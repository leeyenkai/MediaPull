import MediaPullCore
import MediaPullStore
import SwiftUI

/// Search field, sort menu, filters and "Include Subfolders" for a grid of files (SPEC section 37).
struct QueryBar: View {
    @Binding var query: LibraryQuery
    @Binding var includeSubfolders: Bool
    /// The files being shown, for the values the filters offer (tags, places, sources, cameras).
    var entries: [MediaEntry]
    /// ⌘F focuses this field when its pane is the one being worked in (SPEC 21); the token changes on each ⌘F.
    var focusToken: Int = 0
    @FocusState private var searchFocused: Bool
    /// The values the filters offer, worked out off the main actor when the files or their analysis change, not on
    /// every redraw (typing in the search field redraws the bar).
    @State private var facets = FilterFacets()
    private var app: AppModel {
        .shared
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(app.analysis.canSearchByMeaning ? "Search names, text and what photos show" : "Search names and text",
                          text: $query.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { query.search = "" }
                    .onChange(of: focusToken) { _, _ in searchFocused = true }
                if !query.search.isEmpty {
                    Button { query.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear Search")
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 90)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sortMenu.labelStyle(.titleAndIcon)
                    FilterMenu(query: $query, facets: facets).labelStyle(.titleAndIcon)
                }
                HStack(spacing: 4) {
                    sortMenu.labelStyle(.iconOnly)
                    FilterMenu(query: $query, facets: facets).labelStyle(.iconOnly)
                }
            }
            .layoutPriority(1)
            Toggle(isOn: $includeSubfolders) { Image(systemName: "square.stack.3d.down.right") }
                .accessibilityLabel("Include Subfolders")
                .toggleStyle(.button)
                .help("Include subfolders")
        }
        .task(id: FilterFacets.signature(entries, analysisRevision: app.analysis.revision, tagConfidence: query.tagConfidence)) {
            let entries = entries, confidence = query.tagConfidence
            facets = await Task.detached(priority: .userInitiated) { FilterFacets(entries, tagConfidence: confidence) }.value
        }
        .controlSize(.small)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $query.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Ascending", isOn: $query.ascending)
            if query.sort == .events {
                // The same event gap as Settings and Sort by Event.
                Picker("Event Gap", selection: Binding(get: { AppModel.shared.preferences.eventGapHours }, set: {
                    AppModel.shared.preferences.eventGapHours = $0
                    query.eventGap = $0 * 3600
                })) {
                    ForEach([1.0, 2, 3, 6, 12, 24], id: \.self) { Text("\(Int($0)) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
            }
        } label: {
            Label(query.sort.label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort")
    }
}

/// The filters (R-3703). Values within a filter combine with OR; different filters with AND.
struct FilterMenu: View {
    @Binding var query: LibraryQuery
    var facets: FilterFacets
    private var app: AppModel {
        .shared
    }

    var body: some View {
        Menu {
            Menu("Kind") {
                ForEach([MediaKind.image, .animatedImage, .video], id: \.self) { kind in toggle(kind.label, $query.filter.kinds, kind) }
            }
            Menu("Format") {
                // The formats in this folder, most common first (R-3703).
                ForEach(facets.formats, id: \.0) { format, count in toggle("\(format.label) (\(count))", $query.filter.formats, format) }
            }
            Menu("Orientation") {
                ForEach(Orientation.allCases, id: \.self) { o in toggle(o.label, $query.filter.orientations, o) }
            }
            Menu("Size") {
                ForEach(
                    [(0, "Any Size"), (1_000_000, "1 MP or More"), (4_000_000, "4 MP or More"), (12_000_000, "12 MP or More")],
                    id: \.0
                ) { value, label in
                    Button(label + (query.filter.minPixels == (value == 0 ? nil : value) ? " ✓" : "")) {
                        query.filter.minPixels = value == 0 ? nil : value
                    }
                }
            }
            Menu("Video Length") {
                ForEach([(nil, nil, "Any Length"), (nil, 30.0, "Under 30 Seconds"), (30.0, 300.0, "30 Seconds to 5 Minutes"),
                         (300.0, nil, "Over 5 Minutes")] as [(Double?, Double?, String)], id: \.2)
                { min, max, label in
                    Button(label + (query.filter.minDuration == min && query.filter.maxDuration == max ? " ✓" : "")) {
                        query.filter.minDuration = min
                        query.filter.maxDuration = max
                    }
                }
            }
            Divider()
            Menu("Screenshots") {
                Button("Screenshots and Photos" + (query.filter.screenshots == nil ? " ✓" : "")) { query.filter.screenshots = nil }
                ForEach(ScreenshotFilter.allCases, id: \.self) { value in
                    Button("Only " + value.label + (query.filter.screenshots == value ? " ✓" : "")) { query.filter.screenshots = value }
                }
            }
            Menu("Faces") {
                Button("Any" + (query.filter.faces == nil ? " ✓" : "")) { query.filter.faces = nil }
                ForEach(FaceFilter.allCases, id: \.self) { value in
                    Button(value.label + (query.filter.faces == value ? " ✓" : "")) { query.filter.faces = value }
                }
            }
            if app.preferences.facesEnabled, !app.analysis.people.isEmpty {
                Menu("People") {
                    ForEach(app.analysis.people.filter { $0.faceCount > 0 }.prefix(40)) { person in
                        toggle("\(person.displayName) (\(person.faceCount))", $query.filter.people, person.id)
                    }
                }
            }
            Menu("Dominant Colour") {
                ForEach(ColourName.allCases, id: \.self) { colour in toggle(colour.label, $query.filter.colours, colour) }
            }
            valueMenu("Content", values: facets.tags, set: $query.filter.tags) { $0.replacingOccurrences(of: "_", with: " ").capitalized }
            valueMenu("Place", values: facets.places, set: $query.filter.places) { $0 }
            valueMenu("Source", values: facets.sources, set: $query.filter.sources) { $0 }
            valueMenu("Camera", values: facets.cameras, set: $query.filter.cameras) { $0 }
            valueMenu("Finder Tags", values: facets.finderTags, set: $query.filter.finderTags) { $0 }
            Toggle("Only Visually Similar Sets", isOn: $query.filter.similarOnly)
            Divider()
            Button("Clear Filters") { query.filter = LibraryFilter() }
                .disabled(query.filter.isEmpty)
        } label: {
            Label(query.filter.isEmpty ? "Filter" : "Filters (\(query.filter.count))", systemImage: query.filter.isEmpty
                ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by kind, size, faces, colour, content, place and more")
    }

    private func toggle<T: Hashable>(_ label: String, _ set: Binding<Set<T>>, _ value: T) -> some View {
        Toggle(label, isOn: Binding(get: { set.wrappedValue.contains(value) }, set: { on in
            if on {
                set.wrappedValue.insert(value)
            } else {
                set.wrappedValue.remove(value)
            }
        }))
    }

    @ViewBuilder
    private func valueMenu(_ title: String, values: [(String, Int)], set: Binding<Set<String>>,
                           label: @escaping (String) -> String) -> some View
    {
        if !values.isEmpty {
            Menu(title) {
                ForEach(values.prefix(40), id: \.0) { value, count in toggle("\(label(value)) (\(count))", set, value) }
            }
        }
    }
}

/// Progress of analysis, for the Library and Organise headers.
struct AnalysisStatus: View {
    private var app: AppModel {
        .shared
    }

    var body: some View {
        if let progress = app.analysis.progress {
            HStack(spacing: 5) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 50)
                Text(app.analysis.pauseReason ?? "Analysing \(progress.done) of \(progress.total)").lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Media is analysed on this Mac for search and sorting. Nothing leaves the Mac.")
        }
    }
}

/// The values each filter offers, with how many files have them (R-3703).
struct FilterFacets: Sendable {
    var formats: [(MediaFormat, Int)] = []
    var tags: [(String, Int)] = []
    var places: [(String, Int)] = []
    var sources: [(String, Int)] = []
    var cameras: [(String, Int)] = []
    var finderTags: [(String, Int)] = []

    init() {}

    nonisolated init(_ entries: [MediaEntry], tagConfidence: Float) {
        formats = Dictionary(grouping: entries.compactMap(\.format), by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.label < $1.0.label }
        tags = Self.counted(entries.flatMap { ($0.record?.labels ?? []).filter { $0.confidence >= tagConfidence }.map(\.identifier) })
        places = Self.counted(entries.compactMap { $0.record?.place?.display })
        sources = Self.counted(entries.compactMap { $0.source?.sourceName })
        cameras = Self.counted(entries.compactMap { $0.facts?.camera })
        finderTags = Self.counted(entries.flatMap(\.finderTags))
    }

    nonisolated static func counted(_ values: [String]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }

    /// Cheap to work out on every redraw: changes when the files, their analysis or the tag threshold change.
    static func signature(_ entries: [MediaEntry], analysisRevision: Int, tagConfidence: Float) -> String {
        "\(entries.count)|\(entries.first?.path ?? "")|\(entries.last?.path ?? "")|\(analysisRevision)|\(tagConfidence)"
    }
}
