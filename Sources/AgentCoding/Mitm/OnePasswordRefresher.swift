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

    /// The 1Password references to resolve in a swap map: every entry whose
    /// real value is still an `op://` reference, with the fake and hosts the
    /// map gave it -- whatever the credential kind, and whether the fake was
    /// derived from the reference or is an OpenShell placeholder.
    public static func refs(in entries: [TokenMap.Entry]) -> [Ref] {
        var out: [Ref] = []
        for e in entries {
            guard let opRef = OnePasswordCLI.reference(in: e.real) else { continue }
            if let i = out.firstIndex(where: { $0.fake == e.fake && $0.opRef == opRef }) {
                if !out[i].hosts.contains(e.host) {
                    out[i] = Ref(opRef: opRef, fake: e.fake, hosts: out[i].hosts + [e.host],
                                 consentID: out[i].consentID, consentName: out[i].consentName)
                }
            } else {
                out.append(Ref(opRef: opRef, fake: e.fake, hosts: [e.host],
                               consentID: e.consentCredentialID, consentName: e.consentDisplayName))
            }
        }
        return out
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Per profile, the references whose failure the user was already told
    /// about (and `cliMissing` for a missing `op`): kept across `start()`,
    /// which every live credential push, model restage and kubeconfig
    /// rewrite calls -- each one re-armed the app-modal alert while the
    /// reference kept failing (Finding CWE-670, "A failing 1Password read
    /// shows the error alert again on every live credential push"). Told
    /// again only once it has worked, or the reference changed.
    private var reportedFailures: [UUID: Set<String>] = [:]
    static let cliMissing = "op-cli-missing"

    /// A failure to tell the user about: true the first time for it.
    func noteFailure(_ profileID: UUID, _ key: String) -> Bool {
        reportedFailures[profileID, default: []].insert(key).inserted
    }

    func noteSuccess(_ profileID: UUID, _ opRef: String) {
        reportedFailures[profileID]?.remove(opRef)
        reportedFailures[profileID]?.remove(Self.cliMissing)   // `op` ran
    }
    /// Resolves a reference (`op read`; tests stand one in).
    private let read: @Sendable (String) async throws -> String
    public init(read: @escaping @Sendable (String) async throws -> String = { try await OnePasswordCLI.read($0) }) {
        self.read = read
    }

    /// (Re)start the refresh loop for a profile's op-sourced credentials. The
    /// token plan minted the fake from the `op://` *reference string* (a stable
    /// literal); this owns resolving the real secret. It first **blanks** each
    /// placeholder (so a premature request gets no valid key rather than the
    /// literal `op://…`), then resolves immediately and every 120 s thereafter.
    /// `onFirstError` fires on the main actor when a reference starts failing
    /// (op missing / not signed in) so the caller can surface instructions --
    /// once per reference until it works or changes, across restarts.
    /// No-op for an empty list (and clears any prior loop).
    public func start(profileID: UUID, refs: [Ref], swapper: TokenSwapper,
                      onFirstError: (@MainActor (OnePasswordCLI.OpError) -> Void)? = nil) {
        cancel(profileID: profileID)
        // A reference no longer used (removed, or changed to another) is
        // told about again should it come back and fail.
        let live = Set(refs.map(\.opRef)).union([Self.cliMissing])
        reportedFailures[profileID] = reportedFailures[profileID]?.intersection(live)
        guard !refs.isEmpty else { reportedFailures[profileID] = nil; return }
        // Replace the plan's fake→"op://…" placeholder with fake→"" until the
        // real secret resolves; the guest already holds the fake. Only the
        // reference's own still-unresolved entries: a secret already resolved
        // from it (kept by a live refresh) stays, and so does another
        // credential's entry sharing the fake.
        for r in refs {
            let entries = swapper.entries(for: profileID)
            for host in r.hosts where entries.contains(where: {
                $0.fake == r.fake && $0.host == host && OnePasswordCLI.reference(in: $0.real) == r.opRef
            }) {
                Self.updateSwap(swapper: swapper, profileID: profileID, ref: r, real: "", hosts: [host])
            }
        }
        let read = self.read
        let task = Task { [weak self, weak swapper] in
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
                        let real = try await read(r.opRef)
                        // Replaced while `op` ran (a live save restarted the
                        // loop): this reference may be the old one -- writing
                        // it would put the previous secret back.
                        if Task.isCancelled { return }
                        Self.updateSwap(swapper: swapper, profileID: profileID, ref: r,
                                        real: real.trimmingCharacters(in: .whitespacesAndNewlines))
                        self?.noteSuccess(profileID, r.opRef)
                    } catch let e as OnePasswordCLI.OpError {
                        if Task.isCancelled { return }
                        // Once per failing reference (a missing CLI: once),
                        // whatever restarted the loop since.
                        let key: String
                        if case .notInstalled = e { key = Self.cliMissing } else { key = r.opRef }
                        if self?.noteFailure(profileID, key) == true {
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

    /// The session ended: its loop, and what it told the user, go.
    public func stop(profileID: UUID) {
        cancel(profileID: profileID)
        reportedFailures[profileID] = nil
    }

    private func cancel(profileID: UUID) {
        tasks[profileID]?.cancel()
        tasks.removeValue(forKey: profileID)
    }

    public func stopAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
        reportedFailures.removeAll()
    }

    /// Give this reference's own entries (same fake + host, and their value
    /// is this `op://` reference or was resolved from it) the new real value,
    /// in place, each keeping everything else it had (header, paths, body,
    /// consent): keying by `fake` keeps the guest's exported fake valid
    /// across the swap. Another credential's entry that shares the fake and
    /// host (an OpenShell placeholder, `openshell:resolve:env:VAR`, is one
    /// per env var) is left as it is, and so is the order the swap walks
    /// them in (Finding CWE-284, "1Password refresh collapses shared
    /// OpenShell placeholders and blanks the other credential"). An entry no
    /// longer in the map (a live save dropped it) isn't brought back.
    /// A blank keeps the reference in `resolvedFrom`: still this entry, but
    /// a placeholder, so never taken for a resolved secret.
    private static func updateSwap(swapper: TokenSwapper, profileID: UUID,
                                   ref: Ref, real: String, hosts: [String?]? = nil) {
        var entries = swapper.entries(for: profileID)
        let hosts = hosts ?? ref.hosts
        for i in entries.indices where entries[i].fake == ref.fake && hosts.contains(entries[i].host)
            && Self.belongs(entries[i], to: ref.opRef) {
            entries[i] = entries[i].withReal(real, resolvedFrom: ref.opRef)
        }
        swapper.setMap(TokenMap(entries: entries), for: profileID)
    }

    /// The entry is this reference's: its value is still the `op://`
    /// reference, or was resolved (or blanked) from it.
    static func belongs(_ e: TokenMap.Entry, to opRef: String) -> Bool {
        e.resolvedFrom == opRef || OnePasswordCLI.reference(in: e.real) == opRef
    }
}
