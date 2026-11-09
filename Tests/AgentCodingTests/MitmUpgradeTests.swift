import Foundation
import Testing
@testable import bromure_ac

/// Which `Upgrade` requests reach the raw pump. Any upgrade did: an h2c
/// upgrade turned the connection into HTTP/2 the proxy pumped opaquely, so
/// every later request on it passed unseen by the per-request policy.
@Suite("MITM upgrade gate")
struct MitmUpgradeTests {
    private func head(_ lines: String...) -> String {
        (["GET /x HTTP/1.1", "Host: example.com"] + lines).joined(separator: "\r\n")
    }

    @Test("websocket and SPDY/3.1 are pumped")
    func pumped() {
        #expect(HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade", "Upgrade: websocket")))
        #expect(HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade", "Upgrade: WebSocket")))
        #expect(HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade", "Upgrade: SPDY/3.1")))
        // A 101's own header block.
        #expect(HTTPMitmConnection.pumpedUpgrade(
            headerBlock: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade"))
    }

    @Test("h2c, an unknown protocol, or Connection: Upgrade alone go on as HTTP/1.1")
    func notPumped() {
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade, HTTP2-Settings",
                                                                    "Upgrade: h2c", "HTTP2-Settings: AAMAAABkAAQAAP__")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade", "Upgrade: foo/1.0")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("X-Note: Upgrade: websocket")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head()))
        #expect(!HTTPMitmConnection.pumpedUpgrade(
            headerBlock: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade"))
    }

    /// The request goes upstream as it is: any h2c in it is still an offer.
    @Test("websocket offered beside h2c, twice, or with a folded line isn't pumped")
    func smuggledOffers() {
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade", "Upgrade: websocket, h2c")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Upgrade: foo, websocket")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade",
                                                                    "Upgrade: websocket", "Upgrade: h2c")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade",
                                                                    "Upgrade: websocket", " , h2c")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Connection: Upgrade",
                                                                    "Upgrade: websocket", "\th2c")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Upgrade: websocket", "X-A: b\nUpgrade: h2c")))
        #expect(!HTTPMitmConnection.pumpedUpgrade(headerBlock: head("Upgrade: websocket", "Upgrade\0: h2c")))
    }
}
