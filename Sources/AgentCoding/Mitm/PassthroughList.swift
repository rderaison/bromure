import Foundation
import SandboxEngine

/// Host-side list of hostnames whose TLS must NOT be intercepted — spliced raw
/// to the origin instead. Cert-pinners (google et al.) are built in; the
/// operator adds more in Preferences (`proxy.noMitmDomains`). App-global and
/// host-side, so the guest cannot influence what is or isn't inspected.
struct PassthroughList {
    private let entries: [String]

    /// Domains known to pin certificates (MiTM breaks them), always bypassed.
    /// Signal and WhatsApp pin theirs too (the messaging connector VM).
    static let builtins = ["google.com", "gstatic.com", "googleapis.com",
                           "signal.org", "whatsapp.net", "whatsapp.com"]

    /// Nothing is passed through (strict credential mode inspects everything).
    static let none = PassthroughList(entries: [])

    private init(entries: [String]) { self.entries = entries }

    init(extra: [String]) {
        var all = PassthroughList.builtins
        all.append(contentsOf: extra
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        self.entries = all
    }

    /// True if `host` equals or is a subdomain of any entry.
    func matches(_ host: String) -> Bool {
        let h = EgressPolicy.normalizedHost(host)
        return entries.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Built-ins plus the operator's Preferences list.
    static func current() -> PassthroughList {
        PassthroughList(extra: UserDefaults.standard.stringArray(forKey: "proxy.noMitmDomains") ?? [])
    }
}
