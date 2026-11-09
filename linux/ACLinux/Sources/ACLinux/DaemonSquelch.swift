import Foundation
import SandboxEngine

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
    /// Squelch is on for this socket: a model provider's (as WSPromptGuard
    /// reads them), with the workspace's Squelch on (macOS:
    /// WSContentGuard.squelchApplies).
    // partial: the Linux proxy's model-socket rule
    // @port WSContentGuard.static squelchApplies(host: String, profileID: UUID) h=7e12c4137a9e3264 @ca94b963
    static func squelchApplies(host: String, profileID: UUID, local: Bool) -> Bool {
        let h = host.lowercased()
        return TraceLevel.isAIHost(h) && !h.contains("huggingface.co")
            && (!local || PIIEngineScope.offMacEngineHost(profileID: profileID) != nil)
            && SquelchSettings.policy(for: profileID)?.enabled == true
    }

    /// Squelch as an OpenShell message transform, for a socket on the
    /// per-message pump (a policy or rewrite is installed, so there is no
    /// guard): client text is trimmed first, then `then` runs on it (macOS:
    /// WSContentGuard.squelchingTransform).
    // partial: over SquelchSettings
    // @port WSContentGuard.static squelchingTransform(then: ((String)->OpenShellWebSocket.MessageTransform)?, profileID: UUID, conversation: String?, ledger: SquelchLedger) h=ef491d5df3f79cce @ca94b963
    static func squelchingTransform(then: ((String) -> OpenShellWebSocket.MessageTransform)?, profileID: UUID,
                                    conversation: String?) -> (String) -> OpenShellWebSocket.MessageTransform {
        { text in
            var current = text
            var changed = false
            let data = Data(text.utf8)
            if SquelchSettings.policy(for: profileID)?.enabled == true, SquelchRewriter.mayCarryToolOutput(data) {
                let o = SquelchRewriter.rewrite(data, priorCall: { SquelchCallRegistry.shared.call(profileID, $0) })
                SquelchLedger.shared.record(o, profileID: profileID, conversation: conversation ?? o.conversation)
                if o.body != data { current = String(decoding: o.body, as: UTF8.self); changed = true }
            }
            switch then?(current) ?? .unchanged {
            case .unchanged: break
            case .replaced(let t): current = t; changed = true
            case .failed(let why, let failOpen): return .failed(why, failOpen: failOpen)
            }
            return changed ? .replaced(current) : .unchanged
        }
    }

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
