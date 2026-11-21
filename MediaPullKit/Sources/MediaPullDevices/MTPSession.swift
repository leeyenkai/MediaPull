import CoreGraphics
import Foundation

/// Carries one MTP operation to a device and brings back its reply. A transport takes only an `MTPOperation`, so it has no
/// way to send data to the device (R-4107).
public protocol MTPTransport: Sendable {
    func send(_ operation: MTPOperation, transaction: UInt32) async throws -> MTPReply
}

/// Transactions with one MTP device: numbering, busy retries, refusals as errors, and chunked reads.
public actor MTPSession {
    let transport: any MTPTransport
    private var transaction: UInt32 = 0
    public private(set) var deviceInfo: MTPDeviceInfo?

    public init(transport: any MTPTransport) {
        self.transport = transport
    }

    @discardableResult
    func run(_ operation: MTPOperation) async throws -> MTPReply {
        guard MTPOperation.allowedCodes.contains(operation.code) else { throw MTPError.notAllowed(operation.code) }
        for attempt in 0 ..< 4 {
            transaction &+= 1
            if transaction == 0 || transaction == 0xFFFF_FFFF { transaction = 1 }
            let reply = try await transport.send(operation, transaction: transaction)
            if reply.code == MTPReply.ok { return reply }
            if reply.code == MTPReply.deviceBusy, attempt < 3 {
                try await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
                continue
            }
            throw MTPError.response(code: reply.code, operation: operation.code)
        }
        throw MTPError.response(code: MTPReply.deviceBusy, operation: operation.code)
    }

    /// Device information, then a session (one the framework already holds counts as open).
    public func open() async throws -> MTPDeviceInfo {
        let info = try await MTPDeviceInfo(run(.getDeviceInfo()).data)
        deviceInfo = info
        do {
            try await run(.openSession(1))
        } catch MTPError.response(code: MTPReply.sessionAlreadyOpen, operation: _) {}
        return info
    }

    public func close() async {
        _ = try? await run(.closeSession())
    }

    public func storageIDs() async throws -> [UInt32] {
        var reader = try await MTPReader(run(.getStorageIDs()).data)
        // Storages without media (an empty card slot) have a low half of zero.
        return try reader.array32().filter { $0 & 0xFFFF != 0 }
    }

    public func storageInfo(_ storage: UInt32) async throws -> MTPStorageInfo {
        try await MTPStorageInfo(run(.getStorageInfo(storage)).data)
    }

    public func handles(storage: UInt32, parent: UInt32?) async throws -> [UInt32] {
        var reader = try await MTPReader(run(.getObjectHandles(storage: storage, parent: parent ?? 0xFFFF_FFFF)).data)
        return try reader.array32()
    }

    public func objectInfo(_ handle: UInt32) async throws -> MTPObjectInfo {
        try await MTPObjectInfo(run(.getObjectInfo(handle)).data)
    }

    /// The object's size; files of 4 GB or more read it from the size property.
    public func size(of handle: UInt32, info: MTPObjectInfo) async throws -> UInt64 {
        guard info.compressedSize == 0xFFFF_FFFF else { return UInt64(info.compressedSize) }
        var reader = try await MTPReader(run(.getObjectPropValue(handle, property: 0xDC04)).data)
        return try reader.u64()
    }

    public func thumb(_ handle: UInt32) async throws -> Data {
        try await run(.getThumb(handle)).data
    }

    /// Reads the object in chunks into `file`, checking for cancellation between chunks.
    public func read(_ handle: UInt32, size: UInt64, into file: FileHandle, chunk: UInt32 = 8 << 20,
                     progress: @Sendable (Int64) -> Void) async throws
    {
        let operations = deviceInfo?.operations ?? []
        var offset: UInt64 = 0
        if !operations.contains(0x95C1), !operations.contains(0x101B) || size > UInt64(UInt32.max) {
            let data = try await run(.getObject(handle)).data
            try file.write(contentsOf: data)
            progress(Int64(data.count))
            return
        }
        while offset < size {
            try Task.checkCancellation()
            let length = UInt32(min(UInt64(chunk), size - offset))
            let operation: MTPOperation = operations.contains(0x95C1)
                ? .getPartialObject64(handle, offset: offset, length: length)
                : .getPartialObject(handle, offset: UInt32(offset), length: length)
            let data = try await run(operation).data
            guard !data.isEmpty else { throw MTPError.malformed("an empty read before the end of the file") }
            try file.write(contentsOf: data)
            offset += UInt64(data.count)
            progress(Int64(offset))
        }
    }
}

/// An Android phone (or any MTP device) as a `DeviceSource`.
public final class MTPSource: DeviceSource {
    public let identity: DeviceIdentity
    let session: MTPSession

    public init(identity: DeviceIdentity, session: MTPSession) {
        self.identity = identity
        self.session = session
    }

    public func storages() async throws -> [DeviceStorage] {
        var out: [DeviceStorage] = []
        for id in try await session.storageIDs() {
            let info = try? await session.storageInfo(id)
            let name = [info?.description, info?.label].compactMap { $0 }.first { !$0.isEmpty } ?? "Storage"
            out.append(DeviceStorage(id: String(id), name: name, capacity: info?.capacity, free: info?.free))
        }
        return out
    }

    public func children(of folder: DeviceFolder) async throws -> [DeviceEntry] {
        guard let storage = UInt32(folder.storage) else { return [] }
        let parent = folder.ref.flatMap { UInt32($0) }
        var out: [DeviceEntry] = []
        for handle in try await session.handles(storage: storage, parent: parent) {
            try Task.checkCancellation()
            guard let info = try? await session.objectInfo(handle) else { continue }
            let size = info.isFolder ? 0 : (try? await session.size(of: handle, info: info)) ?? UInt64(info.compressedSize)
            // Files of one shot share their folder and name (R-4206).
            let stem = (info.name as NSString).deletingPathExtension.lowercased()
            let entry = DeviceEntry(id: "\(folder.storage)/\(handle)", ref: String(handle), storage: folder.storage, name: info.name,
                                    isFolder: info.isFolder, size: Int64(clamping: size), taken: info.captured ?? info.modified,
                                    pairKey: "\(folder.ref ?? "top")/\(stem)", hasThumbnail: info.thumbFormat != 0)
            if entry.isFolder || entry.isMedia { out.append(entry) }
        }
        return out
    }

    public func thumbnail(_ entry: DeviceEntry, maxPixel: Int) async -> CGImage? {
        guard entry.hasThumbnail, let handle = UInt32(entry.ref), let data = try? await session.thumb(handle), !data.isEmpty else {
            return nil
        }
        return await Task.detached(priority: .utility) { DeviceThumbnails.decode(data, maxPixel: maxPixel) }.value
    }

    public func download(_ entry: DeviceEntry, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let handle = UInt32(entry.ref) else { throw DeviceError.unreadable(entry.name) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw DeviceError.unreadable(entry.name) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try await session.read(handle, size: UInt64(max(entry.size, 0)), into: file, progress: progress)
    }
}
