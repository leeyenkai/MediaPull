#if os(macOS)
    import CoreGraphics
    import Foundation
    import ImageCaptureCore

    /// A device plugged in, as the Devices pane shows it (R-4101, R-4102).
    public struct ConnectedDevice: Sendable, Identifiable {
        public enum State: Sendable {
            case opening
            /// The phone is locked or has not trusted this Mac.
            case locked
            case ready(any DeviceSource)
            case failed(String)
        }

        public var id: String
        public var name: String
        public var symbol: String
        public var isApple: Bool
        public var state: State

        public init(id: String, name: String, symbol: String, isApple: Bool, state: State) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.isApple = isApple
            self.state = state
        }
    }

    /// Finds phones and cameras with Apple's camera framework and makes each a `DeviceSource` (D-116): an MTP phone is read
    /// with MediaPull's own client through the framework's pass-through, everything else as the framework lists it.
    @MainActor
    public final class DeviceBrowser: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
        public var onChange: (([ConnectedDevice]) -> Void)?
        public private(set) var devices: [ConnectedDevice] = [] {
            didSet { onChange?(devices) }
        }

        private let browser = ICDeviceBrowser()
        private var cameras: [String: ICCameraDevice] = [:]
        private var passThroughs: [String: MTPPassThroughTransport] = [:]
        private var catalogs: [String: ImageCaptureSource] = [:]
        private var routed: Set<String> = []

        override public init() {
            super.init()
            browser.delegate = self
            let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        }

        public func start() { if !browser.isBrowsing { browser.start() } }

        public func stop() {
            browser.stop()
            for camera in cameras.values {
                camera.requestCloseSession()
            }
        }

        private func key(_ device: ICDevice) -> String { device.uuidString ?? device.name ?? "device" }

        private func update(_ id: String, _ change: (inout ConnectedDevice) -> Void) {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            change(&devices[index])
        }

        public func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing _: Bool) {
            added(device)
        }

        private func added(_ device: ICDevice) {
            guard let camera = device as? ICCameraDevice else { return }
            let id = key(camera)
            cameras[id] = camera
            let apple = Int(camera.usbVendorID) == DeviceRouting.appleVendorID
            let symbol = camera.systemSymbolName ?? (apple ? "iphone" : "camera")
            devices.append(ConnectedDevice(id: id, name: camera.name ?? "Device", symbol: symbol,
                                           isApple: apple, state: .opening))
            camera.delegate = self
            camera.mediaPresentation = .originalAssets
            camera.requestOpenSession()
        }

        public func deviceBrowser(_: ICDeviceBrowser, didRemove device: ICDevice, moreGoing _: Bool) {
            removed(device)
        }

        private func removed(_ device: ICDevice) {
            let id = key(device)
            passThroughs[id]?.disconnect()
            catalogs[id]?.disconnect()
            for table in [id] {
                cameras[table] = nil
                passThroughs[table] = nil
                catalogs[table] = nil
                routed.remove(table)
            }
            devices.removeAll { $0.id == id }
        }

        public func didRemove(_ device: ICDevice) { removed(device) }

        public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
            let id = key(device)
            if let error {
                update(id) { $0.state = .failed(error.localizedDescription) }
                return
            }
            route(id)
        }

        /// Apple devices are read as the framework lists them; others are asked for their device information through the
        /// pass-through, and an MTP device is read with MediaPull's own client.
        private func route(_ id: String) {
            guard let camera = cameras[id], !routed.contains(id) else { return }
            routed.insert(id)
            let identity = DeviceIdentity(name: camera.name ?? "Device", serial: camera.serialNumberString,
                                          vendorID: Int(camera.usbVendorID),
                                          productID: Int(camera.usbProductID))
            let catalog = ImageCaptureSource(camera: camera, identity: identity)
            catalogs[id] = catalog
            if Int(camera.usbVendorID) == DeviceRouting.appleVendorID {
                update(id) { $0.state = .ready(catalog) }
                return
            }
            let transport = MTPPassThroughTransport(camera: camera)
            passThroughs[id] = transport
            Task {
                let session = MTPSession(transport: transport)
                let info = try? await session.open()
                let backend = DeviceRouting.backend(vendorID: Int(camera.usbVendorID), extensions: info?.vendorExtension)
                if backend == .mtp, let info {
                    let named = DeviceIdentity(name: identity.name, serial: info.serial.isEmpty ? identity.serial : info.serial,
                                               vendorID: identity.vendorID, productID: identity.productID)
                    update(id) { $0.state = .ready(MTPSource(identity: named, session: session)) }
                } else {
                    update(id) { $0.state = .ready(catalog) }
                }
            }
        }

        public func device(_: ICDevice, didCloseSessionWithError _: (any Error)?) {}
        public func cameraDevice(_: ICCameraDevice, didAdd _: [ICCameraItem]) {}
        public func cameraDevice(_: ICCameraDevice, didRemove _: [ICCameraItem]) {}
        public func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: (any Error)?) {}
        public func cameraDevice(_: ICCameraDevice, didReceiveMetadata _: [AnyHashable: Any]?, for _: ICCameraItem,
                                 error _: (any Error)?) {}
        public func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}
        public func cameraDeviceDidChangeCapability(_: ICCameraDevice) {}
        public func cameraDevice(_: ICCameraDevice, didReceivePTPEvent _: Data) {}

        public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
            catalogs[key(device)]?.catalogReady()
        }

        public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
            update(key(device)) { $0.state = .locked }
        }

        public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
            let id = key(device)
            if case .locked = devices.first(where: { $0.id == id })?.state {
                routed.remove(id)
                update(id) { $0.state = .opening }
                route(id)
            }
        }
    }

    /// MTP operations sent inside the framework's own session (D-116): never with data, so nothing reaches the device but
    /// a read request.
    public final class MTPPassThroughTransport: MTPTransport, @unchecked Sendable {
        // Touched only on the main actor.
        private weak var camera: ICCameraDevice?
        private var gone = false

        @MainActor
        init(camera: ICCameraDevice) { self.camera = camera }

        @MainActor
        func disconnect() { gone = true }

        public func send(_ operation: MTPOperation, transaction: UInt32) async throws -> MTPReply {
            let command = operation.command(transaction: transaction)
            return try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    guard !self.gone, let camera = self.camera else {
                        continuation.resume(throwing: MTPError.disconnected)
                        return
                    }
                    camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let header = try? MTPContainer.header(response) else {
                            continuation.resume(throwing: MTPError.malformed("a response without a header"))
                            return
                        }
                        let parameters = stride(from: 12, to: response.count - (response.count - 12) % 4, by: 4).map { response.le32($0) }
                        let payload = MTPContainer.payload(data, code: operation.code)
                        continuation.resume(returning: MTPReply(data: payload, code: header.code, parameters: parameters))
                    }
                }
            }
        }
    }

    /// An iPhone, a camera or an Android phone in PTP mode, as the framework lists it.
    public final class ImageCaptureSource: DeviceSource, @unchecked Sendable {
        public let identity: DeviceIdentity
        // Touched only on the main actor.
        private weak var camera: ICCameraDevice?
        private var ready = false
        private var gone = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        @MainActor
        init(camera: ICCameraDevice, identity: DeviceIdentity) {
            self.camera = camera
            self.identity = identity
        }

        @MainActor
        func catalogReady() {
            ready = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        @MainActor
        func disconnect() {
            gone = true
            catalogReady()
        }

        @MainActor
        private func whenReady() async {
            if ready { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        public func storages() async throws -> [DeviceStorage] { [DeviceStorage(id: "0", name: identity.name)] }

        public func children(of folder: DeviceFolder) async throws -> [DeviceEntry] { try await list(folder) }

        @MainActor
        private func list(_ folder: DeviceFolder) async throws -> [DeviceEntry] {
            await whenReady()
            guard !gone, let camera else { throw DeviceError.disconnected }
            let items = try folder.ref.map { try item(at: $0, in: camera) as? ICCameraFolder }?.flatMap(\.contents) ?? camera.contents ?? []
            return items.compactMap { entry(for: $0, path: folder.ref) }
        }

        /// Items are found by their path of names, so a reference stays valid between listings.
        @MainActor
        private func item(at path: String, in camera: ICCameraDevice) throws -> ICCameraItem? {
            var items = camera.contents ?? []
            var found: ICCameraItem?
            for name in path.split(separator: "/").map(String.init) {
                guard let next = items.first(where: { $0.name == name }) else { throw DeviceError.unreadable(path) }
                found = next
                items = (next as? ICCameraFolder)?.contents ?? []
            }
            return found
        }

        @MainActor
        private func entry(for item: ICCameraItem, path: String?) -> DeviceEntry? {
            let name = item.name ?? "Untitled"
            let ref = path.map { "\($0)/\(name)" } ?? name
            if item is ICCameraFolder {
                return DeviceEntry(id: "0/\(ref)", ref: ref, storage: "0", name: name, isFolder: true, size: 0, taken: item.creationDate)
            }
            guard let file = item as? ICCameraFile else { return nil }
            let group = file.groupUUID.flatMap { $0.isEmpty ? nil : $0 }
            let entry = DeviceEntry(id: "0/\(ref)", ref: ref, storage: "0", name: name, isFolder: false, size: Int64(file.fileSize),
                                    taken: file.exifCreationDate ?? file.creationDate, fingerprint: file.fingerprint, pairKey: group)
            return entry.isMedia ? entry : nil
        }

        public func thumbnail(_ entry: DeviceEntry, maxPixel: Int) async -> CGImage? {
            guard let data = await thumbnailData(entry.ref, maxPixel: maxPixel) else { return nil }
            return DeviceThumbnails.decode(data, maxPixel: maxPixel)
        }

        @MainActor
        private func thumbnailData(_ ref: String, maxPixel: Int) async -> Data? {
            guard let camera, let file = (try? item(at: ref, in: camera)) as? ICCameraFile else { return nil }
            return await withCheckedContinuation { continuation in
                file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        public func download(_ entry: DeviceEntry, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
            let saved = try await requestDownload(entry, into: url.deletingLastPathComponent(), as: url.lastPathComponent)
            guard saved == url.lastPathComponent else { throw DeviceError.unreadable(entry.name) }
            progress(entry.size)
        }

        /// The original, never deleted or truncated on the device afterwards (R-4107).
        @MainActor
        private func requestDownload(_ entry: DeviceEntry, into folder: URL, as name: String) async throws -> String {
            guard !gone, let camera, let file = (try? item(at: entry.ref, in: camera)) as? ICCameraFile else {
                throw DeviceError.disconnected
            }
            let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: folder, .saveAsFilename: name, .overwrite: false]
            return try await withCheckedThrowingContinuation { continuation in
                _ = file.requestDownload(options: options) { filename, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: filename ?? name)
                    }
                }
            }
        }
    }
#endif
