import Foundation
import Testing

/// The CDP pairing gate is skipped on Linux (port/config.json): macOS's
/// switch keeps other VMs off a browser VM's CDP forwarder (:9223), and a
/// Linux server runs no browser VM (agents reach the client's browser over
/// browser-mcp). This trips the day the daemon's sources mention that port
/// or a browser VM's forwarder, so such a VM brings the gate with it.
@Suite("No CDP forwarder on the Linux switch")
struct LinuxSwitchHasNoCDPForwarderTests {
    @Test func nothingOnTheSwitchListensOn9223() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ACLinux")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        let port = try NSRegularExpression(pattern: "(^|[^0-9a-fA-F])9223([^0-9a-fA-F]|$)|cdpForwarder|allowCDPPeer")
        for f in files {
            let text = try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
            let hit = port.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hit == nil, "\(f) mentions the CDP forwarder: port the pairing gate (VMNetSwitch.cdpPeerBlocked) with it")
        }
    }
}
