import Foundation
import Testing
@testable import bromure_ac

/// Builds a minimal TLS 1.2/1.3 ClientHello record carrying an optional SNI, so
/// the parser is exercised against real wire bytes (not a mock).
private func clientHello(sni: String?) -> [UInt8] {
    var ext = [UInt8]()
    if let sni, let name = sni.data(using: .utf8) {
        let n = Array(name)
        var serverNameList = [UInt8]()
        serverNameList.append(0)                                    // name_type = host_name
        serverNameList.append(UInt8(n.count >> 8)); serverNameList.append(UInt8(n.count & 0xFF))
        serverNameList.append(contentsOf: n)
        var snExt = [UInt8]()
        snExt.append(UInt8(serverNameList.count >> 8)); snExt.append(UInt8(serverNameList.count & 0xFF))
        snExt.append(contentsOf: serverNameList)
        ext.append(0x00); ext.append(0x00)                          // ext type server_name
        ext.append(UInt8(snExt.count >> 8)); ext.append(UInt8(snExt.count & 0xFF))
        ext.append(contentsOf: snExt)
    }

    var body = [UInt8]()
    body.append(0x03); body.append(0x03)                           // client_version TLS1.2
    body.append(contentsOf: [UInt8](repeating: 0x11, count: 32))   // random
    body.append(0x00)                                              // session_id length 0
    body.append(0x00); body.append(0x02); body.append(0x13); body.append(0x01)  // cipher_suites (1)
    body.append(0x01); body.append(0x00)                          // compression_methods: 1 × null
    body.append(UInt8(ext.count >> 8)); body.append(UInt8(ext.count & 0xFF))    // extensions length
    body.append(contentsOf: ext)

    var hs = [UInt8]()
    hs.append(0x01)                                               // handshake type ClientHello
    hs.append(UInt8((body.count >> 16) & 0xFF))
    hs.append(UInt8((body.count >> 8) & 0xFF))
    hs.append(UInt8(body.count & 0xFF))
    hs.append(contentsOf: body)

    var rec = [UInt8]()
    rec.append(0x16); rec.append(0x03); rec.append(0x01)          // handshake record, TLS1.0 rec version
    rec.append(UInt8(hs.count >> 8)); rec.append(UInt8(hs.count & 0xFF))
    rec.append(contentsOf: hs)
    return rec
}

@Suite("TLS ClientHello SNI parser")
struct TLSClientHelloTests {
    @Test("Extracts the SNI host, lowercased")
    func extractsSNI() {
        #expect(TLSClientHello.parseSNI(clientHello(sni: "API.Example.COM")) == .sni("api.example.com"))
    }

    @Test("No server_name extension → noSNI")
    func noSNI() {
        #expect(TLSClientHello.parseSNI(clientHello(sni: nil)) == .noSNI)
    }

    @Test("Non-handshake first byte → notTLS")
    func notTLS() {
        #expect(TLSClientHello.parseSNI([0x47, 0x45, 0x54, 0x20]) == .notTLS)  // "GET "
    }

    @Test("Truncated record → needMoreData (peek loop continues)")
    func truncated() {
        let full = clientHello(sni: "example.com")
        #expect(TLSClientHello.parseSNI(Array(full.prefix(10))) == .needMoreData)
    }

    @Test("Complete record but oversized handshake length → noSNI, never hangs")
    func completeRecordTerminates() {
        var b = clientHello(sni: "example.com")
        b[6] = 0xFF  // inflate handshake length past the record
        let r = TLSClientHello.parseSNI(b)
        #expect(r != .needMoreData)
    }
}

@Suite("Generic HTTP write-verb policy")
struct HTTPWritePolicyTests {
    func cfg(_ def: GuardrailsPolicy.Mode, _ hosts: [GuardrailsConfig.HostGuardrail] = []) -> GuardrailsConfig {
        GuardrailsConfig(kubernetes: .off, kubeHosts: [], httpWriteDefault: def, httpWriteHosts: hosts)
    }

    @Test("Default off allows every verb")
    func defaultOff() {
        let c = cfg(.off)
        #expect(c.deny(host: "api.acme.com", method: "POST", path: "/x", amzTarget: nil, formAction: nil) == nil)
    }

    @Test("readOnly default blocks writes, allows reads")
    func readOnlyDefault() {
        let c = cfg(.readOnly)
        #expect(c.deny(host: "api.acme.com", method: "GET", path: "/x", amzTarget: nil, formAction: nil) == nil)
        #expect(c.deny(host: "api.acme.com", method: "POST", path: "/x", amzTarget: nil, formAction: nil) != nil)
        #expect(c.deny(host: "api.acme.com", method: "DELETE", path: "/x", amzTarget: nil, formAction: nil) != nil)
    }

    @Test("Per-host override wins, subdomain matches")
    func perHostOverride() {
        let c = cfg(.off, [GuardrailsConfig.HostGuardrail(host: "acme.com", mode: .readOnly)])
        #expect(c.deny(host: "api.acme.com", method: "POST", path: "/x", amzTarget: nil, formAction: nil) != nil)
        #expect(c.deny(host: "other.com", method: "POST", path: "/x", amzTarget: nil, formAction: nil) == nil)
    }

    @Test("destructive blocks only DELETE")
    func destructive() {
        let c = cfg(.destructive)
        #expect(c.deny(host: "api.acme.com", method: "PUT", path: "/x", amzTarget: nil, formAction: nil) == nil)
        #expect(c.deny(host: "api.acme.com", method: "DELETE", path: "/x", amzTarget: nil, formAction: nil) != nil)
    }
}

@Suite("Passthrough list")
struct PassthroughListTests {
    @Test("Built-in pinners always match, incl. subdomains")
    func builtins() {
        let list = PassthroughList(extra: [])
        #expect(list.matches("google.com"))
        #expect(list.matches("accounts.google.com"))
        #expect(!list.matches("notgoogle.com"))
    }

    @Test("Operator entries match host and subdomains")
    func operatorEntries() {
        let list = PassthroughList(extra: ["Bank.example"])
        #expect(list.matches("bank.example"))
        #expect(list.matches("login.bank.example"))
        #expect(!list.matches("example"))
    }
}
