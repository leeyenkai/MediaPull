import MediaPullCore
import SwiftUI

/// Map & Timeline (section 44): where and when the files of the Source or Target pane last worked in were taken, as that
/// pane shows them. Choosing here selects there.
struct OrganiseMapPane: View {
    @Bindable var model: WindowModel
    @Bindable var organise: OrganiseModel
    @State private var showing: Showing = .map
    @State private var selectingArea = false
    private var app: AppModel { .shared }

    enum Showing: String, CaseIterable {
        case map, timeline

        var label: String { self == .map ? "Map" : "Timeline" }
    }

    /// The pane followed: the Source or Target worked in last (R-4401).
    private var pane: OrganisePane { model.lastOrganiseFolderPane == .organiseTarget ? organise.target : organise.source }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "", pane: .organiseMap, model: model) {
                ChipTabs(selection: $showing, items: Showing.allCases, label: \.label).fixedSize()
                Spacer(minLength: 4)
                Text(pane.role == .source ? "Source" : "Target").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if pane.root == nil {
                Text("Choose a folder in the \(pane.role == .source ? "Source" : "Target") pane.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showing == .map {
                mapView
            } else {
                TimelineView(entries: pane.shown, gap: app.preferences.eventGapHours * 3600) { select($0) }
            }
        }
    }

    /// Choosing in the map or timeline is choosing in the pane (R-4404).
    private func select(_ paths: [String]) {
        pane.selection = Set(paths)
        pane.revision += 1
        pane.gridSelectionChanged(pane.selection)
    }

    private var points: [MapClusters.Point] {
        pane.shown.compactMap { entry in
            guard let lat = entry.facts?.latitude, let lon = entry.facts?.longitude else { return nil }
            return MapClusters.Point(id: entry.path, latitude: lat, longitude: lon)
        }
    }

    @ViewBuilder private var mapView: some View {
        let points = points
        let unanalysed = pane.shown.count { $0.record == nil }
        VStack(spacing: 0) {
            if app.preferences.showMaps {
                LocationClusterMap(points: points, onChoose: { select($0) }, selectingArea: $selectingArea)
                    // A new folder or new filters frame the map again.
                    .id("\(pane.folder?.path ?? "")|\(pane.revision == 0 ? 0 : points.count)")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "map").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text("Maps load images from Apple, so they are off until you show them.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Show Map") { app.preferences.showMaps = true }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Text(summary(points: points.count, unanalysed: unanalysed))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if app.preferences.showMaps {
                    Toggle("Select Area", isOn: $selectingArea).toggleStyle(.button).controlSize(.small)
                        .help("Draw a rectangle on the map to select the files taken inside it")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func summary(points: Int, unanalysed: Int) -> String {
        var parts = ["\(points) with a location"]
        let without = pane.shown.count - points - unanalysed
        if without > 0 { parts.append("\(without) without one") }
        if unanalysed > 0 { parts.append("\(unanalysed) not analysed yet") }
        return parts.joined(separator: " · ")
    }
}

/// The timeline (R-4403): bars per day, month or year, dragged across to choose a range, above the events.
private struct TimelineView: View {
    let entries: [MediaEntry]
    let gap: TimeInterval
    var onChoose: ([String]) -> Void
    @State private var scale: Timeline.Scale?
    @State private var dragFrom: CGFloat?
    @State private var dragTo: CGFloat?

    var body: some View {
        let dated = entries.map { (id: $0.path, date: $0.date) }
        let first = dated.map(\.date).min() ?? Date(), last = dated.map(\.date).max() ?? Date()
        let chosenScale = scale ?? Timeline.scale(from: first, to: last)
        let buckets = Timeline.buckets(dated, scale: chosenScale)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Show", selection: Binding(get: { chosenScale }, set: { scale = $0 })) {
                    ForEach(Timeline.Scale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let range = rangeLabel(buckets) { Text(range).font(.caption).foregroundStyle(.secondary) }
            }
            strip(buckets)
                .frame(height: 90)
            Text("Drag across the bars to choose a range.").font(.caption).foregroundStyle(.secondary)
            Divider()
            events
        }
        .padding(10)
    }

    private func strip(_ buckets: [Timeline.Bucket]) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let tallest = max(buckets.map(\.ids.count).max() ?? 1, 1)
            let step = buckets.isEmpty ? 0 : width / CGFloat(buckets.count)
            Canvas { context, _ in
                for (index, bucket) in buckets.enumerated() where !bucket.ids.isEmpty {
                    let barHeight = max(2, height * CGFloat(bucket.ids.count) / CGFloat(tallest))
                    let rect = CGRect(x: CGFloat(index) * step + step * 0.1, y: height - barHeight, width: max(step * 0.8, 1),
                                      height: barHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, step * 0.2)), with: .color(.accentColor))
                }
                if let from = dragFrom, let to = dragTo {
                    let rect = CGRect(x: min(from, to), y: 0, width: abs(to - from), height: height)
                    context.fill(Path(rect), with: .color(.accentColor.opacity(0.15)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragFrom = value.startLocation.x
                    dragTo = value.location.x
                }
                .onEnded { value in
                    guard step > 0 else { return }
                    let low = Int(max(0, min(value.startLocation.x, value.location.x)) / step)
                    let high = Int(min(width - 1, max(value.startLocation.x, value.location.x)) / step)
                    let chosen = buckets[min(low, buckets.count - 1) ... min(high, buckets.count - 1)].flatMap(\.ids)
                    onChoose(chosen)
                })
        }
    }

    private func rangeLabel(_ buckets: [Timeline.Bucket]) -> String? {
        guard let first = buckets.first?.start, let last = buckets.last?.start else { return nil }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Events newest first, with their place and a count; choosing one selects its files.
    private var events: some View {
        var query = LibraryQuery()
        query.eventGap = gap
        let sections = query.events(entries).reversed()
        return List(Array(sections.enumerated()), id: \.offset) { _, section in
            Button {
                onChoose(section.items.map(\.path))
            } label: {
                HStack {
                    Text(section.title ?? "Undated").lineLimit(1)
                    Spacer()
                    Text("\(section.items.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }
}
