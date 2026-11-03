import Foundation
import SwiftUI

// MARK: - Editor

/// Add, rename, rewrite and delete presets. Works on a draft; Save writes
/// the list back (to the file, or to the server the client mirrors).
struct InstructionPresetEditor: View {
    @ObservedObject var store: InstructionPresetStore
    /// The preset to show first (the one picked on the New session screen).
    var initial: UUID? = nil
    let onDone: () -> Void

    @State private var draft: [InstructionPreset] = []
    @State private var selection: UUID?

    var body: some View {
        content
            .onAppear {
                draft = store.presets
                selection = initial.flatMap { id in draft.first { $0.id == id }?.id } ?? draft.first?.id
            }
    }

    private var changed: Bool { draft != store.presets }

    private func add() {
        let p = InstructionPreset(name: NSLocalizedString("New instructions", comment: "instruction preset default name"),
                                  text: "")
        draft.append(p)
        selection = p.id
    }

    private func delete(_ id: UUID) {
        guard let i = draft.firstIndex(where: { $0.id == id }) else { return }
        draft.remove(at: i)
        selection = draft.indices.contains(i) ? draft[i].id : draft.last?.id
    }

    private func save() {
        store.replace(draft)
        onDone()
    }

    private func binding(_ id: UUID) -> Binding<InstructionPreset>? {
        guard let i = draft.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { draft.indices.contains(i) ? draft[i] : InstructionPreset(name: "", text: "") },
                       set: { if draft.indices.contains(i) { draft[i] = $0 } })
    }

    private static let explanation = NSLocalizedString(
        "Added to the agent's system prompt when a session starts with them. Describe who the agent should be and how it should work — “You are a…”.",
        comment: "instruction preset editor")
    private static let unusableNote = NSLocalizedString(
        "Instructions without a name or text are not kept.", comment: "instruction preset editor")

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(draft) { p in
                            Text(p.name.isEmpty ? NSLocalizedString("Untitled", comment: "instruction preset") : p.name)
                                .foregroundStyle(p.isUsable ? .primary : .secondary)
                                .tag(p.id)
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    HStack(spacing: 2) {
                        Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 20) }
                            .help(NSLocalizedString("Add instructions", comment: "instruction preset editor"))
                        Button { if let s = selection { delete(s) } } label: {
                            Image(systemName: "minus").frame(width: 22, height: 20)
                        }
                        .disabled(selection == nil)
                        .help(NSLocalizedString("Delete these instructions", comment: "instruction preset editor"))
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 200)
                Divider()
                Group {
                    if let s = selection, let b = binding(s) {
                        form(b)
                    } else {
                        Text(NSLocalizedString("No instructions yet. Add some with +.", comment: "instruction preset editor"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                if draft.contains(where: { !$0.isUsable }) {
                    Text(Self.unusableNote).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Save", comment: "")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed)
            }
            .padding(12)
        }
        .frame(width: 680, height: 440)
    }

    private func form(_ p: Binding<InstructionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(NSLocalizedString("Name", comment: "instruction preset editor"), text: p.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
            TextEditor(text: p.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.platformTextBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.acHairline))
            Text(Self.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #else
    private var content: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft) { p in
                        NavigationLink(value: p.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name.isEmpty ? NSLocalizedString("Untitled", comment: "instruction preset") : p.name)
                                Text(p.text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .onDelete { idx in draft.remove(atOffsets: idx) }
                } footer: {
                    Text(Self.explanation + (draft.contains(where: { !$0.isUsable }) ? "\n" + Self.unusableNote : ""))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let b = binding(id) {
                    Form {
                        TextField(NSLocalizedString("Name", comment: "instruction preset editor"), text: b.name)
                        Section {
                            TextEditor(text: b.text).frame(minHeight: 220)
                        }
                    }
                    .navigationTitle(b.wrappedValue.name)
                }
            }
            .navigationTitle(NSLocalizedString("Instructions", comment: "instruction preset editor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "")) { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Save", comment: "")) { save() }.disabled(!changed)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(action: add) {
                        Label(NSLocalizedString("Add instructions", comment: "instruction preset editor"),
                              systemImage: "plus")
                    }
                }
            }
        }
    }
    #endif
}
