import Foundation

/// Per-session background loop that re-resolves each 1Password `op://` reference
/// every 120 s and pushes the fresh secret into the swap map — keeping the
/// guest's already-exported FAKE stable and only updating the host-side real
/// value (so a rotated secret takes effect without a reboot). Modeled on
/// `ExecCredentialPoller`. The resolved secret lives only here and in the
/// swapper's in-memory map; only the `op://` reference is ever on disk.
/// Lifetime is bound to the session — start on launch, stop on close.
@MainActor
public final class OnePasswordRefresher {
    /// One op-sourced credential to keep fresh. `fake` is the exact fake the
    /// token plan minted (and the guest holds); `hosts` are its swap scopes
    /// (nil = any host), matching `TokenMap.Entry.host`.
    public struct Ref: Sendable {
        public let opRef: String
        public let fake: String
        public let hosts: [String?]
        public let consentID: String?
        public let consentName: String?
        public init(opRef: String, fake: String, hosts: [String?],
                    consentID: String? = nil, consentName: String? = nil) {
            self.opRef = opRef
            self.fake = fake
            self.hosts = hosts
            self.consentID = consentID
            self.consentName = consentName
        }
    }

    public static let refreshSeconds: Double = 120

    private var tasks: [UUID: Task<Void, Never>] = [:]
    public init() {}

    /// (Re)start the refresh loop for a profile's op-sourced credentials. The
    /// token plan minted the fake from the `op://` *reference string* (a stable
    /// literal); this owns resolving the real secret. It first **blanks** each
    /// placeholder (so a premature request gets no valid key rather than the
    /// literal `op://…`), then resolves immediately and every 120 s thereafter.
    /// `onFirstError` fires once, on the main actor, if the very first resolution
    /// fails (op missing / not signed in) so the caller can surface instructions.
    /// No-op for an empty list (and clears any prior loop).
    public func start(profileID: UUID, refs: [Ref], swapper: TokenSwapper,
                      onFirstError: (@MainActor (OnePasswordCLI.OpError) -> Void)? = nil) {
        stop(profileID: profileID)
        guard !refs.isEmpty else { return }
        // Replace the plan's fake→"op://…" placeholder with fake→"" until the
        // real secret resolves; the guest already holds the fake.
        for r in refs { Self.updateSwap(swapper: swapper, profileID: profileID, ref: r, real: "") }
        let task = Task { [weak swapper] in
            var reported = false
            var first = true
            while !Task.isCancelled {
                if !first {
                    try? await Task.sleep(for: .seconds(Self.refreshSeconds))
                    if Task.isCancelled { return }
                }
                first = false
                for r in refs {
                    guard let swapper else { return }
                    do {
                        let real = try await OnePasswordCLI.read(r.opRef)
                        Self.updateSwap(swapper: swapper, profileID: profileID, ref: r,
                                        real: real.trimmingCharacters(in: .whitespacesAndNewlines))
                    } catch let e as OnePasswordCLI.OpError {
                        if !reported {
                            reported = true
                            onFirstError?(e)
                        }
                        // A missing CLI won't fix itself mid-session — stop the
                        // loop. Other failures (locked vault, transient) retry.
                        if case .notInstalled = e { return }
                    } catch { /* unexpected — retry next tick */ }
                }
            }
        }
        tasks[profileID] = task
    }

    public func stop(profileID: UUID) {
        tasks[profileID]?.cancel()
        tasks.removeValue(forKey: profileID)
    }

    public func stopAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }

    /// Replace this ref's entries (same fake + host) with the new real value,
    /// preserving any consent metadata — keying by `fake` keeps the guest's
    /// exported fake valid across the swap.
    private static func updateSwap(swapper: TokenSwapper, profileID: UUID,
                                   ref: Ref, real: String) {
        var entries = swapper.entries(for: profileID)
        for host in ref.hosts {
            let prior = entries.first(where: { $0.fake == ref.fake && $0.host == host })
            entries.removeAll { $0.fake == ref.fake && $0.host == host }
            entries.append(TokenMap.Entry(
                fake: ref.fake, real: real, host: host,
                consentCredentialID: prior?.consentCredentialID ?? ref.consentID,
                consentDisplayName: prior?.consentDisplayName ?? ref.consentName))
        }
        swapper.setMap(TokenMap(entries: entries), for: profileID)
    }
}
