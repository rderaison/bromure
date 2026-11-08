import Foundation

// Squelch on a Linux server (macOS: the profiles' didSet, wireSquelch's
// ledger refresh, quit's flush): command-output noise cut from what the
// workspaces' agents send their models, counted per workspace and
// conversation.
extension Daemon {
    /// The workspaces' Squelch settings, as the proxy reads them on every
    /// model request (macOS: SquelchSettings.update in `profiles`' didSet),
    /// from the store as last saved.
    // @port-skip linux-only: the profiles' didSet's Squelch line, over the daemon's store
    static func refreshSquelchSettings() {
        SquelchSettings.update(Dictionary(ProfileStore().loadAll().map { ($0.id, $0.squelch) },
                                          uniquingKeysWith: { a, _ in a }))
    }

    /// A change to the ledger's numbers moves /state's generation, at most
    /// once a second (macOS: SquelchLedger.onChange through SquelchRefreshGate).
    // @port-skip linux-only: wireSquelch's ledger refresh, over StateGeneration
    static func wireSquelchLedger() {
        let pending = SquelchRefreshGate()
        SquelchLedger.shared.onChange = { _ in
            guard pending.claim() else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                pending.release()
                StateGeneration.noteMutation()
            }
        }
    }
}

extension RequestReader {
    /// Squelch on an AI host's request (macOS: driveTLS's Squelch step,
    /// after prompt injection's decoding and before PII): the noise in the
    /// command output the conversation carries is cut before the model
    /// reads it, and counted. Never blocks: a body it can't read goes out as
    /// the agent sent it. Every backend, the on-host engine included.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's Squelch step, on the Linux request chain
    static func squelchStep(_ request: inout Data, proxy: MitmProxy, profileID: UUID, host: String, method: String,
                            trace: inout Trace?) {
        guard TraceLevel.isAIHost(host), SquelchSettings.policy(for: profileID)?.enabled == true else { return }
        // Prompt injection and PII decode a coded body themselves (before
        // this); with neither on, Squelch decodes it to read it.
        let piOn = proxy.promptInjectionPolicy(for: profileID)?.isActive ?? false
        let piiOn = proxy.piiPolicy(for: profileID)?.isActive ?? false
        if !piOn, !piiOn, case .decoded(let plain) = decodeRequestContentEncoding(request) {
            request = plain
            if let t = trace, case .decoded(let plainTrace) = decodeRequestContentEncoding(t.request) {
                trace?.request = plainTrace
            }
        }
        guard method.uppercased() == "POST", let split = request.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headText = String(decoding: request[request.startIndex..<split.upperBound], as: UTF8.self)
        let body = Data(request[split.upperBound...])
        guard SubscriptionAuthRewrite.headerValue("Content-Encoding", inHeaderSection: headText) == nil,
              SquelchRewriter.mayCarryToolOutput(body) else { return }
        let outcome = SquelchRewriter.rewrite(body, priorCall: { SquelchCallRegistry.shared.call(profileID, $0) })
        if outcome.body != body { request = ProxyPolicy.replacingBody(of: request, with: outcome.body) }
        SquelchLedger.shared.record(outcome, profileID: profileID,
                                    conversation: SquelchRewriter.sessionKey(headers: headText) ?? outcome.conversation)
    }
}
