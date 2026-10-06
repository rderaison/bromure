import AppKit
import SandboxEngine

/// Firewall quick actions: the Security Timeline's "Allow…", "Block…",
/// "Switch rule off" / "Remove rule" on a firewall row, and the host-side
/// upkeep of temporary rules (timed expiry, "until the workspace stops").
///
/// The pure part (`FirewallRuleActions`) turns a timeline verdict into rule
/// suggestions and applies an edit to a workspace's pf text; the app part
/// (`ACAppDelegate` extension) saves the result and pushes it live to the
/// running VM — no restart.
enum FirewallRuleActions {

    /// How long a quick allow lasts.
    enum Duration: Equatable, CaseIterable {
        case always, fifteenMinutes, oneHour, untilStop

        /// The rule's temporary fields for this duration, from `now`.
        func apply(to rule: inout EgressPolicy.Rule, now: Date) {
            rule.enabled = true
            rule.expiresAt = nil
            rule.untilStop = false
            switch self {
            case .always:         break
            case .fifteenMinutes: rule.expiresAt = EgressPolicy.expiry(in: 15 * 60, from: now)
            case .oneHour:        rule.expiresAt = EgressPolicy.expiry(in: 60 * 60, from: now)
            case .untilStop:      rule.untilStop = true
            }
        }
    }

    /// One edit to a workspace's ruleset.
    enum Edit: Equatable {
        /// Put `rule` first (first match wins, so it takes precedence over
        /// whatever decided before), replacing any rule with the same text.
        case insert(EgressPolicy.Rule)
        /// Switch off the first rule whose `text` is this (clearing its expiry).
        case disable(ruleText: String)
        /// Switch on the first rule whose `text` is this, for `Duration`.
        case enable(ruleText: String, Duration)
        /// Delete every rule whose `text` is this.
        case remove(ruleText: String)
    }

    /// `text` with `edit` applied, or nil when the text doesn't parse or the
    /// edit changes nothing (rule not found).
    static func apply(_ edit: Edit, to text: String, now: Date = Date()) -> String? {
        guard var policy = try? EgressPolicy.parse(text) else { return nil }
        switch edit {
        case .insert(let rule):
            policy.rules.removeAll { $0.text == rule.text }
            policy.rules.insert(rule, at: 0)
        case .disable(let ruleText):
            guard let i = policy.rules.firstIndex(where: { $0.text == ruleText }) else { return nil }
            policy.rules[i].enabled = false
            policy.rules[i].expiresAt = nil
            policy.rules[i].untilStop = false
        case .enable(let ruleText, let duration):
            guard let i = policy.rules.firstIndex(where: { $0.text == ruleText }) else { return nil }
            duration.apply(to: &policy.rules[i], now: now)
        case .remove(let ruleText):
            let before = policy.rules.count
            policy.rules.removeAll { $0.text == ruleText }
            guard policy.rules.count != before else { return nil }
        }
        let out = policy.serialize()
        return out == text ? nil : out
    }

    /// Whether `text` has a rule named `ruleText` (the timeline only offers to
    /// switch off / remove a rule that's still in the workspace — not one
    /// since edited, nor the built-in local-models allowance).
    static func contains(ruleText: String, in text: String) -> Bool {
        ((try? EgressPolicy.parse(text))?.rules ?? []).contains { $0.text == ruleText }
    }

    /// A rule target offered for a destination: an exact host / IP, or a whole
    /// registrable domain (`wholeDomain`, "Allow all of github.com").
    struct Target: Equatable {
        let name: String
        let wholeDomain: Bool
        init(_ name: String, wholeDomain: Bool = false) { self.name = name; self.wholeDomain = wholeDomain }
    }

    /// The rule targets worth offering for a destination, most specific first:
    /// the host the guest asked for (the CONNECT host / SNI / queried DNS
    /// name — the name the proxy route matches too, so a rule made from a
    /// transparent row holds on both routes); then its registrable domain
    /// (`api.github.com` → `github.com`) when different and not a shared
    /// CDN / hosting suffix (never "all of cloudflare.net"); then the other
    /// names seen for the address (CNAME targets), exact only. A bare IP for a
    /// flow with no hostname.
    ///
    /// Aliases that name the provider's server rather than the site — CDN /
    /// shared-hosting names (`www.iana.org.cdn.cloudflare.net`) and
    /// infrastructure-looking ones (`dyna.wikimedia.org`, `…t-msedge.net`) —
    /// are not offered (the row's tooltip still lists them): a rule on one
    /// would be about the CDN, not the destination. A row whose host is such
    /// a name (older rows) is offered under the site's name instead, when an
    /// alias has it.
    static func targets(for fw: SecurityTimeline.Firewall) -> [Target] {
        if var host = fw.host?.lowercased(), !host.isEmpty, EgressPolicy.parseIPv4(host) == nil {
            var aliases = fw.aliases.map { $0.lowercased() }
                .filter { !$0.isEmpty && EgressPolicy.parseIPv4($0) == nil && $0 != host }
            if isServerName(host), let site = aliases.first(where: { !isServerName($0) }) {
                aliases.removeAll { $0 == site }
                aliases.insert(host, at: 0)
                host = site
            }
            var out = [Target(host)]
            if let domain = registrableDomain(of: host), domain != host, !isSharedHosting(host) {
                out.append(Target(domain, wholeDomain: true))
            }
            for alias in aliases where !isServerName(alias) && !out.contains(Target(alias)) {
                out.append(Target(alias))
            }
            return out
        }
        if let ip = fw.ip ?? fw.host, EgressPolicy.parseIPv4(ip) != nil { return [Target(ip)] }
        return []
    }

    /// Domains under which unrelated parties' sites live (CDNs, cloud and
    /// static hosting): "allow all of" one of these would open every
    /// customer of that provider, so it's never offered.
    static let sharedHostingSuffixes: Set<String> = [
        // CDNs / edge networks
        "cloudflare.net", "cloudflare-dns.com", "akamai.net", "akamaiedge.net", "akamaized.net",
        "akamaihd.net", "akamaitechnologies.com", "edgekey.net", "edgesuite.net", "cloudfront.net",
        "fastly.net", "fastlylb.net", "fastly-edge.com", "azureedge.net", "azurefd.net",
        "edgecastcdn.net", "llnwd.net", "b-cdn.net", "cdn77.org", "kxcdn.com", "stackpathdns.com",
        "incapdns.net", "impervadns.net", "sucuri.net", "jsdelivr.net", "cdninstagram.com",
        // Cloud / app hosting
        "amazonaws.com", "elasticbeanstalk.com", "awsglobalaccelerator.com", "aws.dev",
        "googleusercontent.com", "googleapis.com", "appspot.com", "cloudfunctions.net", "run.app",
        "web.app", "firebaseapp.com", "azurewebsites.net", "cloudapp.net", "cloudapp.azure.com",
        "trafficmanager.net", "blob.core.windows.net", "windows.net",
        "herokuapp.com", "herokudns.com", "digitaloceanspaces.com", "ondigitalocean.app",
        "fly.dev", "onrender.com", "railway.app", "vercel.app", "now.sh", "netlify.app",
        "pages.dev", "workers.dev", "r2.dev", "deno.dev", "glitch.me", "repl.co", "replit.dev",
        "surge.sh", "ngrok.io", "ngrok-free.app", "ngrok.app", "trycloudflare.com",
        // Static / user-content hosting
        "github.io", "githubusercontent.com", "gitlab.io", "bitbucket.io", "blogspot.com",
        "wordpress.com", "wpengine.com", "wixsite.com", "squarespace.com", "myshopify.com",
        "tumblr.com", "neocities.org", "000webhostapp.com",
    ]

    /// Whether `host` lives under a shared CDN / hosting suffix.
    static func isSharedHosting(_ host: String) -> Bool {
        let h = host.lowercased()
        return sharedHostingSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Labels (split on "." and "-") that mark a CDN / load-balancer server
    /// name rather than a site: `x.cdn.example.net`, `e123.edgekey.net`,
    /// `dyna.wikimedia.org`, `part-0012.t-0009.t-msedge.net`.
    static let infrastructureLabels: Set<String> = [
        "cdn", "edgekey", "edgesuite", "edge", "dyna", "dyn", "geo", "geodns", "anycast",
        "lb", "elb", "glb", "gslb", "msedge", "fastly", "fastlylb", "cloudfront",
        "trafficmanager", "edgecast", "llnwd", "footprint",
    ]

    /// Whether `name` looks like a CDN / load-balancer server name.
    static func looksLikeInfrastructure(_ name: String) -> Bool {
        let labels = name.lowercased().split(whereSeparator: { $0 == "." || $0 == "-" })
        return labels.contains { l in
            infrastructureLabels.contains(String(l)) || l.contains("cdn") || l.contains("akamai")
        }
    }

    /// A name for the provider's server, not the site: never offered as a
    /// rule target (only shown in the row's details).
    static func isServerName(_ name: String) -> Bool {
        isSharedHosting(name) || looksLikeInfrastructure(name)
    }

    /// What the workspace's CURRENT rules decide for this row's destination
    /// (nil: nothing to evaluate) — so an old "blocked" row whose host has
    /// since been allowed says so instead of offering to allow it again.
    static func currentDecision(for fw: SecurityTimeline.Firewall, policy: EgressPolicy,
                                now: Date = Date()) -> (denied: Bool, rule: String?)? {
        guard isActionable(fw) else { return nil }
        let names = ([fw.host] + fw.aliases.map(Optional.some)).compactMap { $0 }
            .filter { EgressPolicy.parseIPv4($0) == nil && !$0.isEmpty }
        let ip = (fw.ip ?? fw.host).flatMap(EgressPolicy.parseIPv4)
        let proto: EgressPolicy.Proto = fw.proto == "udp" ? .udp : .tcp
        let port = UInt16(truncatingIfNeeded: fw.port ?? 0)
        let rule = policy.firstMatch(ip: ip, hostnames: names, proto: proto, port: port, now: now)
        let denied = policy.verdict(ip: ip, hostnames: names, proto: proto, port: port, now: now) == .deny
        return (denied, rule?.text)
    }

    /// The existing rule with the same text as `rule`, if any — a quick
    /// allow then shows what's already there (on, off, until when) instead
    /// of silently resetting it.
    static func existing(_ rule: EgressPolicy.Rule, in text: String) -> EgressPolicy.Rule? {
        ((try? EgressPolicy.parse(text))?.rules ?? []).first { $0.text == rule.text }
    }

    /// An allow rule for a blocked destination: protocol + port as seen (the
    /// most specific match that lets exactly this kind of flow through).
    static func allowRule(target: String, fw: SecurityTimeline.Firewall) -> EgressPolicy.Rule? {
        let proto = fw.proto == "udp" ? "udp" : "tcp"
        let ports = (fw.port ?? 0) > 0 ? ":\(fw.port!)" : ""
        return try? EgressPolicy.parse("allow \(proto) \(target)\(ports)").rules.first
    }

    /// A deny rule for an allowed destination: every protocol and port to it
    /// — "block this host", not just this one port of it.
    static func blockRule(target: String) -> EgressPolicy.Rule? {
        try? EgressPolicy.parse("deny any \(target)").rules.first
    }

    /// Whether a row can carry quick actions at all: a ruleset decision
    /// (not a transport drop) on TCP/UDP with a destination we can name.
    static func isActionable(_ fw: SecurityTimeline.Firewall) -> Bool {
        fw.byPolicy && (fw.proto == "tcp" || fw.proto == "udp") && !targets(for: fw).isEmpty
    }

    // MARK: Editor merge

    /// Whether two rule texts say the same thing (formatting aside).
    static func sameRules(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let pa = try? EgressPolicy.parse(a), let pb = try? EgressPolicy.parse(b) else { return false }
        return pa == pb
    }

    /// Carry a change made outside the editor (`old` → `new`: a timeline
    /// quick action, an expiry) onto the editor's unsaved text `ours`, rule
    /// by rule (rules are matched by their text): removed rules go, added
    /// rules come in at their position, a rule whose on/off state or time
    /// limit changed takes the new state (it's what's in force), and a changed
    /// default posture is adopted. Everything else the user edited stays.
    /// nil when a side doesn't parse — the editor then asks.
    static func merge(external old: String, _ new: String, into ours: String) -> String? {
        if sameRules(ours, old) { return new }
        guard let o = try? EgressPolicy.parse(old), let n = try? EgressPolicy.parse(new),
              var u = try? EgressPolicy.parse(ours) else { return nil }
        let oldTexts = Set(o.rules.map(\.text)), newTexts = Set(n.rules.map(\.text))
        // Removed outside.
        u.rules.removeAll { oldTexts.contains($0.text) && !newTexts.contains($0.text) }
        for (i, r) in n.rules.enumerated() {
            if let j = u.rules.firstIndex(where: { $0.text == r.text }) {
                // Present on both sides: a state change made outside wins.
                if let was = o.rules.first(where: { $0.text == r.text }),
                   was.enabled != r.enabled || was.expiresAt != r.expiresAt || was.untilStop != r.untilStop {
                    u.rules[j].enabled = r.enabled
                    u.rules[j].expiresAt = r.expiresAt
                    u.rules[j].untilStop = r.untilStop
                }
            } else if !oldTexts.contains(r.text) {
                // Added outside (a quick action puts it first).
                u.rules.insert(r, at: min(i, u.rules.count))
            }
            // In `old` and `new` but deleted in the editor: stays deleted.
        }
        if o.defaultAction != n.defaultAction { u.defaultAction = n.defaultAction }
        return u.serialize()
    }

    /// Two-label registrable domain, or three under a common second-level
    /// public suffix (`co.uk`, `com.au`…). Deliberately simple — no PSL — and
    /// only ever OFFERED next to the exact host, never applied silently.
    static func registrableDomain(of host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]
        if labels.count >= 3, labels[labels.count - 1].count == 2,
           secondLevel.contains(labels[labels.count - 2]) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}

// MARK: - App side

extension Notification.Name {
    /// A workspace's firewall rules changed outside its editor (a timeline
    /// quick action, an expiry): `object` is the profile id, `userInfo["rules"]`
    /// the new pf text. An open editor reloads its rule table from it.
    static let bromureFirewallRulesChanged = Notification.Name("io.bromure.firewallRulesChanged")
    /// A workspace's saved firewall rules changed by ANY path (editor, CLI /
    /// automation, quick action, expiry): `object` is the profile id. What
    /// shows the rules' current verdict (the Security Timeline's "Allowed
    /// now" / "Blocked now") re-evaluates.
    static let bromureFirewallPolicyChanged = Notification.Name("io.bromure.firewallPolicyChanged")
}

/// The expiry sweep's timers (an extension can't hold stored properties).
@MainActor private enum FirewallSweep {
    static var timer: Timer?
    /// One-shot at the soonest timed rule's expiry, so the rule is switched
    /// off — and the connections it allowed are cut — at that instant, not
    /// up to a sweep interval later.
    static var expiryTimer: Timer?
    static var didLaunchSweep = false
}

extension ACAppDelegate {

    /// Push a workspace's outbound rules to its running VM: the switch port
    /// (L4, every frame — see `VMNetSwitch.setEgressPolicy`) and the MiTM
    /// (SNI / CONNECT / HTTP-verb layers read it per connection). No restart.
    func applyLiveFirewall(for profile: Profile, sandbox: UbuntuSandboxVM?) {
        mitmEngine?.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
        sandbox?.applyEgressPolicy(profile.resolvedEgressPolicy)
    }

    /// Apply a quick edit to a workspace's rules: save, push live to the
    /// running VM, tell an open editor. False when nothing changed.
    @MainActor @discardableResult
    func applyFirewallEdit(_ edit: FirewallRuleActions.Edit, profileID: UUID) -> Bool {
        guard let p = profiles.first(where: { $0.id == profileID }),
              let text = FirewallRuleActions.apply(edit, to: p.egressRules) else { return false }
        return commitFirewallRules(text, profileID: profileID)
    }

    /// Persist `text` as a workspace's rules and apply it live.
    @MainActor @discardableResult
    func commitFirewallRules(_ text: String, profileID: UUID) -> Bool {
        guard var p = profiles.first(where: { $0.id == profileID }), p.egressRules != text else { return false }
        let previous = p.egressRules
        p.egressRules = text
        do { try store.save(p) } catch {
            NSLog("[bromure-ac] firewall: couldn't save rules for \(p.name): \(error)")
            return false
        }
        if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i] = p }
        // Running: switch port + MiTM now. Only the rules are patched into the
        // session's and pane's copies (those are launch-time, model-overlaid
        // profiles), so a later editor save diffs against what's in force —
        // nothing else is re-applied (no terminal re-theme, no env refresh).
        let session = runningSessions[profileID]
        let pane = pane(for: profileID)
        session?.profile.egressRules = text
        pane?.profile.egressRules = text
        if session != nil || pane != nil {
            applyLiveFirewall(for: p, sandbox: session?.sandbox ?? pane?.sandbox)
        }
        // `previous` lets an open editor with unsaved edits merge the change
        // into them rule by rule instead of dropping them.
        NotificationCenter.default.post(name: .bromureFirewallRulesChanged, object: profileID,
                                        userInfo: ["rules": text, "previous": previous])
        scheduleNextFirewallExpiry()
        return true
    }

    /// (Re)arm the one-shot timer for the soonest timed-rule expiry across
    /// workspaces. The evaluators already ignore an expired rule on their own;
    /// this makes the host switch it off at that instant, which re-checks the
    /// open connections it allowed (`MitmEngine.setGuardrailsConfig`).
    @MainActor func scheduleNextFirewallExpiry(now: Date = Date()) {
        FirewallSweep.expiryTimer?.invalidate()
        FirewallSweep.expiryTimer = nil
        let next = profiles.lazy.filter { $0.egressRules.contains("#@until=") }
            .compactMap { (try? EgressPolicy.parse($0.egressRules))?.nextExpiry }
            .min()
        guard let next else { return }
        let t = Timer(fire: max(next, now).addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepFirewallRules() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        FirewallSweep.expiryTimer = t
    }

    /// Start the periodic sweep that switches off expired temporary rules and
    /// saves them. Enforcement doesn't wait for it — the evaluator ignores an
    /// expired rule the moment it expires — so this only keeps the saved text,
    /// the editor and the timeline honest. The first pass also ends every
    /// "until the workspace stops" rule left over from the previous run (no
    /// workspace survives an app quit as "running").
    @MainActor func startFirewallExpirySweep() {
        guard FirewallSweep.timer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepFirewallRules() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        FirewallSweep.timer = t
    }

    @MainActor func sweepFirewallRules(now: Date = Date()) {
        let launch = !FirewallSweep.didLaunchSweep
        FirewallSweep.didLaunchSweep = true
        for p in profiles where p.egressRules.contains("#@") {
            let stopped = launch && runningSessions[p.id] == nil
            if let text = EgressPolicy.sweeping(p.egressRules, now: now, workspaceStopped: stopped) {
                commitFirewallRules(text, profileID: p.id)
            }
        }
        // A timed rule saved from the editor arms its expiry timer here.
        scheduleNextFirewallExpiry(now: now)
    }

    /// `profiles` was reassigned: for each workspace whose rules differ from
    /// `old`, re-arm the expiry timer (a timed rule saved by the CLI or the
    /// editor gets its instant switch-off too) and tell observers.
    @MainActor func firewallProfilesChanged(from old: [Profile]) {
        let before = Dictionary(old.map { ($0.id, $0.egressRules) }, uniquingKeysWith: { a, _ in a })
        let changed = profiles.filter { before[$0.id] != $0.egressRules }.map(\.id)
        guard !changed.isEmpty else { return }
        scheduleNextFirewallExpiry()
        for id in changed {
            NotificationCenter.default.post(name: .bromureFirewallPolicyChanged, object: id)
        }
    }

    /// Wire the firewall's proxy-route cut to the guest: reset agentd's bridge
    /// socket for that connection (see `HTTPMitmConnection.cutForFirewall`).
    @MainActor func installFirewallGuestAbort() {
        EgressConnectionRegistry.shared.guestAbort = { [weak self] pid, port, done in
            Task { @MainActor in
                defer { done() }
                _ = try? await self?.guestJSONRequest(
                    profileID: pid, request: ["bridge_abort": ["port": Int(port)], "timeout": 5])
            }
        }
    }

    /// The workspace stopped: its "until the workspace stops" rules end.
    @MainActor func endUntilStopFirewallRules(for profileID: UUID) {
        guard let p = profiles.first(where: { $0.id == profileID }),
              let text = EgressPolicy.sweeping(p.egressRules, now: Date(), workspaceStopped: true)
        else { return }
        commitFirewallRules(text, profileID: profileID)
    }
}
