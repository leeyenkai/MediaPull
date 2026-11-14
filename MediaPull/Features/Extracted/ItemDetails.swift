import MediaPullCore
import MediaPullLibrary
import MediaPullStore
import SwiftUI

/// Details of an extracted item, shown under its preview (SPEC R-1009).
struct ItemDetails: View {
    @Bindable var model: WindowModel
    var item: MediaItem
    private var app: AppModel { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let state = model.states[item.id] {
                    StateLine(state: state)
                }

                InfoGrid(rows: details)

                if let engine = item.source.engine, let description = engine.description?.nonEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Caption").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(description).font(.callout).textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Versions found").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(item.variants.filter { $0.origin != .engineThumbnail }, id: \.id) { variant in
                        VariantRow(variant: variant, chosen: variant.id == item.bestID)
                    }
                    if item.variants.contains(where: { $0.isDerived && $0.check == .unverified }) {
                        Button("Check Original Sizes") { model.ensureProbed(item) }
                            .controlSize(.small)
                    }
                }

                if let name = plannedName {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Will be saved as").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(name).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Save to Library") { model.saveToLibrary([item]) }
                        .buttonStyle(.borderedProminent)
                    Button("Save to…") { model.saveTo([item]) }
                    Button(item.kind == .image ? "Edit" : (item.kind == .video ? "Edit Video" : "Rename")) { model.edit(item.id) }
                }
                .controlSize(.small)
                HStack {
                    if let url = item.best?.url, url.scheme == "https" || url.scheme == "http" {
                        Button("Copy URL") { Format.copy(url.absoluteString) }
                        Button("Open") { model.browser.load(url) }
                    }
                    Button("Quick Look") { model.gridQuickLook() }
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var details: [(String, String)] {
        var rows: [(String, String)] = [("Type", item.kind.label)]
        if let format = item.displayFormat { rows.append(("Format", format.label)) }
        if let size = item.displaySize { rows.append(("Dimensions", "\(size.width) × \(size.height) px")) }
        if let bytes = item.displayBytes { rows.append(("File size", Format.bytes(bytes))) }
        if let duration = item.duration { rows.append(("Duration", Format.duration(duration))) }
        switch item.source {
        case let .web(web):
            rows.append(("Page", web.pageTitle ?? web.pageURL.host ?? ""))
            if !web.isMainFrame, let origin = web.frameOrigin { rows.append(("Frame", origin)) }
        case let .engine(engine):
            if engine.isInstagram {
                rows.append(("Account", engine.username.map { "@\($0)" } ?? ""))
                rows.append(("Section", engine.instagramSection.capitalized))
                if let num = engine.num, let count = engine.count, count > 1 { rows.append(("Position", "\(num) of \(count)")) }
                if let code = engine.postShortcode { rows.append(("Post", code)) }
            } else {
                rows.append(("Extractor", "\(engine.category) \(engine.subcategory)"))
                if let user = engine.username { rows.append(("User", user)) }
            }
            if let date = engine.date { rows.append(("Date", date.formatted(date: .abbreviated, time: .shortened))) }
            if let width = engine.originalWidth, let height = engine.originalHeight, width > 0 {
                rows.append(("Original upload", "\(width) × \(height) px"))
            }
        }
        if let page = item.source.web?.documentPage { rows.append(("PDF page", "\(page)")) }
        if let alt = item.alt?.nonEmpty, item.source.engine == nil { rows.append(("Description", alt)) }
        if item.flags.contains(.protected) { rows.append(("Protection", "DRM or encryption: cannot be saved")) }
        if item.flags.contains(.insecure) { rows.append(("Connection", "Not encrypted (http)")) }
        return rows
    }

    private var plannedName: String? {
        let format = model.predictedFormat(item)
        let root = app.lastSaveFolderURL.flatMap { app.root(containing: $0) } ?? app.defaultRoot
        let layout = root?.layout ?? app.preferences.defaultLayout
        let info = FinalFileInfo(format: format, sha256: "0000000000", pixelSize: item.displaySize, duration: item.duration,
                                 sourceURL: item.best?.url, lastModified: nil,
                                 originalName: item.best.flatMap { URLNormalizer.baseName(of: $0.url) }, note: nil)
        let name = ArchivePlanner.fileName(for: item, info: info, layout: layout, settings: app.saveSettings, index: item.discoveryIndex + 1,
                                           saveDate: Date(), override: model.customNames[item.id])
        return name
    }
}

struct StateLine: View {
    var state: ItemState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch state {
            case .queued:
                Image(systemName: "clock")
                Text("Waiting to save")
            case let .saving(fraction):
                ProgressView(value: fraction ?? 0).frame(width: 80)
                Text("Saving")
            case let .saved(url), let .duplicate(url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            case let .skipped(reason):
                Image(systemName: "minus.circle")
                Text(reason)
            case let .failed(reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct InfoGrid: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled).lineLimit(3)
                }
            }
        }
        .font(.callout)
    }
}

struct VariantRow: View {
    var variant: MediaVariant
    var chosen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: chosen ? "checkmark.circle.fill" : status)
                .foregroundStyle(chosen ? .green : .secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).font(.caption)
                Text(variant.url.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var status: String {
        switch variant.check {
        case .unverified: "questionmark.circle"
        case .verified: "circle"
        case .failed: "xmark.circle"
        }
    }

    private var summary: String {
        var parts = [variant.origin.label]
        if let size = variant.pixelSize { parts.append(size.label) } else if let width = variant.declaredWidth { parts.append("\(width)w") }
        if let format = variant.format { parts.append(format.label) }
        if let bytes = variant.byteCount { parts.append(Format.bytes(bytes)) }
        if case .failed = variant.check { parts.append("not available") }
        if variant.isDerived, variant.check == .unverified { parts.append("unchecked") }
        return parts.joined(separator: " · ")
    }
}
