import MediaPullCore
import SwiftUI

/// The scratchpad in Collect's title bar (D-109, R-706): notes on the left, the chosen note's text on the right.
struct NotesView: View {
    @Bindable var store: NotesStore
    @State private var selection: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list
                    .frame(width: 190)
                Divider()
                editor
            }
            if let problem = store.problem {
                Divider()
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .onAppear { if selection == nil { selection = store.notes.notes.first?.id } }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete Note", role: .destructive) {
                guard let id = selection else { return }
                store.delete(id)
                selection = store.notes.notes.first?.id
            }
        } message: {
            Text("“\(selection.flatMap { store.notes[$0] }?.title ?? "")” is removed for good.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                Button {
                    selection = store.add().id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New Note")
                .help("New Note")
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .accessibilityLabel("Delete Note")
                .help("Delete Note")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if store.notes.notes.isEmpty {
                VStack(spacing: 8) {
                    Text("No notes yet").foregroundStyle(.secondary)
                    Button("New Note") { selection = store.add().id }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.notes.notes, selection: $selection) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        Text(note.preview.isEmpty ? note.modified.formatted(date: .abbreviated, time: .shortened) : note.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(note.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, store.notes[id] != nil {
            TextEditor(text: Binding(get: { store.notes[id]?.text ?? "" }, set: { store.update(id, text: $0) }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
        } else {
            Text("Choose a note, or make a new one.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
