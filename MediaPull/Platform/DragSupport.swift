import AppKit
import UniformTypeIdentifiers

nonisolated enum DragTypes {
    static let itemsIdentifier = "com.yenkai.mediapull.items"
    static let items = NSPasteboard.PasteboardType(itemsIdentifier)
    static let itemsUTType = UTType(exportedAs: itemsIdentifier)
}

/// One dragged media item: the window it belongs to and its id.
nonisolated struct ItemDragPayload: Codable, Hashable, Sendable {
    var window: UUID
    var id: String

    static func read(from pasteboard: NSPasteboard) -> [ItemDragPayload] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: DragTypes.items).flatMap { try? JSONDecoder().decode(ItemDragPayload.self, from: $0) }
        }
    }
}

/// A file promise for one extracted item that also carries the item's identity, so dropping on a
/// library folder saves through the pipeline while dropping on Finder writes the file
/// (SPEC section 18).
nonisolated final class ItemPromiseProvider: NSFilePromiseProvider {
    var payload: ItemDragPayload?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        types.insert(DragTypes.items, at: 0)
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == DragTypes.items ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == DragTypes.items, let payload { return try? JSONEncoder().encode(payload) }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Writes promised files when items are dropped on Finder or another app.
final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    static let shared = PromiseWriter()
    /// Read from whatever thread AppKit asks on, so it is not tied to the main actor.
    nonisolated let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType _: String) -> String {
        (provider.userInfo as? [String: String])?["name"] ?? "media"
    }

    nonisolated func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void)
    {
        let info = provider.userInfo as? [String: String]
        let window = info?["window"].flatMap(UUID.init(uuidString:))
        let id = info?["id"]
        let withSidecar = info?["sidecar"] == "1"
        let done = UncheckedCompletion(completionHandler)
        // Block this operation until the file is written, so the queue's limit of 4 applies.
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { finished.signal() }
            guard let window, let id, let model = AppModel.shared.window(window) else {
                done.call(CocoaError(.fileNoSuchFile))
                return
            }
            let error = await model.writePromise(itemID: id, to: url, withSidecar: withSidecar)
            done.call(error)
        }
        finished.wait()
    }
}

nonisolated final class UncheckedCompletion: @unchecked Sendable {
    let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) { handler(error) }
}
