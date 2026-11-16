import MediaPullCore
import MediaPullLibrary
import SwiftUI

/// Settings > Analysis and Organise (SPEC sections 20, 36 to 38).
struct AnalysisSettings: View {
    @Bindable var preferences = AppModel.shared.preferences
    @State private var newSubject = ""
    @State private var confirmDelete = false
    private var app: AppModel {
        .shared
    }

    var body: some View {
        Form {
            Section {
                Toggle("Analyse library media", isOn: Binding(get: { preferences.analysisEnabled }, set: {
                    preferences.analysisEnabled = $0
                    if $0 {
                        app.analysis.schedule()
                    } else {
                        app.analysis.cancelScan()
                    }
                }))
                Toggle("Pause on battery", isOn: $preferences.analysisPauseOnBattery)
                ForEach(app.roots) { root in
                    Toggle(root.name, isOn: Binding(get: { !preferences.analysisExcludedRoots.contains(root.url.path) }, set: { on in
                        if on {
                            preferences.analysisExcludedRoots.remove(root.url.path)
                        } else {
                            preferences.analysisExcludedRoots.insert(root.url.path)
                        }
                        app.analysis.updateWatch()
                        app.analysis.schedule()
                    }))
                    .padding(.leading, 12)
                }
                Text("\(app.analysis.analysedCount) files analysed. Analysis finds content, text, places, colours and faces so you can search and sort. "
                    + "It runs on this Mac at low priority; nothing is uploaded and nothing is written into your folders.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Analysis") }
            Section {
                Picker("Confidence needed", selection: $preferences.subjectThreshold) {
                    ForEach([0.3, 0.4, 0.5, 0.6, 0.7, 0.8], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                }
                Text("Below this, files go to Unsorted instead of a guess. In tests at 50 %, 95 % of photos were filed and 95 % of those "
                    + "correctly; at 70 %, 88 % were filed and 96 % correctly.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a subject, such as “cars” or “sunsets”", text: $newSubject)
                        .onSubmit(addSubject)
                    Button("Add", action: addSubject).disabled(newSubject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(preferences.customSubjects, id: \.self) { subject in
                    HStack {
                        Text(subject)
                        Spacer()
                        Button { preferences.customSubjects.removeAll { $0 == subject } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text("Sort by Subject") }
            Section {
                Picker("Event gap", selection: $preferences.eventGapHours) {
                    ForEach([1.0, 2, 3, 6, 12, 24], id: \.self) { Text("\(Int($0)) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
                Picker("Keep undo history for", selection: $preferences.undoHistoryDays) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
                }
            } header: { Text("Organise") }
            Section {
                HStack {
                    Button("Analyse Again") { Task { await app.analysis.analyseAgain() } }
                        .help("Analyses every file again. People, their names and your corrections are kept.")
                    Button("Delete All Analysis Data…") { confirmDelete = true }
                }
            } footer: {
                Text("Results are kept in MediaPull's own data, never in library folders.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all analysis data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await app.analysis.deleteAllAnalysis() } }
        } message: {
            Text(
                "Search by content, the filters that need analysis, and people are emptied until media is analysed again. Your files are not touched."
            )
        }
    }

    private func addSubject() {
        let subject = newSubject.trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty, !preferences.customSubjects.contains(subject) else { return }
        preferences.customSubjects.append(subject)
        newSubject = ""
    }
}

/// Settings > Faces (R-3901).
struct FaceSettings: View {
    @Bindable var preferences = AppModel.shared.preferences
    @State private var confirmDelete = false
    private var app: AppModel {
        .shared
    }

    var body: some View {
        Form {
            if !preferences.facesEnabled {
                Section { FaceOptIn() }
            } else {
                Section {
                    Text("\(app.analysis.people.filter { $0.faceCount > 0 }.count) people found. Face data stays on this Mac and is never written "
                        + "into your folders, metadata files or exports.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Matching", selection: $preferences.faceMatchAdjustment) {
                        Text("Looser (fewer split groups)").tag(-0.05)
                        Text("Standard").tag(0.0)
                        Text("Stricter (fewer wrong matches)").tag(0.05)
                    }
                    .onChange(of: preferences.faceMatchAdjustment) { _, _ in Task { await app.analysis.regroupFaces(full: true) } }
                    Button("Delete All Face Data…") { confirmDelete = true }
                } header: { Text("Recognising People") }
                Section {
                    Picker("Photos of several people", selection: $preferences.groupPhotoPlacement) {
                        ForEach(GroupPhotoPlacement.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Include unnamed people", isOn: $preferences.sortUnnamedPeople)
                    Text("Copies in each person's folder are clones that take no extra space on Mac drives. In Archive-layout folders, photos of "
                        + "several people go into one Group photos folder so each post is kept once.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Sort by Person") }
            }
            Section {
                Text(FaceOptIn.limits).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Accuracy") }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all face data?", isPresented: $confirmDelete) {
            Button("Delete All Face Data", role: .destructive) { Task { await app.analysis.deleteAllFaceData() } }
        } message: {
            Text(
                "People, names, corrections and face measurements are removed and recognising people is turned off. Your photos are not touched."
            )
        }
    }
}
