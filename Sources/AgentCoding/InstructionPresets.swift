import Foundation
import SwiftUI

// MARK: - Session instructions
//
// Named blocks of text appended to an agent's system prompt ("You are a
// careful reviewer…"), picked on the New session screen. They belong to the
// Mac that runs the machines: a fat client — another Mac, an iPhone or an
// iPad — mirrors that Mac's list and edits it there, so every device offers
// the same ones. The text a session started with is kept on the session, so
// a resume gives the agent the same instructions again.

struct InstructionPreset: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var text: String

    /// Ready to offer: something to call it and something to say.
    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a new install starts with — examples to edit or delete.
    static var examples: [InstructionPreset] {
        [
            InstructionPreset(
                name: NSLocalizedString("Careful reviewer", comment: "instruction preset example name"),
                text: NSLocalizedString("You are a meticulous senior engineer reviewing changes before they ship. Look for bugs, edge cases and security issues first, explain your reasoning, and prefer small, well-tested changes over large rewrites.", comment: "instruction preset example text")),
            InstructionPreset(
                name: NSLocalizedString("Teacher", comment: "instruction preset example name"),
                text: NSLocalizedString("You are a patient teacher. Explain what you are doing and why as you go, in plain language, and point out what the user could learn from each step.", comment: "instruction preset example text")),
        ]
    }
}

/// The presets: a JSON file on the Mac that runs the machines, or a
/// fat client's mirror of that Mac's list (written back through `push`).
@MainActor
final class InstructionPresetStore: ObservableObject {
    @Published private(set) var presets: [InstructionPreset] = []
    private let fileURL: URL?
    private let push: (([InstructionPreset]) -> Void)?

    init(fileURL: URL? = nil) {
        push = nil
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("instruction-presets.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([InstructionPreset].self, from: data) {
            presets = list
        } else {
            presets = InstructionPreset.examples
        }
    }

    /// A fat client's copy: `applyMirror` fills it from the server, edits go
    /// back through `push`.
    init(mirror push: @escaping ([InstructionPreset]) -> Void) {
        fileURL = nil
        self.push = push
    }

    func preset(_ id: UUID?) -> InstructionPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    /// Replace the whole list (the editor saves this way). Unusable rows —
    /// no name or no text — are dropped.
    func replace(_ list: [InstructionPreset]) {
        let kept = list.filter(\.isUsable).map {
            InstructionPreset(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        presets = kept
        if let push { push(kept) } else { save() }
    }

    /// The server's list, as the last poll saw it.
    func applyMirror(_ list: [InstructionPreset]) {
        if list != presets { presets = list }
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The wire form (`/state`'s `instructionPresets`, POST /instruction-presets).
    nonisolated static func wire(_ list: [InstructionPreset]) -> [[String: Any]] {
        list.map { ["id": $0.id.uuidString, "name": $0.name, "text": $0.text] }
    }
    nonisolated static func fromWire(_ list: [[String: Any]]) -> [InstructionPreset] {
        list.compactMap { d in
            guard let name = d["name"] as? String, let text = d["text"] as? String else { return nil }
            let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return InstructionPreset(id: id, name: name, text: text)
        }
    }
}

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
