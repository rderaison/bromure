import Foundation
import Testing
@testable import bromure_ac

/// Board: "mcp__display__show_media doesn't work". Claude showed a png, the
/// tool answered "Shown to the user", and the chat drew a bare "display show
/// media" row. The chat reads the guest home as "~" in card headers, and
/// that rewrite also ran over the call's detail -- the JSON the card reads
/// the file's path from: "~/shot.png" isn't an absolute path, so the call
/// wasn't recognized as a display at all. Only /tmp files ever showed.
@Suite("A display call's path survives the chat's home and share rewrite")
struct DisplayPathRewriteTests {
    /// The detail as the Claude parser writes it (Foundation escapes "/").
    static func call(_ name: String, _ input: [String: String]) -> TranscriptItem {
        let data = try! JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
        return TranscriptItem(id: 0, kind: .toolUse(name: name, summary: input["path"] ?? "",
                                                    detail: String(decoding: data, as: UTF8.self)), timestamp: nil)
    }

    static func request(_ item: TranscriptItem) -> DisplayRequest? {
        guard case .toolUse(let name, _, let detail) = item.kind else { return nil }
        return DisplayRequest.parse(name: name, detail: detail)
    }

    @Test("an image in the home, or in a shared Mac folder, is still shown", arguments: [
        "/home/ubuntu/shot.png", "/home/ubuntu", "/mnt/bromure-share-1/plots/a.png", "/tmp/x.png",
    ])
    func media(path: String) {
        let names = ["/mnt/bromure-share-1": "~/Projects"]
        let shown = GuestSharePaths.rewrite([Self.call("mcp__display__show_media", ["path": path, "title": "Shot"])],
                                            names: names)
        #expect(Self.request(shown[0]) == .media(path: path, title: "Shot", caption: nil))
        let sent = GuestSharePaths.rewrite([Self.call("mcp__display__send_file", ["path": path])], names: names)
        #expect(Self.request(sent[0]) == .file(path: path, note: nil))
    }

    @Test("other cards still read the home as ~")
    func others() {
        let out = GuestSharePaths.rewrite([Self.call("Read", ["path": "/home/ubuntu/a.txt"])], names: [:])
        guard case .toolUse(_, let summary, let detail) = out[0].kind else { Issue.record("not a call"); return }
        #expect(summary == "~/a.txt" && detail.contains("~"))
    }
}
