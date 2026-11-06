import Crypto
import Foundation
import Testing
@testable import ACLinux

/// The detector models' pinned hashes (PromptInjectionModelPins), shared
/// with macOS: a file is installed only while it hashes to its pin.
@Suite("Prompt-injection model pins")
struct PromptInjectionModelPinsTests {
    @Test func everyPinIsASHA256AndBothModelsArePinned() {
        let pins = PromptInjectionModelPins.sha256
        #expect(Set(pins.keys) == ["prompt-injection", "claudemd-guard"])
        #expect(Set(pins["prompt-injection"]!.keys) == ["model.onnx", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"])
        #expect(Set(pins["claudemd-guard"]!.keys) == ["model.onnx", "tokenizer.json", "tokenizer_config.json", "config.json"])
        for (_, files) in pins { for (_, h) in files {
            #expect(h.count == 64 && h.allSatisfy { "0123456789abcdef".contains($0) })
        } }
        #expect(PromptInjectionModelPins.expected(dir: "prompt-injection", file: "nope.bin") == nil)
    }

    /// The real downloads (BROMURE_TEST_MODELS: a folder holding
    /// prompt-injection/ and claudemd-guard/ as dl.bromure.io serves them).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROMURE_TEST_MODELS"] != nil))
    func theDownloadedModelsMatchTheirPins() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BROMURE_TEST_MODELS"]!, isDirectory: true)
        for (dir, files) in PromptInjectionModelPins.sha256 { for (file, want) in files {
            #expect(PromptInjectionModelPins.matches(root.appendingPathComponent(dir).appendingPathComponent(file), sha256: want),
                    "\(dir)/\(file)")
        } }
    }

    @Test func aFileMatchesItsPinAndAChangedOneDoesnt() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/model.onnx")
        // 3 MiB: more than one read chunk.
        var bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        let want = try PromptInjectionModelPins.hex(of: url)
        #expect(want == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(!PromptInjectionModelPins.matches(url, sha256: String(repeating: "0", count: 64)))
        // The right pin last: that's the verdict a stale cache would keep.
        #expect(PromptInjectionModelPins.matches(url, sha256: want))
        // Changed on disk (a later modification date): hashed again, no match.
        bytes[1000] ^= 0xFF
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(!PromptInjectionModelPins.matches(url, sha256: want))
        // Gone: no match.
        try FileManager.default.removeItem(at: url)
        #expect(!PromptInjectionModelPins.matches(url, sha256: want))
    }

    /// What isInstalled asks: never a hash, only a verdict already known for
    /// the file as it is now.
    @Test func theCachedVerdictNeverHashes() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir + "/tokenizer.json")
        try Data("one".utf8).write(to: url)
        let want = try PromptInjectionModelPins.hex(of: url)
        #expect(PromptInjectionModelPins.cachedVerdict(url, sha256: want) == nil, "cold: unknown, not hashed")
        #expect(PromptInjectionModelPins.matches(url, sha256: want))
        #expect(PromptInjectionModelPins.cachedVerdict(url, sha256: want) == true)
        try Data("two".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(PromptInjectionModelPins.cachedVerdict(url, sha256: want) == nil, "changed: unknown again")
        #expect(!PromptInjectionModelPins.matches(url, sha256: want))
        #expect(PromptInjectionModelPins.cachedVerdict(url, sha256: want) == false, "known bad: not installed")
        // A download noted as verified: known good without a hash.
        let fresh = URL(fileURLWithPath: dir + "/config.json")
        try Data("fresh".utf8).write(to: fresh)
        PromptInjectionModelPins.noteVerified(fresh, sha256: "x")
        #expect(PromptInjectionModelPins.cachedVerdict(fresh, sha256: "x") == true)
        #expect(PromptInjectionModelPins.cachedVerdict(URL(fileURLWithPath: dir + "/nope"), sha256: want) == false, "missing")
    }

    /// What the classifier's load runs: a pinned file that doesn't match is
    /// deleted (fetched again, never loaded); the others stay.
    @Test func aLoadRemovesTheFilesThatDontMatch() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        for f in ["model.onnx", "tokenizer.json", "tokenizer_config.json"] {   // not special_tokens_map.json
            try Data("not the real \(f)".utf8).write(to: folder.appendingPathComponent(f))
        }
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))   // not pinned
        let bad = PromptInjectionModelPins.removeMismatched(dirName: "prompt-injection", in: folder)
        #expect(bad == ["model.onnx", "tokenizer.json", "tokenizer_config.json"])
        for f in bad { #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(f).path)) }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path), "unpinned files stay")
        #expect(PromptInjectionModelPins.removeMismatched(dirName: "no-such-model", in: folder).isEmpty)
    }

    /// The real downloads pass the load's check and nothing is removed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROMURE_TEST_MODELS"] != nil))
    func theDownloadedModelsPassTheLoadCheck() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BROMURE_TEST_MODELS"]!, isDirectory: true)
        for dir in ["prompt-injection", "claudemd-guard"] {
            #expect(PromptInjectionModelPins.removeMismatched(dirName: dir, in: root.appendingPathComponent(dir)).isEmpty, "\(dir)")
        }
    }
}
