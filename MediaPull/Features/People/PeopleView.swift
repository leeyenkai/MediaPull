import MediaPullCore
import MediaPullStore
import SwiftUI

/// People recognised in the library (SPEC section 39): name, merge, split and correct.
struct PeopleView: View {
    /// Shown inside the Organise pane rather than on its own.
    var inline = false
    @State private var selected: UUID?
    @State private var faces: [(key: String, path: String, box: FaceBox?)] = []
    @State private var chosenFaces: Set<String> = []
    @State private var nameDraft = ""
    @State private var mergeTarget: UUID?
    @Environment(\.dismiss) private var dismiss
    private var app: AppModel {
        .shared
    }

    private func toggleFace(_ key: String) {
        if chosenFaces.contains(key) { chosenFaces.remove(key) } else { chosenFaces.insert(key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !inline { Text("People").font(.title2.weight(.semibold)) }
                Spacer()
                if app.preferences.facesEnabled {
                    Button("Regroup") { Task { await app.analysis.regroupFaces(full: true) } }
                        .help("Group faces again; names, merges and corrections are kept. " + FaceOptIn.limits)
                        .controlSize(inline ? .small : .regular)
                }
                if !inline { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) } // lint:allow shortcut shown only in a sheet
            }
            if !app.preferences.facesEnabled {
                FaceOptIn()
            } else if app.analysis.people.isEmpty {
                Text(app.analysis
                    .isRunning ? "Looking for people…" :
                    "No people found yet. People appear once at least two photos of someone are analysed.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    List(selection: $selected) {
                        ForEach(app.analysis.people.filter { $0.faceCount > 0 }) { person in
                            PersonRow(person: person, suggestion: app.analysis.suggestions[person.id]).tag(person.id)
                        }
                    }
                    .frame(minWidth: 200, minHeight: 120, idealHeight: 200)
                    detail.frame(minWidth: 240, minHeight: 200)
                }
            }
            if !inline {
                Text(FaceOptIn.limits).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(inline ? 0 : 20)
        .frame(width: inline ? nil : 820, height: inline ? nil : 600)
        .onChange(of: selected) { _, id in load(id) }
        .onChange(of: app.analysis.peopleRevision) { _, _ in load(selected) }
    }

    private func load(_ id: UUID?) {
        chosenFaces = []
        guard let id else { faces = []; return }
        nameDraft = app.analysis.people.first { $0.id == id }?.name ?? ""
        Task {
            // A slower load for a person selected earlier must not show that person's faces under this one.
            let loaded = await app.analysis.faces(of: id)
            if selected == id { faces = loaded }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let person = app.analysis.people.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                if let suggestion = app.analysis.suggestions[id] {
                    HStack {
                        Image(systemName: "folder.badge.person.crop")
                        Text("\(suggestion)? The folder “\(suggestion)” holds most of these photos.")
                        Spacer()
                        Button("Use Name") { Task { await app.analysis.rename(id, to: suggestion) } }
                        Button("Dismiss") { Task { await app.analysis.dismissSuggestion(id) } }
                    }
                    .font(.callout)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    TextField("Name", text: $nameDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        .onSubmit { Task { await app.analysis.rename(id, to: nameDraft) } }
                    Button("Rename") { Task { await app.analysis.rename(id, to: nameDraft) } }
                    Spacer()
                    Picker("Merge into", selection: $mergeTarget) {
                        Text("Merge Into…").tag(UUID?.none)
                        ForEach(app.analysis.people.filter { $0.id != id && $0.faceCount > 0 }) { Text($0.displayName).tag(Optional($0.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: mergeTarget) { _, target in
                        guard let target else { return }
                        mergeTarget = nil
                        Task {
                            await app.analysis.merge(id, into: target)
                            selected = target
                        }
                    }
                }
                Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s"). Select photos to split them off or remove them.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(faces, id: \.key) { face in
                            FaceThumb(path: face.path, box: face.box)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                    chosenFaces.contains(face.key) ? Color.accentColor : .clear,
                                    lineWidth: 3
                                ))
                                .onTapGesture { toggleFace(face.key) }
                                .help(face.path)
                                .accessibilityElement()
                                .accessibilityLabel("Photo \(URL(fileURLWithPath: face.path).lastPathComponent)")
                                .accessibilityAddTraits(chosenFaces.contains(face.key) ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { toggleFace(face.key) }
                        }
                    }
                }
                HStack {
                    Button("Split Into New Person") {
                        let keys = Array(chosenFaces)
                        Task { await app.analysis.split(keys, from: id) }
                    }
                    .disabled(chosenFaces.isEmpty)
                    Button("Not This Person") {
                        let keys = Array(chosenFaces)
                        Task { await app.analysis.notThisPerson(keys, person: id) }
                    }
                    .disabled(chosenFaces.isEmpty)
                }
            }
        } else {
            Text("Choose a person").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PersonRow: View {
    let person: PersonInfo
    let suggestion: String?
    @State private var face: (path: String, box: FaceBox?)?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if let face {
                    FaceThumb(path: face.path, box: face.box, side: 32)
                } else {
                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(person.displayName).lineLimit(1)
                Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let suggestion {
                // One click names the person from the folder their photos are in (R-3905).
                Button("\(suggestion)?") { Task { await AppModel.shared.analysis.rename(person.id, to: suggestion) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Name this person “\(suggestion)”, from the folder holding most of their photos")
            }
        }
        .task(id: person.id) {
            if let first = await AppModel.shared.analysis.faces(of: person.id, limit: 1).first { face = (first.path, first.box) }
        }
    }
}

/// A face cut from its photo.
struct FaceThumb: View {
    let path: String
    let box: FaceBox?
    var side: CGFloat = 84
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) {
            guard let full = await AppModel.shared.thumbnails.localThumbnail(for: URL(fileURLWithPath: path), maxPixel: 640)?.image
            else { return }
            guard let box else { image = full; return }
            let w = CGFloat(full.width), h = CGFloat(full.height)
            let side = max(box.width * w, box.height * h) * 1.5
            let rect = CGRect(
                x: box.x * w + box.width * w / 2 - side / 2,
                y: box.y * h + box.height * h / 2 - side / 2,
                width: side,
                height: side
            )
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            image = full.cropping(to: rect.integral) ?? full
        }
    }
}

/// The opt-in for recognising people (R-3901, D-61).
struct FaceOptIn: View {
    @State private var confirmDelete = false
    private var app: AppModel {
        .shared
    }

    static let limits =
        "Faces turned well away from the camera are matched less reliably, children's faces change with age and are confused more "
        + "often, and very small faces are not used. Corrections you make are kept."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recognise people in your photos", systemImage: "person.2.badge.gearshape").font(.headline)
            Text("MediaPull can group photos of the same person so you can name them, find them and sort them into folders. "
                + "Face data is biometric: it is computed and kept only on this Mac, never written into your folders, metadata files or "
                    + "exports, "
                + "and can be deleted in one step at any time.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn On") { app.analysis.enableFaces() }.buttonStyle(.borderedProminent)
                Button("Delete All Face Data…") { confirmDelete = true }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Delete all face data?", isPresented: $confirmDelete) {
            Button("Delete All Face Data", role: .destructive) { Task { await app.analysis.deleteAllFaceData() } }
        } message: {
            Text(
                """
                    People, names, corrections and face measurements are removed and recognising people is turned off. Your photos are not \
                    touched.
                    """
            )
        }
    }
}
