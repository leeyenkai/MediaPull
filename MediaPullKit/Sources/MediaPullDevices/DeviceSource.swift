import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore

/// Who a device is, for the record of what was imported from it (R-4105).
public struct DeviceIdentity: Sendable, Hashable, Codable {
    public var name: String
    public var serial: String?
    public var vendorID: Int
    public var productID: Int

    public init(name: String, serial: String?, vendorID: Int, productID: Int) {
        self.name = name
        self.serial = serial
        self.vendorID = vendorID
        self.productID = productID
    }

    /// The serial number where the device gives one, else vendor, product and name.
    public var key: String {
        if let serial, !serial.trimmingCharacters(in: .whitespaces).isEmpty { return "serial:\(serial)" }
        return "usb:\(vendorID):\(productID):\(name)"
    }
}

/// A storage on a device (an iPhone has one; an Android phone may have internal storage and a card).
public struct DeviceStorage: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var capacity: UInt64?
    public var free: UInt64?

    public init(id: String, name: String, capacity: UInt64? = nil, free: UInt64? = nil) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.free = free
    }
}

/// A file or folder on a device. `ref` is the source's own reference (an MTP handle, an index into the framework's items).
public struct DeviceEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var ref: String
    public var storage: String
    public var name: String
    public var isFolder: Bool
    public var size: Int64
    public var taken: Date?
    /// The framework's own fingerprint of the file's contents, where it gives one.
    public var fingerprint: String?
    /// Files that belong together (a Live Photo's still and clip) share this.
    public var pairKey: String?
    public var hasThumbnail: Bool

    public init(id: String, ref: String, storage: String, name: String, isFolder: Bool, size: Int64, taken: Date? = nil,
                fingerprint: String? = nil, pairKey: String? = nil, hasThumbnail: Bool = true)
    {
        self.id = id
        self.ref = ref
        self.storage = storage
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.taken = taken
        self.fingerprint = fingerprint
        self.pairKey = pairKey
        self.hasThumbnail = hasThumbnail
    }

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    public var format: MediaFormat? { MediaFormat.fromExtension(fileExtension) }
    public var kind: MediaKind? { format?.kind }

    /// Photos and videos only (R-4103); `.AAE` edit files and everything else stay on the device.
    public var isMedia: Bool {
        guard !isFolder, let kind else { return false }
        return kind == .image || kind == .animatedImage || kind == .video
    }

    /// How the record of imports knows this file (R-4105).
    public var importKey: String {
        if let fingerprint, !fingerprint.isEmpty { return "f:\(fingerprint)" }
        let taken = taken.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "n:\(name.precomposedStringWithCanonicalMapping.lowercased())|\(size)|\(taken)"
    }
}

/// Where in a device a listing starts: a storage's top, or a folder in it.
public struct DeviceFolder: Sendable, Hashable {
    public var storage: String
    /// nil for the top of the storage.
    public var ref: String?

    public init(storage: String, ref: String? = nil) {
        self.storage = storage
        self.ref = ref
    }
}

/// A phone or camera that can be browsed and copied from, never written to (R-4107).
public protocol DeviceSource: AnyObject, Sendable {
    var identity: DeviceIdentity { get }
    func storages() async throws -> [DeviceStorage]
    /// Folders and media files directly inside `folder`.
    func children(of folder: DeviceFolder) async throws -> [DeviceEntry]
    /// The device's own small picture of the file, never the whole file.
    func thumbnail(_ entry: DeviceEntry, maxPixel: Int) async -> CGImage?
    /// Copies the file to `url` (a new file); `progress` gets the bytes copied so far.
    func download(_ entry: DeviceEntry, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum DeviceError: Error, LocalizedError, Equatable {
    case disconnected
    case unreadable(String)
    case sizeMismatch(expected: Int64, got: Int64)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The device was disconnected."
        case let .unreadable(name): "“\(name)” could not be read from the device."
        case let .sizeMismatch(expected, got): "The copy is \(got) bytes, but the device said \(expected)."
        }
    }
}

enum DeviceThumbnails {
    /// A small image from the bytes of a device's thumbnail (JPEG, usually), decoded off the main actor by the caller.
    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Which way a device is read (R-4102, D-116).
public enum DeviceRouting {
    public enum Backend: Sendable, Equatable {
        /// As Apple's camera framework lists it (iPhones, cameras, Android phones in PTP mode).
        case imageCapture
        /// With MediaPull's own MTP client (Android phones in File transfer mode).
        case mtp
    }

    public static let appleVendorID = 0x05AC

    /// `extensions` is the vendor-extension text of the device information, nil when it could not be read.
    public static func backend(vendorID: Int, extensions: String?) -> Backend {
        if vendorID == appleVendorID { return .imageCapture }
        guard let extensions, extensions.lowercased().contains("microsoft.com") else { return .imageCapture }
        return .mtp
    }
}
