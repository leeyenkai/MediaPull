import CoreGraphics
import Foundation
import MediaPullCore
import MediaPullMedia

/// An MTP device in memory, answering as a phone would: for tests and the offline self-test (`--selftest-devices`). It
/// records every operation it is sent, so a test can check that only reads arrived.
public actor MTPResponderSimulator: MTPTransport {
    public struct Object: Sendable {
        public var name: String
        public var parent: UInt32
        public var storage: UInt32
        public var data: Data?
        public var captured: Date?

        public init(name: String, parent: UInt32, storage: UInt32, data: Data? = nil, captured: Date? = nil) {
            self.name = name
            self.parent = parent
            self.storage = storage
            self.data = data
            self.captured = captured
        }
    }

    public private(set) var objects: [UInt32: Object] = [:]
    public private(set) var received: [UInt16] = []
    public var busyBeforeAnswer = 0
    public var disconnected = false
    private var nextHandle: UInt32 = 1
    private var sessionOpen = false
    let operations: Set<UInt16>
    let serial: String

    public init(serial: String = "SIM0001", supports64: Bool = true) {
        self.serial = serial
        var operations: Set<UInt16> = [0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100A, 0x101B, 0x9803]
        if supports64 { operations.insert(0x95C1) }
        self.operations = operations
    }

    @discardableResult
    public func add(_ name: String, in parent: UInt32 = 0xFFFF_FFFF, storage: UInt32 = 0x0001_0001, data: Data? = nil,
                    captured: Date? = nil) -> UInt32
    {
        let handle = nextHandle
        nextHandle += 1
        objects[handle] = Object(name: name, parent: parent, storage: storage, data: data, captured: captured)
        return handle
    }

    public func setDisconnected(_ value: Bool) { disconnected = value }
    public func setBusy(_ count: Int) { busyBeforeAnswer = count }

    public func send(_ operation: MTPOperation, transaction _: UInt32) async throws -> MTPReply {
        guard !disconnected else { throw MTPError.disconnected }
        received.append(operation.code)
        if busyBeforeAnswer > 0 {
            busyBeforeAnswer -= 1
            return MTPReply(code: MTPReply.deviceBusy)
        }
        let p = operation.parameters
        switch operation.code {
        case 0x1001: return MTPReply(data: deviceInfo(), code: MTPReply.ok)
        case 0x1002:
            defer { sessionOpen = true }
            return MTPReply(code: sessionOpen ? MTPReply.sessionAlreadyOpen : MTPReply.ok)
        case 0x1003:
            sessionOpen = false
            return MTPReply(code: MTPReply.ok)
        case 0x1004:
            var data = Data()
            data.appendLE(UInt32(1))
            data.appendLE(UInt32(0x0001_0001))
            return MTPReply(data: data, code: MTPReply.ok)
        case 0x1005:
            var data = Data()
            data.appendLE(UInt16(3))
            data.appendLE(UInt16(2))
            data.appendLE(UInt16(0))
            data.appendLE(UInt64(64 << 30))
            data.appendLE(UInt64(20 << 30))
            data.appendLE(UInt32(0xFFFF_FFFF))
            data.appendPTPString("Internal shared storage")
            data.appendPTPString("")
            return MTPReply(data: data, code: MTPReply.ok)
        case 0x1007:
            let handles = objects.filter { $0.value.storage == p[0] && $0.value.parent == p[2] }.keys.sorted()
            var data = Data()
            data.appendLE(UInt32(handles.count))
            for handle in handles {
                data.appendLE(handle)
            }
            return MTPReply(data: data, code: MTPReply.ok)
        case 0x1008:
            guard let object = objects[p[0]] else { return MTPReply(code: MTPReply.invalidObjectHandle) }
            let folder = object.data == nil
            let info = MTPObjectInfo(storage: object.storage, format: folder ? 0x3001 : 0x3000,
                                     compressedSize: UInt32(object.data?.count ?? 0),
                                     thumbFormat: folder ? 0 : 0x3801, parent: object.parent, name: object.name, captured: object.captured)
            return MTPReply(data: info.encoded(), code: MTPReply.ok)
        case 0x1009:
            guard let data = objects[p[0]]?.data else { return MTPReply(code: MTPReply.invalidObjectHandle) }
            return MTPReply(data: data, code: MTPReply.ok)
        case 0x100A:
            guard objects[p[0]]?.data != nil else { return MTPReply(code: MTPReply.invalidObjectHandle) }
            return MTPReply(data: Data(), code: MTPReply.ok)
        case 0x101B, 0x95C1:
            guard let data = objects[p[0]]?.data else { return MTPReply(code: MTPReply.invalidObjectHandle) }
            let offset = operation.code == 0x95C1 ? Int(UInt64(p[1]) | UInt64(p[2]) << 32) : Int(p[1])
            let length = Int(operation.code == 0x95C1 ? p[3] : p[2])
            let start = min(offset, data.count)
            return MTPReply(data: data.subdata(in: start ..< min(data.count, start + length)), code: MTPReply.ok)
        default:
            return MTPReply(code: MTPReply.operationNotSupported)
        }
    }

    private func deviceInfo() -> Data {
        var data = Data()
        data.appendLE(UInt16(100))
        data.appendLE(UInt32(6))
        data.appendLE(UInt16(100))
        data.appendPTPString("microsoft.com: 1.0; android.com: 1.0;")
        data.appendLE(UInt16(0))
        let codes = operations.sorted()
        data.appendLE(UInt32(codes.count))
        for code in codes {
            data.appendLE(code)
        }
        for _ in 0 ..< 4 {
            data.appendLE(UInt32(0))
        }
        data.appendPTPString("Stand-in")
        data.appendPTPString("Android phone")
        data.appendPTPString("1.0")
        data.appendPTPString(serial)
        return data
    }
}

/// A folder as a device: a camera card's drive (R-4303), or a stand-in iPhone in the offline self-test. Its subfolders are
/// the device's folders, its files the device's files, and files of one shot share a name (R-4206).
public final class FolderDeviceSource: DeviceSource {
    public let identity: DeviceIdentity
    let root: URL

    public init(root: URL, identity: DeviceIdentity) {
        self.root = root
        self.identity = identity
    }

    public func storages() async throws -> [DeviceStorage] { [DeviceStorage(id: "0", name: identity.name)] }

    public func children(of folder: DeviceFolder) async throws -> [DeviceEntry] {
        let base = folder.ref.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let root = root
        return try await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> DeviceEntry? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                let folder = relative.split(separator: "/").dropLast().joined(separator: "/")
                let pair = "\(folder)/\(url.deletingPathExtension().lastPathComponent)"
                let entry = DeviceEntry(id: "0/\(relative)", ref: relative, storage: "0", name: url.lastPathComponent,
                                        isFolder: values?.isDirectory ?? false, size: Int64(values?.fileSize ?? 0),
                                        taken: values?.contentModificationDate, pairKey: pair)
                return entry.isFolder || entry.isMedia ? entry : nil
            }
        }.value
    }

    public func thumbnail(_ entry: DeviceEntry, maxPixel: Int) async -> CGImage? {
        let url = root.appendingPathComponent(entry.ref)
        if entry.kind == .video { return await Thumbnailer.videoFrame(at: url, maxPixel: maxPixel) }
        // The picture's own embedded preview where it has one large enough (RAW, HEIC), so a card of RAW files lists quickly.
        return await Task.detached(priority: .utility) { Thumbnailer.image(at: url, maxPixel: maxPixel) }.value
    }

    public func download(_ entry: DeviceEntry, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let source = root.appendingPathComponent(entry.ref)
        try await Task.detached(priority: .userInitiated) {
            // Copied (never moved) into the importer's own staging folder; the card is only read. A copy streams, so a
            // large video never sits in memory.
            guard FileManager.default.fileExists(atPath: source.path) else { throw DeviceError.disconnected }
            try FileManager.default.copyItem(at: source, to: url)
        }.value
        progress(entry.size)
    }
}
