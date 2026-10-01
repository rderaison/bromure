import Foundation
import Testing
@testable import bromure_ac

@Suite("Session instructions")
@MainActor
struct InstructionPresetTests {
    let text = "You are a careful reviewer.\nUse \"tests\" & keep *globs* [out] — ça va? 🙂 ${x}"
    let path = AgentSessionEngine.instructionsGuestPath(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test("every agent's flags survive the launcher's word split")
    func flagsHaveNoSpacesInValues() {
        for tool in Profile.Tool.allCases {
            let flags = AgentSessionEngine.instructionFlags(tool: tool, text: text, path: path, resuming: false)
            // Flag names and values alternate; no value carries a space or a glob.
            for word in flags.split(separator: " ") {
                #expect(!word.contains("*") && !word.contains("?") && !word.contains("["), Comment(rawValue: "\(tool): \(word)"))
            }
        }
        #expect(AgentSessionEngine.instructionFlags(tool: .claude, text: text, path: path, resuming: true)
                == "--append-system-prompt-file \(path)")
        #expect(AgentSessionEngine.instructionFlags(tool: .omp, text: text, path: path, resuming: false)
                == "--append-system-prompt \(path)")
        #expect(AgentSessionEngine.instructionFlags(tool: .grok, text: text, path: path, resuming: false).isEmpty)
        // Kimi's agent file only applies to a fresh start.
        #expect(AgentSessionEngine.instructionFlags(tool: .kimi, text: text, path: path, resuming: false)
                == "--agent-file \(path)")
        #expect(AgentSessionEngine.instructionFlags(tool: .kimi, text: text, path: path, resuming: true).isEmpty)
    }

    @Test("Codex's value is a TOML string that decodes back to the text")
    func codexValueRoundTrips() throws {
        let flags = AgentSessionEngine.instructionFlags(tool: .codex, text: text, path: path, resuming: false)
        #expect(flags.hasPrefix("-c developer_instructions=\""))
        let value = String(flags.dropFirst("-c developer_instructions=".count))
        #expect(!value.contains(" "))
        // \uXXXX / \UXXXXXXXX escapes: decode them the way TOML does.
        var out = "", i = value.dropFirst().dropLast()[...]
        while let c = i.first {
            if c == "\\", let kind = i.dropFirst().first, kind == "u" || kind == "U" {
                let n = kind == "u" ? 4 : 8
                let hex = i.dropFirst(2).prefix(n)
                out.unicodeScalars.append(Unicode.Scalar(UInt32(hex, radix: 16)!)!)
                i = i.dropFirst(2 + n)
            } else {
                out.append(c); i = i.dropFirst()
            }
        }
        #expect(out == text)
    }

    @Test("Kimi's agent file keeps its own prompt and can't be read as a template")
    func kimiAgentFile() {
        let file = AgentSessionEngine.instructionsFile(text, tool: .kimi)
        #expect(file.hasPrefix("---\ndescription: "))
        #expect(file.contains("${base_prompt}"))
        #expect(!file.contains("${x}"))
        #expect(AgentSessionEngine.instructionsFile(text, tool: .claude) == text + "\n")
    }

    @Test("Grok gets them in its first message")
    func grokOpening() {
        let both = AgentSessionEngine.openingWithInstructions("Be brief.", message: "Fix the build")
        #expect(both.contains("Be brief.") && both.hasSuffix("Fix the build"))
        #expect(!AgentSessionEngine.openingWithInstructions("Be brief.", message: "").contains("---"))
    }

    @Test("the store keeps usable presets and round-trips the wire form")
    func store() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InstructionPresetStore(fileURL: url)
        // A first run offers the examples.
        #expect(store.presets.map(\.name) == InstructionPreset.examples.map(\.name))
        store.replace([InstructionPreset(name: " Reviewer ", text: " Review it. "),
                       InstructionPreset(name: "", text: "nameless"),
                       InstructionPreset(name: "Empty", text: "  ")])
        #expect(store.presets.map(\.name) == ["Reviewer"])
        #expect(store.presets.first?.text == "Review it.")
        // Saved, and read back by the next launch.
        #expect(InstructionPresetStore(fileURL: url).presets == store.presets)
        // A fat client's mirror: the server's list in, edits pushed out.
        var pushed: [InstructionPreset] = []
        let mirror = InstructionPresetStore { pushed = $0 }
        mirror.applyMirror(InstructionPresetStore.fromWire(InstructionPresetStore.wire(store.presets)))
        #expect(mirror.presets == store.presets)
        mirror.replace([])
        #expect(pushed.isEmpty && mirror.presets.isEmpty)
    }
}
