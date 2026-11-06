import Foundation
import Testing
@testable import ACLinux

/// The Switchboard MCP's token (SwitchboardToken, shared with macOS): one
/// per session, from a host key kept 0600; the shim's hello carries it.
@Suite("Switchboard MCP token", .serialized)
struct SwitchboardTokenTests {
    @Test func aSessionsTokenIsItsOwnAndStable() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir); SwitchboardToken.keyFolder = nil }
        SwitchboardToken.keyFolder = URL(fileURLWithPath: dir, isDirectory: true)
        let a = UUID(), b = UUID()
        let ta = SwitchboardToken.token(for: a)
        #expect(ta.count == 64 && ta.allSatisfy(\.isHexDigit))
        #expect(SwitchboardToken.token(for: a) == ta, "stable")
        #expect(SwitchboardToken.token(for: b) != ta, "another session's differs")
        #expect(SwitchboardToken.matches(ta, sessionID: a))
        #expect(!SwitchboardToken.matches(ta, sessionID: b))
        #expect(!SwitchboardToken.matches(nil, sessionID: a) && !SwitchboardToken.matches("", sessionID: a))
        #expect(!SwitchboardToken.matches(String(ta.dropLast()), sessionID: a))
        // The key: 32 bytes, 0600, and the same after a restart (read back).
        let key = dir + "/switchboard-token.key"
        let attrs = try FileManager.default.attributesOfItem(atPath: key)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect((attrs[.size] as? Int) == 32)
        SwitchboardToken.keyFolder = URL(fileURLWithPath: dir, isDirectory: true)   // forgets the in-memory key
        #expect(SwitchboardToken.token(for: a) == ta, "the key on disk is reused")
        // Another host (another key): another token for the same session.
        let other = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: other) }
        SwitchboardToken.keyFolder = URL(fileURLWithPath: other, isDirectory: true)
        #expect(SwitchboardToken.token(for: a) != ta)
    }

    @Test func theHelloCarriesTheWindowAndTheToken() {
        #expect(SwitchboardToken.parseHello("w3 tabc123") == (3, "abc123"))
        #expect(SwitchboardToken.parseHello("w3") == (3, nil))
        #expect(SwitchboardToken.parseHello("") == (nil, nil))
        #expect(SwitchboardToken.parseHello("x3 tabc").window == nil)
        #expect(SwitchboardToken.parseHello("w-1 tabc").window == nil)
    }

    @Test func theBriefWritesTheTokenPrivatelyAndOnlyAHexOne() {
        let t = String(repeating: "ab", count: 32)
        let c = SwitchboardLaunch.briefCommand(guestFolder: "~/.bromure/switchboard", token: t)
        #expect(c.contains("umask 077") && c.contains("printf %s \(t) > '~/.bromure/switchboard'/.bromure-switchboard-token.new"))
        #expect(c.contains("mv -f '~/.bromure/switchboard'/.bromure-switchboard-token.new '~/.bromure/switchboard'/.bromure-switchboard-token"))
        #expect(!SwitchboardLaunch.briefCommand(guestFolder: "/x", token: "ab; rm -rf ~").contains("rm -rf"), "not hex: not written")
        #expect(!SwitchboardLaunch.briefCommand(guestFolder: "/x").contains("token"))
    }

    @Test func theShimPresentsTheTokenFromItsFolderNotItsEnvironment() {
        let s = SessionDisk.switchboardMCPShimScript
        #expect(s.contains("def _token():") && s.contains(".bromure-switchboard-token"))
        #expect(s.contains("HELLO = HELLO + \" t\" + _TOKEN"))
        #expect(!s.contains("environ.get(\"BROMURE_SWITCHBOARD_TOKEN") && !s.contains("sys.argv[2]"))
        // Only the Switchboard's shim carries it.
        #expect(!SessionDisk.delegationMCPShimScript.contains("_token()"))
    }
}
