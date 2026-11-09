import Foundation

/// The insecure-upstream opt-out (macOS: driveTLS's step before 5, and
/// relayUpstream's 502 hint): where the workspace allows it (Guardrails →
/// "Allow X-bromure-insecure", on by default), the guest drops THIS
/// request's upstream certificate validation by sending `X-bromure-insecure:
/// yes`, the escape hatch for self-signed / private-CA endpoints. It relaxes
/// a security control at the untrusted guest's request, so no real
/// credential goes on such a request (no swap, no subscription / MCP / AWS
/// auth, no sign-in capture): only the guest's own fakes can reach the
/// unvalidated upstream. Every use is on the Security Timeline.
extension RequestReader {
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's insecure-upstream step, on the Linux request chain
    static func insecureBypass(_ req: Data, proxy: MitmProxy, profileID: UUID, host: String) -> Bool {
        guard proxy.guardrailsConfig(for: profileID)?.allowInsecureBypass ?? false,
              let head = SubscriptionAuthRewrite.rawHeaderSection(of: req),
              let v = SubscriptionAuthRewrite.headerValue("x-bromure-insecure", inHeaderSection: head)?
                .trimmingCharacters(in: .whitespaces).lowercased(),
              v == "yes" || v == "true" || v == "1"
        else { return false }
        FileHandle.standardError.write(Data(
            "[mitm] INSECURE bypass for \(host): skipping upstream cert validation + credential injection\n".utf8))
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: "tls.insecure_bypass",
            eventData: ["host": .string(host),
                        "reason": .string("upstream certificate validation skipped at guest request (X-bromure-insecure); no real credentials injected")])
        return true
    }
}

extension MitmProxy {
    /// The 502 for an upstream that couldn't be reached, for `profileID`'s
    /// request (macOS: relayUpstream's catch): with the opt-out's hint where
    /// the workspace allows it, and an untrusted certificate on the Security
    /// Timeline.
    // @port-skip linux-only: relayUpstream's 502 and its tls.upstream_untrusted event, on the Linux proxy
    func upstreamErrorResponse(_ error: Error, host: String, profileID: UUID) -> Data {
        let allowHint = guardrailsConfig(for: profileID)?.allowInsecureBypass ?? false
        let d = describeUpstreamError(error, host: host, allowInsecureHint: allowHint)
        if d.isTrust {
            BACEventEmitter.shared.emitDetached(
                profileID: profileID, eventType: "tls.upstream_untrusted",
                eventData: ["host": .string(host), "reason": .string(d.reason),
                            "code": .int(UpstreamFailure(error).urlErrorCode)])
        }
        return Self.upstreamErrorResponse(error, host: host, described: d)
    }
}

extension MitmProxy {
    /// The client-certificate event's data: the host, and the identity by
    /// name, never its key.
    // partial: the kubeconfig credential's display name (no SecCertificate subject summary on Linux)
    // @port HTTPMitmConnection.static clientCertEventData(_: ClientIdentityRegistry.Entry, host: String, port: Int) h=04c9d05d81681ba8 @285807ef
    static func clientCertEventData(_ id: KubeUpstreamTrust.Identity, host: String, port: Int) -> [String: AnyJSON] {
        [
            "host": .string(port == 443 ? host : "\(host):\(port)"),
            "identity": .string(id.consentDisplayName ?? "client certificate"),
        ]
    }
}
