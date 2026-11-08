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
        // Now: with the window's baseline, it's cleared.
        let doc = try #require(RemoteHostController.settingsDocument(edited: edited, opened: stored))
        #expect(try host(stored, applying: doc).agentReach == nil)
        // Without one, reach is never widened: the host keeps its list.
        let blind = try #require(RemoteHostController.settingsDocument(edited: edited, opened: nil))
        #expect(blind["agentReach"] == nil)
        #expect(try host(stored, applying: blind).agentReach == [other])
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

    /// The finding (CWE-367): a window opened on "Every workspace", saved
    /// for an unrelated setting after another client restricted the reach,
    /// sent reach null and reopened it. The whole window going back undid
    /// any change made meanwhile the same way.
    @Test("a field left as the window opened it isn't sent: a restriction made meanwhile stands")
    func unchangedStaysOut() throws {
        let a = UUID(), b = UUID()
        var opened = Profile(name: "ws", tool: .claude, authMode: .token)
        opened.agentReach = nil                          // the window opened on "Every workspace"
        var edited = opened
        edited.customFontSize = 15                       // the user changes something else
        var host = opened
        host.agentReach = [a]                            // another client restricted it meanwhile
        let doc = try #require(RemoteHostController.settingsDocument(edited: edited, opened: opened))
        #expect(doc["agentReach"] == nil && doc["customFontSize"] as? Int == 15)
        let saved = try self.host(host, applying: doc)
        #expect(saved.agentReach == [a], "the save reopened the restricted reach")
        #expect(saved.customFontSize == 15)

        // A list narrowed meanwhile isn't put back either.
        opened.agentReach = [a, b]
        edited = opened; edited.privateMode = true
        host = opened; host.agentReach = [a]
        let narrowed = try self.host(host, applying: try #require(
            RemoteHostController.settingsDocument(edited: edited, opened: opened)))
        #expect(narrowed.agentReach == [a] && narrowed.privateMode)

        // What the user did change to reach still goes: narrowed, or opened up.
        edited = opened; edited.agentReach = [b]
        #expect(try self.host(host, applying: try #require(
            RemoteHostController.settingsDocument(edited: edited, opened: opened))).agentReach == [b])
        edited = opened; edited.agentReach = nil
        #expect(try self.host(host, applying: try #require(
            RemoteHostController.settingsDocument(edited: edited, opened: opened))).agentReach == nil)

        // Unchanged kube contexts stay out; the last one removed is an explicit [].
        let unchanged = try #require(RemoteHostController.settingsDocument(edited: opened, opened: opened))
        #expect(unchanged["kubeconfigs"] == nil && unchanged["agentReach"] == nil)
    }

    @Test("the settings window saves through it")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(src.contains("guard var doc = RemoteHostController.settingsDocument(edited: edited, opened: original) else { return }"))
        // The iOS app builds this file but not ProfileDocument's.
        let shared = try #require(src.range(of: "static func settingsDocument("))
        #expect(!src[shared.upperBound...].prefix(1500).contains("ProfileDocument.editedDocument(fetched"))
        let ios = try String(contentsOf: top.appendingPathComponent("ios/BromureRemote/Sources/BromureRemote/WorkspaceEditor.swift"), encoding: .utf8)
        #expect(ios.contains("built = RemoteHostController.settingsDocument(edited: edited, opened: original)"))
    }
}
