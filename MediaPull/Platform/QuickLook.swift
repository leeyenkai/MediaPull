import AppKit
import Quartz
import UniformTypeIdentifiers

/// Quick Look on local files. Remote media is downloaded through the gate first (SPEC R-1010).
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []
    private var loading: Task<Void, Never>?

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    func show(loading _: Int, loader: @escaping () async -> [URL]) {
        loading?.cancel()
        loading = Task { [weak self] in
            let files = await loader()
            guard !Task.isCancelled else { return }
            if files.isEmpty { NSSound.beep() } else { self?.show(files) }
        }
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] : nil }
        return url.map { $0 as NSURL }
    }
}

enum FolderPicker {
    static func chooseFolder(title: String, prompt: String, start: URL?, window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    static func chooseFiles(title: String, window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Convert"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

enum PDFPicker {
    static func choose(window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose PDFs"
        panel.prompt = "Extract Images"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}
