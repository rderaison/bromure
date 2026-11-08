import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import SandboxEngine

/// The transparent entry of the Linux proxy (macOS: MitmEngine's
/// acceptTransparentFlow): a guest flow the switch diverted, with no CONNECT,
/// its destination recovered from the TLS SNI or the HTTP Host header, and the
/// same policy chain as the cooperative path.
extension MitmProxy {
    /// Accept a transparently-intercepted TCP flow (from SwitchInterceptor).
    /// `appFD` is the guest side of a socketpair carrying the raw stream.
    /// Passthrough hosts (the built-in pinners plus the operator's list) and
    /// non-TLS / unparseable flows are spliced raw (fail open); everything
    /// else is MiTM'd through the workspace's policy chain. Takes ownership
    /// of `appFD`.
    // @port MitmEngine.acceptTransparentFlow(appFD: Int32, profileID: UUID, destIP: String, destPort: Int, srcPort: Int) h=85d1555a8e0b2840 @8e2543eb
    func acceptTransparentFlow(appFD: Int32, profileID: UUID, destIP: String, destPort: Int, srcPort: Int = 0) {
        // Off the event loops, on a thread of its own: the peeks block on the
        // socket, and a pool would let a few hundred idle guest connections
        // starve every other VM's.
        Thread.detachNewThread { [self] in
            // A frame the guest addressed to loopback / link-local reaches
            // the switch only if it was forged; never dial the host's own.
            // A multi-user server's own addresses are refused too, as the
            // switch refuses them on the native path (blockedDestination),
            // which a diverted flow never takes.
            if let ip = OpenShellPolicy.IPAddress(destIP),
               let reason = Self.destinationDenial(host: destIP, resolved: [ip], hostAddresses: blocksHostAddresses) {
                SupplyChainLog.shared.record(
                    "[firewall] ✗ deny tcp \(destIP):\(destPort) — \(reason) (\(profileID.uuidString.prefix(8)))")
                close(appFD); return
            }
            // Nothing from the guest within 5 s (or it closed first): no
            // decision to make and nothing to splice, so no host connect.
            guard Self.waitForData(appFD, timeoutMs: Self.firstByteTimeoutMs) else {
                close(appFD); return
            }
            let guardrails = guardrailsConfig(for: profileID)
            // Strict sandbox: ask the guest's root attestor which executable
            // opened this connection (by its source port), before any policy
            // decision. No answer = no identity: a rule scoped to `binaries`
            // doesn't match it (fail closed), only provider rules apply.
            var identity: OpenShellPolicy.BinaryIdentity?
            if guardrails?.egressPolicy?.enforceBinaries == true, srcPort > 0 {
                identity = attestedIdentity(profileID, UInt16(truncatingIfNeeded: srcPort),
                                            destIP, UInt16(truncatingIfNeeded: destPort))
            }

            // Plain HTTP (:80) — no TLS. Peek the Host header to identify the
            // destination, apply the egress policy, then MiTM as cleartext (or
            // splice on passthrough / non-HTTP).
            let destAddr = EgressPolicy.parseIPv4Address(destIP)
            // An OpenShell L7 endpoint on another port: the switch diverted it
            // here, and cleartext HTTP on it gets the same treatment as :80.
            var plainHTTP = destPort == 80
            var tlsPeek: TLSClientHello.Result?
            if !plainHTTP,
               guardrails?.egressPolicy?.inspectedPorts.contains(UInt16(truncatingIfNeeded: destPort)) == true {
                let d = TLSClientHello.peek(fd: appFD)
                if case .notTLS = d { plainHTTP = true } else { tlsPeek = d }
            }
            if plainHTTP {
                let peeked = Self.peekHTTPHost(fd: appFD)
                let host = peeked ?? destIP
                BinaryIdentityService.shared.noteHost(identity, profileID: profileID, host: peeked, port: destPort)
                let strict80 = guardrails?.strictCredentials ?? false
                var shouldSplice = !strict80 && PassthroughList.current().matches(host)
                // `policy.local` on its reserved address: the advisor, answered
                // by the proxy (no egress decision, never forwarded).
                let advisor = destIP == EgressPolicy.advisorAddressString && host == OpenShellAdvisor.host
                if !advisor, let policy = guardrails?.egressPolicy {
                    // pf rules keep their name-only check here; OpenShell also
                    // needs the address (allowed_ips, private-range guard).
                    let os = policy.openShell != nil
                    switch policy.verdict(ip: os ? destAddr : nil,
                                          hostnames: os ? (peeked.map { [$0] } ?? []) : [host], proto: .tcp,
                                          port: UInt16(truncatingIfNeeded: destPort), identity: identity) {
                    case .deny:
                        Self.reportTransparentDeny(policy: policy, profileID: profileID, label: host,
                                                   hostnames: [host], destIP: destIP, destPort: destPort, layer: "l4",
                                                   exe: identity?.exe)
                        close(appFD); return
                    case .mitm:   shouldSplice = false
                    case .splice: shouldSplice = true
                    case .allow:  break
                    }
                }
                if shouldSplice {
                    spliceRaw(appFD: appFD, destIP: destIP, destPort: destPort)
                } else {
                    serveTransparent(appFD: appFD, profileID: profileID, host: host, port: destPort, tls: false,
                                     identity: identity)
                }
                return
            }

            let decision = tlsPeek ?? TLSClientHello.peek(fd: appFD)
            // Strict credential mode inspects every flow: no passthrough list.
            let strict = guardrails?.strictCredentials ?? false
            let passthrough = strict ? PassthroughList.none : PassthroughList.current()
            let host: String
            var shouldSplice: Bool
            switch decision {
            case .sni(let s):
                host = s
                shouldSplice = passthrough.matches(s)          // pinned / operator-listed
            case .noSNI:
                host = destIP                                  // MiTM with an IP-literal leaf
                shouldSplice = false
            case .notTLS, .needMoreData:
                host = destIP
                shouldSplice = true                            // fail open — not our protocol
            }

            // Egress firewall by SNI hostname (the authoritative check for
            // TLS, and the fallback for names the switch couldn't map at L4).
            // An OpenShell policy also decides SNI-less and non-TLS flows (by
            // destination address) instead of letting them fail open.
            let sniHost: String? = { if case .sni(let s) = decision { return s }; return nil }()
            BinaryIdentityService.shared.noteHost(identity, profileID: profileID, host: sniHost, port: destPort)
            if let policy = guardrails?.egressPolicy, sniHost != nil || policy.openShell != nil {
                switch policy.verdict(ip: policy.openShell != nil ? destAddr : nil,
                                      hostnames: sniHost.map { [$0] } ?? [], proto: .tcp,
                                      port: UInt16(truncatingIfNeeded: destPort), identity: identity) {
                case .deny:
                    Self.reportTransparentDeny(policy: policy, profileID: profileID, label: sniHost ?? destIP,
                                               hostnames: sniHost.map { [$0] } ?? [], destIP: destIP,
                                               destPort: destPort, layer: "sni", exe: identity?.exe)
                    close(appFD); return
                case .mitm:   shouldSplice = false              // `web` rule / inspected endpoint overrides passthrough
                case .splice: shouldSplice = true               // OpenShell `tls: skip`
                case .allow:  break
                }
            }

            if shouldSplice {
                // Strict credential mode can't vouch for an uninspected
                // non-TLS stream on an HTTP(S) port; only an explicit
                // OpenShell `tls: skip` endpoint is relayed raw.
                if strict, sniHost == nil {
                    SupplyChainLog.shared.record(
                        "[firewall] ✗ deny uninspectable tcp \(destIP):\(destPort) — strict credentials (\(profileID.uuidString.prefix(8)))")
                    close(appFD); return
                }
                spliceRaw(appFD: appFD, destIP: destIP, destPort: destPort)
                return
            }
            serveTransparent(appFD: appFD, profileID: profileID, host: host, port: destPort, tls: true,
                             identity: identity)
        }
    }

    /// The attested identity of a transparent flow's guest socket
    /// (BinaryIdentityService.identity, bounded: an attestor not up yet is
    /// waited for briefly, then none). Called on the flow's own thread,
    /// which waits for it as macOS's flow task awaits it.
    // @port-skip linux-only: the transparent flow's thread waiting on BinaryIdentityService.identity (macOS awaits it in a task)
    func attestedIdentity(_ profileID: UUID, _ sport: UInt16, _ dst: String, _ dport: UInt16) -> OpenShellPolicy.BinaryIdentity? {
        let lookup = identityLookup
        let answer = NIOLockedValueBox<OpenShellPolicy.BinaryIdentity?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let id = await lookup(profileID, sport, dst, dport)
            answer.withLockedValue { $0 = id }
            done.signal()
        }
        done.wait()
        return answer.withLockedValue { $0 }
    }

    /// The Timeline row for a transparent flow the egress policy refused
    /// (macOS: acceptTransparentFlow's two deny reports, `l4` for HTTP and
    /// `sni` for TLS), once a minute per destination.
    // @port-skip linux-only: acceptTransparentFlow's deny report, factored once
    static func reportTransparentDeny(policy: EgressPolicy, profileID: UUID, label: String, hostnames: [String],
                                      destIP: String, destPort: Int, layer: String, exe: String? = nil) {
        guard EgressReportDeduper.shared.shouldReport(profileID: profileID, host: label,
                                                      port: destPort, denied: true, exe: exe) else { return }
        SupplyChainLog.shared.record(
            "[firewall] ✗ deny tcp \(label):\(destPort) (\(profileID.uuidString.prefix(8)))")
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall",
            eventData: ["action": .string("deny"), "proto": .string("tcp"),
                        "host": .string(label), "port": .int(destPort), "layer": .string(layer),
                        "dst_ip": .string(destIP), "exe": .of(exe),
                        "rule": .of(policy.firstMatch(ip: nil, hostnames: hostnames, proto: .tcp,
                                                      port: UInt16(truncatingIfNeeded: destPort))?.text),
                        "by_policy": .bool(true)])
    }

    /// The flow MiTM'd: the unread stream (the peeks only looked) through the
    /// TLS leaf for `host` when `tls`, then the request pipeline, registered
    /// with the firewall's registry (macOS: runTransparentTLS /
    /// runTransparentHTTP, route "transparent").
    // @port-skip linux-only: makeConnection + runTransparentTLS / runTransparentHTTP on NIO
    func serveTransparent(appFD: Int32, profileID: UUID, host: String, port: Int, tls: Bool,
                          identity: OpenShellPolicy.BinaryIdentity? = nil) {
        // The leaf first: until withConnectedSocket takes `appFD`, a failure
        // is ours to close.
        let context: NIOSSLContext?
        do { context = tls ? try serverContext(host: host) : nil } catch { close(appFD); return }
        let bootstrap = ClientBootstrap(group: group).channelInitializer { [self] ch in
            do {
                let ops = ch.pipeline.syncOperations
                if let context { try ops.addHandler(NIOSSLServerHandler(context: context)) }
                try ops.addHandler(RequestReader(proxy: self, profileID: profileID, host: host, port: port, tls: tls,
                                                 identity: identity))
                return ch.eventLoop.makeSucceededVoidFuture()
            } catch {
                return ch.eventLoop.makeFailedFuture(error)
            }
        }
        // Not closed on a failure: NIO took `appFD` over as it made the
        // channel and closes it on any failure after that; a close here
        // would hit whoever has the number by then. (The one failure before
        // it, BaseSocket's ignoreSIGPIPE, can't happen on Linux.)
        guard let ch = try? bootstrap.withConnectedSocket(appFD).wait() else { return }
        if !trackForFirewall(ch, profileID: profileID, host: host, port: port, route: "transparent", identity: identity) {
            ch.close(promise: nil)
        }
    }

    /// Splice `appFD` to a fresh TCP connection to `destIP:destPort` — the
    /// exact address the guest chose, never re-resolved, so a pinned host
    /// reaches its real endpoint (macOS: MitmPassthrough.splice). Closes both
    /// when either side ends.
    // @port-skip linux-only: MitmPassthrough.splice(appFD:destIP:destPort:) on NIO
    func spliceRaw(appFD: Int32, destIP: String, destPort: Int) {
        // The relay is in the pipeline from the channel's first read: the
        // bytes the peeks left in the socket (a ClientHello) are held, not lost.
        let glue = ByteGlue(peer: nil)
        let bootstrap = ClientBootstrap(group: group).channelInitializer { ch in ch.pipeline.addHandler(glue) }
        guard let ip = OpenShellPolicy.IPAddress(destIP) else { close(appFD); return }
        // Past here NIO owns `appFD` (serveTransparent): never closed here.
        guard let ch = try? bootstrap.withConnectedSocket(appFD).wait() else { return }
        ch.eventLoop.execute { [self] in splice(ch, to: [ip], port: destPort, pending: ByteBuffer(), glue: glue) }
    }

    /// How long a diverted flow may stay silent before it's closed.
    nonisolated(unsafe) static var firstByteTimeoutMs: Int32 = 5000

    /// Whether `fd` has a byte to read within `timeoutMs` (not an EOF).
    // @port-skip linux-only: the transparent entry's first-byte wait (macOS peeks without one)
    static func waitForData(_ fd: Int32, timeoutMs: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return false }
        var b: UInt8 = 0
        return recv(fd, &b, 1, Int32(MSG_PEEK)) == 1
    }

    /// The HTTP request's host, peeked (not consumed): an absolute-form
    /// target's, else the Host header's, lowercased; nil when the stream
    /// doesn't look like HTTP.
    // @port MitmEngine.static peekHTTPHost(fd: Int32) h=347205d2f6f9c707 @8e2543eb
    static func peekHTTPHost(fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 4096, Int32(MSG_PEEK)) }
        guard n > 0, let text = String(bytes: buf.prefix(n), encoding: .isoLatin1),
              let firstLineEnd = text.range(of: "\r\n") else { return nil }
        let parts = text[..<firstLineEnd.lowerBound].split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }   // looks like HTTP?
        // absolute-form target: METHOD http://host[:port]/path HTTP/1.1
        let target = String(parts[1])
        if let schemeSep = target.range(of: "://") {
            let hostPart = target[schemeSep.upperBound...].prefix { $0 != "/" }
            let host = hostPart.split(separator: ":").first.map(String.init) ?? String(hostPart)
            if !host.isEmpty { return host.lowercased() }
        }
        // origin-form: pull the Host header.
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("host:") {
            let v = line.dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
            let host = v.split(separator: ":").first.map(String.init) ?? v
            if !host.isEmpty { return host.lowercased() }
        }
        return nil
    }
}
