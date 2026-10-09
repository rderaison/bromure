import Foundation
import Testing

/// A VZVirtioSocketConnection owns its fileDescriptor and closes it when the
/// connection is closed or released. Closing that number ourselves closes it
/// twice — the second close lands on whatever file reused the number, and on
/// a guarded one the app dies (EXC_GUARD) with no dialog. Claude sign-in quit
/// the app the instant the browser's "Authorize" hit the loopback relay.
@Suite("vsock fd ownership")
struct VsockFDOwnershipTests {

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    @Test("No source closes a VZ connection's fileDescriptor itself")
    func noRawCloseOfVZOwnedFD() throws {
        let pattern = try NSRegularExpression(pattern: #"close\(\s*(conn|connection)\.fileDescriptor\s*\)"#)
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "use conn.close(), or dup() the fd first: \(offenders)")
    }

    @Test("The OAuth loopback relay works on its own dup of the vsock fd")
    func loopbackRelayDups() throws {
        let text = try String(contentsOf: sources.appendingPathComponent(
            "AgentCoding/LoopbackCallbackForwarder.swift"), encoding: .utf8)
        #expect(text.contains("let vfd = dup(conn.fileDescriptor)"))
        #expect(!text.contains("let vfd = conn.fileDescriptor"))
    }
}
