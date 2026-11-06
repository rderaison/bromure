import Foundation
import Testing
@testable import bromure_ac

/// Board report: from the fat client, changing which workspaces a VM's agents
/// may reach (delegation) didn't take. The host checks reach on every call,
/// but the fat client's save left `agentReach` out when it was nil ("Every
/// workspace") — the Profile encoder skips a field at its default — and the
/// host keeps a field the document doesn't name. Every setting turned back to
/// its default from the fat client was lost the same way.
@Suite("A fat client's settings save clears what the user cleared")
@MainActor
struct RemoteSettingsClearTests {
    private func host(_ p: Profile, applying doc: [String: Any]) throws -> Profile {
        switch ProfileDocument.merge(doc, over: p) {
        case .success(let merged): return merged
        case .failure(let e): throw e
        }
    }

    @Test("reach opened to every workspace reaches the host; the old document kept the list")
    func reachEveryWorkspace() throws {
        let other = UUID()
        var stored = Profile(name: "ws", tool: .claude, authMode: .token)
        stored.agentReach = [other]
        var edited = stored
        edited.agentReach = nil
        // The old save: the edited profile encoded as is.
        let old = try #require(ACAppDelegate.codableToDict(edited))
        #expect(try host(stored, applying: old).agentReach == [other], "the bug: the list stayed")
        // Now: with the window's baseline, and without one.
        for opened in [stored, nil] as [Profile?] {
            let doc = try #require(RemoteHostController.settingsDocument(edited: edited, opened: opened))
            #expect(try host(stored, applying: doc).agentReach == nil)
        }
        // And narrowing it still goes through.
        edited.agentReach = []
        let narrow = try #require(RemoteHostController.settingsDocument(edited: edited, opened: stored))
        #expect(try host(stored, applying: narrow).agentReach == [])
    }

    @Test("settings turned back to their default arrive as defaults; untouched notes stay out")
    func defaultsCleared() throws {
        var stored = Profile(name: "ws", tool: .claude, authMode: .token)
        stored.browserPersistent = true
        stored.privateMode = true
        stored.traceLevel = .activity
        stored.modelRouting = .local
        stored.browserAllowUploads = false
        stored.customFontSize = 15
        stored.environmentVariables = [EnvironmentVariable(name: "FOO", value: "1")]
        stored.comments = "host notes"
        var edited = stored
        edited.browserPersistent = false
        edited.privateMode = false
        edited.traceLevel = .off
        edited.modelRouting = .cloud
        edited.browserAllowUploads = true
        edited.customFontSize = nil
        edited.environmentVariables = []
        let doc = try #require(RemoteHostController.settingsDocument(edited: edited, opened: stored))
        #expect(doc["comments"] == nil)                       // as opened: the host's stand
        let got = try host(stored, applying: doc)
        #expect(!got.browserPersistent && !got.privateMode && got.traceLevel == .off)
        #expect(got.modelRouting == .cloud && got.browserAllowUploads && got.customFontSize == nil)
        #expect(got.environmentVariables.isEmpty)
        #expect(got.comments == "host notes")
    }

    @Test("the settings window saves through it")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(src.contains("guard var doc = RemoteHostController.settingsDocument(edited: edited, opened: original) else { return }"))
    }
}
