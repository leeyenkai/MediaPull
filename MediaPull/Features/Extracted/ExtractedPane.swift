import MediaPullCore
import SwiftUI

struct ExtractedPane: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ExtractedHeader(model: model)
            QuickFilterBar(model: model)
            Divider()
            if model.showFilters {
                FilterBar(model: model)
                Divider()
            }
            ZStack {
                MediaGrid(sections: model.sections, selection: model.selection, cellSize: model.cellSize,
                          revision: model.gridRevision, owner: model)
                if model.visible.isEmpty {
                    EmptyExtracted(model: model)
                }
            }
            Divider()
            ExtractedStatusBar(model: model)
        }
    }
}

struct ExtractedHeader: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Extracted Media")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                // Wide panes show every action; narrow ones keep sort and filters and fold the rest into a menu.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        extractionButton
                        sortMenu
                        scrollButton
                        rescanButton
                        pdfMenu
                        clearButton
                    }
                    HStack(spacing: 8) {
                        extractionButton
                        sortMenu
                        overflowMenu
                    }
                }
                PaneMenu(pane: .extracted, window: model)
            }
            contextActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(app.preferences.theme.headerBackground)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.filter.sort) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            Toggle("Ascending", isOn: $model.filter.ascending)
            Divider()
            Button("Zoom In") { model.cellSize = min(WindowModel.zoomRange.upperBound, model.cellSize + 40) }
            Button("Zoom Out") { model.cellSize = max(WindowModel.zoomRange.lowerBound, model.cellSize - 40) }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort and zoom")
    }

    /// Finding media on pages can be paused, for example while signing in.
    private var extractionButton: some View {
        Button { model.extractionEnabled.toggle() } label: {
            Image(systemName: model.extractionEnabled ? "pause.circle" : "play.circle.fill")
        }
        .buttonStyle(.borderless)
        .help(model.extractionEnabled ? "Pause finding media on pages" : "Paused. Click to find media on pages again.")
    }

    private var scrollButton: some View {
        Button { model.toggleAutoScroll() } label: {
            Image(systemName: model.autoScrolling ? "stop.circle" : "arrow.down.to.line.compact")
        }
        .buttonStyle(.borderless)
        .help(model.autoScrolling ? "Stop scrolling" : "Scroll the page to the end so lazy-loaded media appears")
    }

    private var rescanButton: some View {
        Button { model.browser.rescan() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
            .buttonStyle(.borderless)
            .help("Look for media on the page again")
    }

    @ViewBuilder
    private var pdfCommands: some View {
        Button("Open PDF…") { PDFPicker.choose(window: model.hostWindow) { files in files.forEach(model.extractPDF(local:)) } }
        if model.browser.isShowingPDF, let url = model.browser.url {
            Button("Extract Images from This PDF") {
                model.extractedDocuments.remove(url.absoluteString)
                model.extractPDF(remote: url, linkedFrom: nil)
            }
        }
    }

    private var pdfMenu: some View {
        Menu { pdfCommands } label: { Image(systemName: "doc.richtext") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Extract the images inside a PDF. You can also drop PDF files here.")
    }

    private var clearButton: some View {
        Button { model.clear() } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Clear extracted media (⌘K)")
            .disabled(model.items.isEmpty)
    }

    private var overflowMenu: some View {
        Menu {
            Button(model.autoScrolling ? "Stop Scrolling" : "Scroll to End of Page") { model.toggleAutoScroll() }
            Button("Look for Media Again") { model.browser.rescan() }
            Button("Save Video from This Page…") { model.showDownloads(video: true) }
                .disabled(model.browser.url == nil)
            Divider()
            pdfCommands
            Divider()
            Button("Clear Extracted Media") { model.clear() }
                .disabled(model.items.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var contextActions: some View {
        if !model.documents.isEmpty {
            HStack(spacing: 8) {
                Menu("PDFs on This Page (\(model.documents.count))") {
                    Button("Extract Images from All PDFs") { model.extractAllDocuments() }
                    Divider()
                    ForEach(model.documents.prefix(25), id: \.self) { url in
                        Button((url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                            + (model.extractedDocuments.contains(url.absoluteString) ? " ✓" : ""))
                        {
                            model.extractPDF(remote: url, linkedFrom: model.browser.url)
                        }
                    }
                }
                .fixedSize()
                .help("Lists the images inside PDFs linked from this page")
            }
            .controlSize(.small)
        }
        switch model.pageKind {
        case let .instagramProfile(name, _), let .instagramStories(name, _):
            HStack(spacing: 8) {
                Button("Download @\(name)…") { model.showDownloads("@\(name)") }
                    .buttonStyle(.borderedProminent)
                Button("List in Extracted Media") {
                    var draft = app.engines.draft(username: name)
                    draft.incremental = false
                    app.engines.startPull(draft, scanOnly: true, window: model)
                }
                if !app.engines.signedIn {
                    Image(systemName: "key.fill").foregroundStyle(.orange).help("Sign in to Instagram first for full results")
                }
            }
            .controlSize(.small)
        case let .instagramPost(code, url):
            HStack(spacing: 8) {
                Button("Download This Post") {
                    var draft = app.engines.draft(username: "", postURL: url)
                    draft.folderName = ""
                    draft.incremental = false
                    app.engines.startPull(draft, scanOnly: false, window: model)
                }
                .buttonStyle(.borderedProminent)
                Button("List in Extracted Media") {
                    var draft = app.engines.draft(username: "", postURL: url)
                    draft.incremental = false
                    app.engines.startPull(draft, scanOnly: true, window: model)
                }
                Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        default:
            if let category = model.siteExtractorCategory, let url = model.browser.url {
                HStack(spacing: 8) {
                    Button("Get Original Files") { app.engines.startSiteScan(url: url, category: category, window: model) }
                        .buttonStyle(.borderedProminent)
                        .help("Lists this \(category.capitalized) page's files at their original size, in Extracted Media")
                    Button("Download All…") { model.showDownloads() }
                        .help("Download everything at this address into a folder")
                }
                .controlSize(.small)
            }
        }
    }
}

struct EmptyExtracted: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.items.isEmpty ? "photo.on.rectangle.angled" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            if model.items.isEmpty {
                Text(model.browser.isLoading ? "Looking for media…" : "No media yet")
                    .font(.headline)
                Text("Open a page in the browser. Images and videos appear here as they load.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Everything is filtered out")
                    .font(.headline)
                Text("\(model.items.count) items were found, but none match the filters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Reset Filters") { model.filter = MediaFilter() }
            }
        }
        .padding(24)
        .frame(maxWidth: 320)
    }
}

struct ExtractedStatusBar: View {
    @Bindable var model: WindowModel
    private var app: AppModel { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Text(counts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            ZoomSlider(size: $model.cellSize)
            if let job = app.jobs.jobs.first(where: { $0.state.isActive && [.save, .scan, .pull, .stream].contains($0.kind) }) {
                HStack(spacing: 6) {
                    ProgressView(value: job.progress ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                        .opacity(job.progress == nil ? 0.4 : 1)
                    Text(job.title).font(.caption).lineLimit(1)
                }
            }
            SaveFolderMenu(model: model)
            Button(model.selection.isEmpty ? "Save" : "Save \(model.selection.count)") { model.saveItems() }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(model.selection.isEmpty)
                .help("Save the selected items to “\(model.saveFolderName)” (⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var counts: String {
        var parts = ["\(model.items.count) found"]
        if model.visible.count != model.items.count { parts.append("\(model.visible.count) shown") }
        if !model.selection.isEmpty {
            parts.append("\(model.selection.count) selected")
            let bytes = model.selectedItems.compactMap(\.displayBytes).reduce(0, +)
            if bytes > 0 { parts.append(Format.bytes(bytes)) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Always-visible filters: media type and a minimum-resolution slider (SPEC R-1006a).
struct QuickFilterBar: View {
    @Bindable var model: WindowModel
    static let stops = [0, 100, 200, 300, 400, 500, 640, 800, 1000, 1200, 1500, 1920, 2400, 3000, 4000]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ChipToggle(title: "All", isOn: Binding(get: { model.filter.kinds.isEmpty }, set: { _ in model.filter.kinds = [] }))
                        kindChip("Images", [.image])
                        kindChip("Animated", [.animatedImage])
                        kindChip("Videos", [.video, .stream])
                        kindChip("Audio", [.audio])
                        kindChip("SVG", [.vector])
                        Divider().frame(height: 14)
                        ChipToggle(title: "This Page", isOn: $model.filter.currentPageOnly)
                            .help("Only media from the page in the current tab")
                    }
                }
                .scrollClipDisabled(false)
                Button {
                    model.showFilters.toggle()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(model.showFilters ? "Fewer Filters" : "More Filters", systemImage: "slider.horizontal.3")
                            .fixedSize()
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                .buttonStyle(.borderless)
                .layoutPriority(1)
                .help("All filters: format, file size, shape, source, domain and more (⌘F)")
            }
            HStack(spacing: 8) {
                Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                Slider(value: sliderIndex, in: 0 ... Double(Self.stops.count - 1), step: 1)
                    .controlSize(.small)
                    .frame(minWidth: 70)
                    .help("Hides media smaller than this on its longest side")
                Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
                Text(label)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 64, alignment: .leading)
                Spacer(minLength: 0)
                // The count gives way first when the pane is narrow.
                Text("\(model.visible.count) of \(model.items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func kindChip(_ title: String, _ kinds: Set<MediaKind>) -> some View {
        ChipToggle(title: title, isOn: Binding(
            get: { !model.filter.kinds.isEmpty && kinds.isSubset(of: model.filter.kinds) },
            set: { on in
                if on { model.filter.kinds.formUnion(kinds) } else { model.filter.kinds.subtract(kinds) }
            }
        ))
    }

    private var sliderIndex: Binding<Double> {
        Binding(
            get: {
                let value = model.filter.minLongSide ?? 0
                return Double(Self.stops.lastIndex { $0 <= value } ?? 0)
            },
            set: { index in
                let value = Self.stops[max(0, min(Self.stops.count - 1, Int(index.rounded())))]
                model.filter.minLongSide = value == 0 ? nil : value
            }
        )
    }

    private var label: String {
        guard let value = model.filter.minLongSide, value > 0 else { return "Any size" }
        return "At least \(value) px"
    }
}

/// Shows more or fewer items at once by resizing the thumbnails (SPEC R-1001a). Pinch on the grid,
/// ⌘+ and ⌘- do the same.
struct ZoomSlider: View {
    @Binding var size: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Button { size = max(WindowModel.zoomRange.lowerBound, size - 40) } label: {
                Image(systemName: "square.grid.3x3").font(.system(size: 10))
            }
            .help("Zoom out: more items")
            Slider(value: $size, in: WindowModel.zoomRange)
                .controlSize(.mini)
                .frame(width: 96)
                .help("Thumbnail size")
                .accessibilityLabel("Zoom")
            Button { size = min(WindowModel.zoomRange.upperBound, size + 40) } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 13))
            }
            .help("Zoom in: larger items")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}
