import Foundation
import Testing
@testable import bromure_ac

@Suite("Display MCP cards")
struct DisplayCardTests {
    @Test("a display call is read whatever the agent calls MCP tools")
    func parsesEveryAgentsNaming() {
        let media = #"{"path":"/tmp/a.png","title":"Dots","caption":"c"}"#
        for name in ["mcp__display__show_media", "display__show_media", "display.show_media", "show_media"] {
            #expect(DisplayRequest.parse(name: name, detail: media)
                    == .media(path: "/tmp/a.png", title: "Dots", caption: "c"), Comment(rawValue: name))
        }
        // A relative path can't be read off the machine: not a card.
        #expect(DisplayRequest.parse(name: "mcp__display__show_media", detail: #"{"path":"a.png"}"#) == nil)
        // Someone else's show_media isn't ours.
        #expect(DisplayRequest.parse(name: "mcp__gallery__show_media", detail: media) == nil)
        // A spec as an object or as a JSON string, normalized the same way.
        let obj = DisplayRequest.parse(name: "mcp__display__show_chart",
                                       detail: #"{"spec":{"mark":"bar","data":{"values":[]}}}"#)
        let str = DisplayRequest.parse(name: "mcp__display__show_chart",
                                       detail: #"{"spec":"{\"mark\":\"bar\",\"data\":{\"values\":[]}}"}"#)
        #expect(obj != nil)
        #expect(obj == str)
    }

    @Test("send_file becomes a download card")
    func parsesSendFile() {
        #expect(DisplayRequest.parse(name: "mcp__display__send_file", detail: #"{"path":"/tmp/out.zip","note":"the build"}"#)
                == .file(path: "/tmp/out.zip", note: "the build"))
        #expect(DisplayRequest.parse(name: "display.send_file", detail: #"{"path":"/tmp/out.zip"}"#)
                == .file(path: "/tmp/out.zip", note: nil))
        #expect(DisplayRequest.parse(name: "mcp__display__send_file", detail: #"{"path":"out.zip"}"#) == nil)
        #expect(DisplayRequest.parse(name: "mcp__mail__send_file", detail: #"{"path":"/tmp/out.zip"}"#) == nil)
    }

    @Test("a download streams in chunks and lands under a free name")
    func streamsDownload() async throws {
        let blob = Data((0..<(13 * 1024 * 1024)).map { UInt8($0 % 251) })
        var reads = 0
        let reader = DisplayFileReader(read: { _, _ in nil }, op: { op in
            reads += 1
            let off = (op["offset"] as? Int64).map(Int.init) ?? (op["offset"] as? Int) ?? 0
            let len = min((op["length"] as? Int) ?? 0, blob.count - off)
            let chunk = blob.subdata(in: off..<(off + len))
            return ["data": chunk.base64EncodedString(), "size": blob.count, "eof": off + len >= blob.count]
        })
        #expect(await reader.size("/x") == Int64(blob.count))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("out.zip").path, contents: Data())
        let dest = DisplayDownloads.uniqueURL(in: dir, name: "out.zip")
        #expect(dest.lastPathComponent == "out 2.zip")
        reads = 0
        try await reader.download("/x", to: dest) { _, _ in }
        #expect(reads == 3)
        #expect(try Data(contentsOf: dest) == blob)
        // Nothing half-written is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["out 2.zip", "out.zip"])
    }

    @Test("a display call is shown, never folded into the activity line")
    func notFolded() {
        let show = TranscriptItem(id: 1, kind: .toolUse(name: "mcp__display__show_chart", summary: "",
                                                        detail: #"{"spec":{"mark":"bar"}}"#), timestamp: nil)
        let bash = TranscriptItem(id: 2, kind: .toolUse(name: "Bash", summary: "ls", detail: "{}"), timestamp: nil)
        #expect(!TranscriptRow.isActivity(show))
        #expect(TranscriptRow.isActivity(bash))
    }

    @Test("every agent is given the display server, pre-approved")
    func registered() {
        let claude = SessionDisk.claudeCodeMCPConfig(servers: [])
        #expect(claude.contains("\"display\""))
        #expect(claude.contains("bromure-display-mcp.py"))
        let codex = SessionDisk.codexMCPConfig(servers: [])
        #expect(codex.contains("[mcp_servers.display]"))
        #expect(ProfileStore.claudeAlwaysAllowed.contains("mcp__display"))
    }
}
