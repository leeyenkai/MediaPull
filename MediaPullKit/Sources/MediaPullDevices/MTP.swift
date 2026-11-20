import Foundation

/// One MTP request MediaPull may send (R-4107): reads only. The initialiser is private, so an operation that deletes, sends,
/// moves, copies, formats or sets anything cannot be written, and no request carries data to the device.
public struct MTPOperation: Sendable, Equatable, CustomStringConvertible {
    public let code: UInt16
    public let parameters: [UInt32]

    private init(_ code: UInt16, _ parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }

    public static func getDeviceInfo() -> MTPOperation { .init(0x1001) }
    public static func openSession(_ id: UInt32) -> MTPOperation { .init(0x1002, [id]) }
    public static func closeSession() -> MTPOperation { .init(0x1003) }
    public static func getStorageIDs() -> MTPOperation { .init(0x1004) }
    public static func getStorageInfo(_ storage: UInt32) -> MTPOperation { .init(0x1005, [storage]) }
    /// `parent` 0xFFFFFFFF lists the top of the storage.
    public static func getObjectHandles(storage: UInt32, parent: UInt32) -> MTPOperation { .init(0x1007, [storage, 0, parent]) }
    public static func getObjectInfo(_ handle: UInt32) -> MTPOperation { .init(0x1008, [handle]) }
    public static func getObject(_ handle: UInt32) -> MTPOperation { .init(0x1009, [handle]) }
    public static func getThumb(_ handle: UInt32) -> MTPOperation { .init(0x100A, [handle]) }
    public static func getPartialObject(_ handle: UInt32, offset: UInt32, length: UInt32) -> MTPOperation {
        .init(0x101B, [handle, offset, length])
    }

    public static func getPartialObject64(_ handle: UInt32, offset: UInt64, length: UInt32) -> MTPOperation {
        .init(0x95C1, [handle, UInt32(truncatingIfNeeded: offset), UInt32(truncatingIfNeeded: offset >> 32), length])
    }

    public static func getObjectPropsSupported(format: UInt16) -> MTPOperation { .init(0x9801, [UInt32(format)]) }
    public static func getObjectPropValue(_ handle: UInt32, property: UInt16) -> MTPOperation { .init(0x9803, [handle, UInt32(property)]) }
    public static func getObjectPropList(_ handle: UInt32, property: UInt16) -> MTPOperation {
        .init(0x9805, [handle, 0, UInt32(property), 0, 0])
    }

    public static func getObjectReferences(_ handle: UInt32) -> MTPOperation { .init(0x9810, [handle]) }

    /// Every code an operation can have.
    public static let allowedCodes: Set<UInt16> = [
        0x1001, 0x1002, 0x1003, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100A, 0x101B, 0x95C1, 0x9801, 0x9803, 0x9805, 0x9810,
    ]

    /// The PTP and MTP operations that change a device; none can be built (tests check the two sets never meet).
    public static let writeCodes: Set<UInt16> = [
        0x100B, 0x100C, 0x100D, 0x100E, 0x100F, 0x1010, 0x1011, 0x1012, 0x1013, 0x1016, 0x1017, 0x1018, 0x1019, 0x101A,
        0x101C, 0x101D, 0x9804, 0x9806, 0x9807, 0x9808, 0x9811, 0x95C2, 0x95C3, 0x95C4, 0x95C5,
    ]

    /// The command container: length, type 1, code, transaction, parameters (little-endian).
    public func command(transaction: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(12 + 4 * parameters.count))
        data.appendLE(UInt16(1))
        data.appendLE(code)
        data.appendLE(transaction)
        for parameter in parameters {
            data.appendLE(parameter)
        }
        return data
    }

    public var description: String { "0x" + String(code, radix: 16, uppercase: true) }
}

/// What a device answered: the data phase (without its container header) and the response code and parameters.
public struct MTPReply: Sendable, Equatable {
    public var data: Data
    public var code: UInt16
    public var parameters: [UInt32]

    public init(data: Data = Data(), code: UInt16, parameters: [UInt32] = []) {
        self.data = data
        self.code = code
        self.parameters = parameters
    }

    public static let ok: UInt16 = 0x2001
    public static let deviceBusy: UInt16 = 0x2019
    public static let sessionAlreadyOpen: UInt16 = 0x201E
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let operationNotSupported: UInt16 = 0x2005
}

public enum MTPError: Error, Equatable, LocalizedError {
    case malformed(String)
    case response(code: UInt16, operation: UInt16)
    case disconnected
    case notAllowed(UInt16)

    public var errorDescription: String? {
        switch self {
        case let .malformed(what): "The device sent something that could not be read (\(what))."
        case let .response(code, operation):
            "The device refused a request (0x\(String(operation, radix: 16)): 0x\(String(code, radix: 16)))."
        case .disconnected: "The device was disconnected."
        case let .notAllowed(code): "MediaPull does not send 0x\(String(code, radix: 16)) to devices."
        }
    }
}

/// Containers as they come off the wire: a data container (type 2) then a response container (type 3), possibly split
/// across USB packets and possibly with a zero-length packet after a data phase that fills whole packets.
public enum MTPContainer {
    public struct Header: Equatable, Sendable {
        public var length: UInt32
        public var type: UInt16
        public var code: UInt16
        public var transaction: UInt32
    }

    public static func header(_ data: Data) throws -> Header {
        guard data.count >= 12 else { throw MTPError.malformed("a container shorter than its header") }
        let header = Header(length: data.le32(0), type: data.le16(4), code: data.le16(6), transaction: data.le32(8))
        guard header.length >= 12 else { throw MTPError.malformed("a container length below 12") }
        return header
    }

    /// Joins packets into whole containers; empty packets are skipped.
    public static func split(_ packets: [Data]) throws -> [(Header, Data)] {
        var stream = Data()
        for packet in packets where !packet.isEmpty {
            stream.append(packet)
        }
        var out: [(Header, Data)] = []
        var offset = 0
        while offset < stream.count {
            let rest = stream.subdata(in: offset ..< stream.count)
            let header = try header(rest)
            guard rest.count >= Int(header.length) else { throw MTPError.malformed("a container cut short") }
            out.append((header, rest.subdata(in: 12 ..< Int(header.length))))
            offset += Int(header.length)
        }
        return out
    }

    /// A reply from the containers of one transaction.
    public static func reply(_ packets: [Data]) throws -> MTPReply {
        var data = Data()
        for (header, payload) in try split(packets) {
            switch header.type {
            case 2: data.append(payload)
            case 3:
                let parameters = stride(from: 0, to: payload.count - payload.count % 4, by: 4).map { payload.le32($0) }
                return MTPReply(data: data, code: header.code, parameters: parameters)
            default: continue
            }
        }
        throw MTPError.malformed("no response container")
    }

    /// A response container from a code and parameters (the simulator's side, and tests).
    public static func response(_ code: UInt16, transaction: UInt32, parameters: [UInt32] = []) -> Data {
        var out = Data()
        out.appendLE(UInt32(12 + 4 * parameters.count))
        out.appendLE(UInt16(3))
        out.appendLE(code)
        out.appendLE(transaction)
        for parameter in parameters {
            out.appendLE(parameter)
        }
        return out
    }

    public static func data(_ payload: Data, code: UInt16, transaction: UInt32) -> Data {
        var out = Data()
        out.appendLE(UInt32(12 + payload.count))
        out.appendLE(UInt16(2))
        out.appendLE(code)
        out.appendLE(transaction)
        out.append(payload)
        return out
    }

    /// A data phase handed over with or without its container header.
    public static func payload(_ data: Data, code: UInt16) -> Data {
        guard data.count >= 12, data.le16(4) == 2, data.le16(6) == code, Int(data.le32(0)) == data.count else { return data }
        return data.subdata(in: 12 ..< data.count)
    }
}

// MARK: Datasets

/// Reads PTP datasets: little-endian integers, arrays with a 32-bit count, and strings as a count of UTF-16 units
/// (terminator included) followed by the units.
public struct MTPReader {
    public let data: Data
    public private(set) var offset = 0

    public init(_ data: Data) { self.data = data }

    public mutating func u8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw MTPError.malformed("a dataset cut short") }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw MTPError.malformed("a dataset cut short") }
        defer { offset += 2 }
        return data.le16(offset)
    }

    public mutating func u32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw MTPError.malformed("a dataset cut short") }
        defer { offset += 4 }
        return data.le32(offset)
    }

    public mutating func u64() throws -> UInt64 {
        let low = try UInt64(u32())
        return try low | UInt64(u32()) << 32
    }

    public mutating func string() throws -> String {
        let count = try Int(u8())
        guard count > 0 else { return "" }
        guard offset + 2 * count <= data.count else { throw MTPError.malformed("a string cut short") }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0 ..< count {
            try units.append(u16())
        }
        return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
    }

    public mutating func array16() throws -> [UInt16] {
        let count = try Int(u32())
        guard count <= (data.count - offset) / 2 else { throw MTPError.malformed("an array longer than its dataset") }
        return try (0 ..< count).map { _ in try u16() }
    }

    public mutating func array32() throws -> [UInt32] {
        let count = try Int(u32())
        guard count <= (data.count - offset) / 4 else { throw MTPError.malformed("an array longer than its dataset") }
        return try (0 ..< count).map { _ in try u32() }
    }
}

public struct MTPDeviceInfo: Sendable, Equatable {
    public var vendorExtension: String
    public var operations: Set<UInt16>
    public var manufacturer: String
    public var model: String
    public var version: String
    public var serial: String

    /// Android and other MTP devices name Microsoft's extension set.
    public var speaksMTP: Bool { vendorExtension.lowercased().contains("microsoft.com") }

    public init(vendorExtension: String, operations: Set<UInt16>, manufacturer: String, model: String, version: String, serial: String) {
        self.vendorExtension = vendorExtension
        self.operations = operations
        self.manufacturer = manufacturer
        self.model = model
        self.version = version
        self.serial = serial
    }

    public init(_ data: Data) throws {
        var reader = MTPReader(data)
        _ = try reader.u16() // standard version
        _ = try reader.u32() // vendor extension id
        _ = try reader.u16() // vendor extension version
        vendorExtension = try reader.string()
        _ = try reader.u16() // functional mode
        operations = try Set(reader.array16())
        _ = try reader.array16() // events
        _ = try reader.array16() // device properties
        _ = try reader.array16() // capture formats
        _ = try reader.array16() // playback formats
        manufacturer = try reader.string()
        model = try reader.string()
        version = try reader.string()
        serial = try reader.string()
    }
}

public struct MTPStorageInfo: Sendable, Equatable {
    public var capacity: UInt64
    public var free: UInt64
    public var description: String
    public var label: String

    public init(capacity: UInt64, free: UInt64, description: String, label: String) {
        self.capacity = capacity
        self.free = free
        self.description = description
        self.label = label
    }

    public init(_ data: Data) throws {
        var reader = MTPReader(data)
        _ = try reader.u16() // storage type
        _ = try reader.u16() // file system type
        _ = try reader.u16() // access capability
        capacity = try reader.u64()
        free = try reader.u64()
        _ = try reader.u32() // free space in objects
        description = try reader.string()
        label = try reader.string()
    }
}

public struct MTPObjectInfo: Sendable, Equatable {
    public var storage: UInt32
    public var format: UInt16
    /// 0xFFFFFFFF when the object is 4 GB or more; the size property tells the rest.
    public var compressedSize: UInt32
    public var thumbFormat: UInt16
    public var parent: UInt32
    public var name: String
    public var captured: Date?
    public var modified: Date?

    public var isFolder: Bool { format == 0x3001 }

    public init(storage: UInt32, format: UInt16, compressedSize: UInt32, thumbFormat: UInt16 = 0, parent: UInt32, name: String,
                captured: Date? = nil, modified: Date? = nil)
    {
        self.storage = storage
        self.format = format
        self.compressedSize = compressedSize
        self.thumbFormat = thumbFormat
        self.parent = parent
        self.name = name
        self.captured = captured
        self.modified = modified
    }

    public init(_ data: Data) throws {
        var reader = MTPReader(data)
        storage = try reader.u32()
        format = try reader.u16()
        _ = try reader.u16() // protection
        compressedSize = try reader.u32()
        thumbFormat = try reader.u16()
        for _ in 0 ..< 7 {
            _ = try reader.u32() // thumb size and pixels, image pixels and bit depth
        }
        parent = try reader.u32()
        _ = try reader.u16() // association type
        _ = try reader.u32() // association description
        _ = try reader.u32() // sequence number
        name = try reader.string()
        captured = try MTPDate.parse(reader.string())
        modified = try MTPDate.parse(reader.string())
    }

    /// The dataset as a device sends it (the simulator's side, and tests).
    public func encoded() -> Data {
        var data = Data()
        data.appendLE(storage)
        data.appendLE(format)
        data.appendLE(UInt16(0))
        data.appendLE(compressedSize)
        data.appendLE(thumbFormat)
        for _ in 0 ..< 7 {
            data.appendLE(UInt32(0))
        }
        data.appendLE(parent)
        data.appendLE(UInt16(isFolder ? 1 : 0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendPTPString(name)
        data.appendPTPString(captured.map(MTPDate.format) ?? "")
        data.appendPTPString(modified.map(MTPDate.format) ?? "")
        data.appendPTPString("")
        return data
    }
}

/// PTP dates: `YYYYMMDDThhmmss`, optionally with tenths of a second and `Z` or an offset such as `+0800`. Without either,
/// the time is the device's local time, read here as the Mac's.
public enum MTPDate {
    public static func parse(_ text: String) -> Date? {
        let chars = Array(text)
        guard chars.count >= 15, chars[8] == "T" else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = number(0 ..< 4), let month = number(4 ..< 6), let day = number(6 ..< 8),
              let hour = number(9 ..< 11), let minute = number(11 ..< 13), let second = number(13 ..< 15),
              (1 ... 12).contains(month), (1 ... 31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var rest = chars.dropFirst(15)
        if rest.first == "." {
            rest = rest.dropFirst().drop { $0.isNumber }
        }
        var zone = TimeZone.current
        if rest.first == "Z" {
            zone = TimeZone(secondsFromGMT: 0)!
        } else if let sign = rest.first, sign == "+" || sign == "-" {
            let digits = String(rest.dropFirst().prefix(4))
            guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
            let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            guard let offset = TimeZone(secondsFromGMT: seconds) else { return nil }
            zone = offset
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    public static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 { UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16 }

    mutating func appendLE(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendPTPString(_ text: String) {
        guard !text.isEmpty else {
            append(0)
            return
        }
        let units = Array(text.utf16.prefix(254)) + [0]
        append(UInt8(units.count))
        for unit in units {
            appendLE(unit)
        }
    }
}
