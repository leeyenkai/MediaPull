import MediaPullCore
import SwiftUI

/// The filter bar (SPEC R-1006).
struct FilterBar: View {
    @Bindable var model: WindowModel
    /// The name being typed for a new preset; nil when not saving one.
    @State private var presetName: String?
    @Bindable private var preferences = AppModel.shared.preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search URLs, names, captions", text: $model.filter.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
            }
            HStack(spacing: 10) {
                NumberField(title: "Min width", value: $model.filter.minWidth)
                NumberField(title: "Min height", value: $model.filter.minHeight)
                SizeField(title: "Min size", bytes: $model.filter.minBytes)
                SizeField(title: "Max size", bytes: $model.filter.maxBytes)
                Picker("Shape", selection: $model.filter.aspect) {
                    ForEach(AspectFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 10) {
                Menu(formatTitle) {
                    ForEach(MediaFormat.allCases, id: \.self) { format in
                        Toggle(format.label, isOn: Binding(
                            get: { model.filter.formats.contains(format) },
                            set: { on in
                                if on { model.filter.formats.insert(format) } else { model.filter.formats.remove(format) }
                            }
                        ))
                    }
                    Divider()
                    Button("Any Format") { model.filter.formats = [] }
                }
                .fixedSize()
                Menu(sourceTitle) {
                    ForEach(SourceGroup.allCases, id: \.self) { source in
                        Toggle(source.label, isOn: Binding(
                            get: { model.filter.sources.contains(source) },
                            set: { on in
                                if on { model.filter.sources.insert(source) } else { model.filter.sources.remove(source) }
                            }
                        ))
                    }
                    Divider()
                    Button("Any Source") { model.filter.sources = [] }
                }
                .fixedSize()
                Menu(instagramTitle) {
                    ForEach(["posts", "reels", "stories", "highlights", "avatar"], id: \.self) { section in
                        Toggle(section.capitalized, isOn: Binding(
                            get: { model.filter.instagramSections.contains(section) },
                            set: { on in
                                if on {
                                    model.filter.instagramSections.insert(section)
                                } else {
                                    model.filter.instagramSections.remove(section)
                                }
                            }
                        ))
                    }
                    Divider()
                    Button("All Instagram Items") { model.filter.instagramSections = [] }
                }
                .fixedSize()
                Menu(stateTitle) {
                    ForEach(SaveStateFilter.allCases, id: \.self) { state in
                        Toggle(state.label, isOn: Binding(
                            get: { model.filter.states.contains(state) },
                            set: { on in
                                if on { model.filter.states.insert(state) } else { model.filter.states.remove(state) }
                            }
                        ))
                    }
                }
                .fixedSize()
                TextField("Only domains", text: $model.filter.includeDomains)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                TextField("Hide domains", text: $model.filter.excludeDomains)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
            }
            HStack(spacing: 14) {
                Toggle("Hide tiny", isOn: $model.filter.hideTiny)
                Toggle("Hide icons", isOn: $model.filter.hideIcons)
                Toggle("Hide duplicates", isOn: $model.filter.hideDuplicates)
                Toggle("Same site", isOn: $model.filter.sameSiteOnly)
                Toggle("This page only", isOn: $model.filter.currentPageOnly)
                Toggle("Exclude unknown sizes", isOn: $model.filter.excludeUnknown)
                Spacer()
                Button("Reset") { model.filter = MediaFilter() }
                    .disabled(model.filter == MediaFilter())
            }
            .toggleStyle(.checkbox)
            presets
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }

    /// Named presets (R-1008): choose one, save the current filters under a name typed in place, or delete one.
    private var presets: some View {
        HStack(spacing: 8) {
            if let name = presetName {
                TextField("Preset name", text: Binding(get: { name }, set: { presetName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(savePreset)
                Button("Save", action: savePreset)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { presetName = nil }
            } else {
                Menu("Presets") {
                    ForEach(preferences.filterPresets) { preset in
                        Button(preset.name) { model.filter = preset.filter }
                    }
                    if !preferences.filterPresets.isEmpty {
                        Divider()
                        Menu("Delete") {
                            ForEach(preferences.filterPresets) { preset in
                                Button(preset.name) { preferences.filterPresets.removeAll { $0.name == preset.name } }
                            }
                        }
                    }
                }
                .fixedSize()
                Button("Save as Preset…") { presetName = "" }
            }
            Spacer()
        }
    }

    private func savePreset() {
        guard let raw = presetName else { return }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var kept = model.filter
        kept.text = ""
        // A preset with the same name is replaced; the list stays in name order.
        preferences.filterPresets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        preferences.filterPresets.append(FilterPreset(name: name, filter: kept))
        preferences.filterPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        presetName = nil
    }

    private var formatTitle: String {
        model.filter.formats.isEmpty ? "Any format" : model.filter.formats.map(\.label).sorted().joined(separator: ", ")
    }

    private var sourceTitle: String {
        model.filter.sources.isEmpty ? "Any source" : "\(model.filter.sources.count) sources"
    }

    private var instagramTitle: String {
        model.filter.instagramSections.isEmpty
            ? "Instagram: all"
            : model.filter.instagramSections.sorted().joined(separator: ", ").capitalized
    }

    private var stateTitle: String {
        model.filter.states.isEmpty ? "Any state" : model.filter.states.map(\.label).sorted().joined(separator: ", ")
    }
}

struct ChipToggle: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(isOn ? AppModel.shared.preferences.theme.accent.opacity(0.88) : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct NumberField: View {
    var title: String
    @Binding var value: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField("any", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("px").foregroundStyle(.secondary)
        }
    }
}

struct SizeField: View {
    var title: String
    @Binding var bytes: Int64?

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField("any", value: Binding(
                get: { bytes.map { Double($0) / 1024 } },
                set: { newValue in bytes = newValue.map { Int64($0 * 1024) } }
            ), format: .number.precision(.fractionLength(0 ... 1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("KB").foregroundStyle(.secondary)
        }
    }
}
