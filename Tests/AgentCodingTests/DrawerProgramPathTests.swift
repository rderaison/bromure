import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-451): "Drawer subtitle clips the program path at the file
/// name". A blocked row's subtitle was "<full exe> · <count>× · <when>" on
/// one tail-truncated line in a 368 pt drawer: a long path lost the time,
/// then the file name, so /usr/local/bin/python3 and /usr/local/bin/pip3
/// looked alike while Allow granted the clicked row's program.
@Suite("Sandbox drawer: the program's file name stays visible")
struct DrawerProgramPathTests {
    @Test("count and time are their own line; the path isn't in it")
    func subtitleHasNoPath() {
        let now = Date()
        let line = PolicyDrawer.blockedSubtitle(count: 3, last: now.addingTimeInterval(-120), now: now)
        #expect(line.hasPrefix("3× · "))
        #expect(!line.contains("/"))
        #expect(!PolicyDrawer.blockedSubtitle(count: 1, last: now, now: now).contains("×"))
    }

    @Test("Allow's help names the full path it grants")
    func helpNamesPath() {
        #expect(PolicyDrawer.allowHelp(exe: "/usr/local/bin/python3").contains("/usr/local/bin/python3"))
        #expect(PolicyDrawer.allowHelp(exe: nil) == "Add a rule for this host and port")
    }

    @Test("the program line clips in the middle and carries the full path as help")
    func programLineMiddleTruncates() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/PolicyDrawer.swift"), encoding: .utf8)
        let line = try #require(src.range(of: "if let exe = program(item, profile) {\n                            Text(verbatim: exe)"))
        let after = src[line.upperBound...].prefix(250)
        #expect(after.contains(".lineLimit(1).truncationMode(.middle)"))
        #expect(after.contains(".help(Text(verbatim: exe))"))
        #expect(!src.contains("parts.append(exe)"))
    }
}
