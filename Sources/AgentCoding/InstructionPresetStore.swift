#if canImport(Combine)
import Combine
#endif
import Foundation

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
final class InstructionPresetStore {
    #if canImport(Combine)
    @Published private(set) var presets: [InstructionPreset] = []
    #else
    // No Combine (the Linux daemon): nothing observes the list there.
    private(set) var presets: [InstructionPreset] = []
    #endif
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

#if canImport(Combine)
extension InstructionPresetStore: ObservableObject {}
#endif
