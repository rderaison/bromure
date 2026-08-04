import Foundation

/// Whole-file config import.
///
/// The typed importers lift one or two *attributes* out of a config file — an
/// identity, a token, a registry list — and drop the rest. That loses most of
/// what people actually configure: git aliases, `pull.rebase`, merge tools,
/// `init.defaultBranch`, npm scopes. This carries the whole file instead.
///
/// Two things have to happen before a host file can be handed to the VM:
///
/// 1. **Secrets come out.** A token embedded in a `[url]` rewrite would land in
///    the guest in cleartext, defeating the entire point of the fake/swap
///    design. Those lines are removed here; the typed path re-adds the same
///    credential through the proxy, where the VM only ever sees a fake.
/// 2. **Mac-only settings are neutralized.** `credential.helper = osxkeychain`
///    does not exist on Linux, and `commit.gpgsign` with a signing key that
///    stayed on the host fails every commit. Both are actively harmful in the
///    guest, so they are dropped or forced off rather than copied.
///
/// Everything else is preserved byte-for-byte, comments included.
enum ConfigFileSanitize {

    struct Result: Equatable {
        var contents: String
        /// Secret-bearing lines removed (they arrive via the typed path).
        var strippedSecrets: Int
        /// Settings dropped or forced off, named for the UI to report.
        var disabled: [String]

        var isEmpty: Bool {
            contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - git

    /// `~/.gitconfig`, minus embedded tokens and host-only helpers.
    ///
    /// Section-aware because the same key means different things in different
    /// sections (`helper` under `[credential]` is ours to own; `gpgsign` under
    /// `[commit]` has to be forced off). Continuation lines are folded first so
    /// a value split across lines can't smuggle a token past the filter.
    static func gitConfig(_ text: String) -> Result {
        var out: [String] = []
        var stripped = 0
        var disabled: [String] = []
        var section = "", subsection = ""
        // Set while skipping the body of a dropped [url "…token…"] section.
        var skippingSection = false

        for raw in unfold(text) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") {
                (section, subsection) = header(trimmed)
                skippingSection = false
                // A URL rewrite keyed on a URL with userinfo is a credential in
                // disguise — drop the whole section, body included.
                if section == "url", GitConfigParse.credential(fromURL: subsection) != nil {
                    skippingSection = true
                    stripped += 1
                    continue
                }
                out.append(raw)
                continue
            }
            if skippingSection { continue }

            // Comments and blanks ride along untouched.
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                out.append(raw)
                continue
            }

            guard let eq = trimmed.firstIndex(of: "=") else {
                out.append(raw)          // bare boolean, e.g. `rebase`
                continue
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            // A token can also hide in a plain value: `url = https://tok@host/`.
            if ["url", "insteadof", "pushinsteadof"].contains(key),
               GitConfigParse.credential(fromURL: String(value)) != nil {
                stripped += 1
                continue
            }

            switch (section, key) {
            case ("user", "name"), ("user", "email"):
                // The identity has a typed home on the profile and an editor
                // field. A second copy here would be a rival source of truth:
                // clear the field and the managed [user] block disappears,
                // leaving this stale value to silently take over.
                continue

            case ("credential", "helper"):
                // We install our own (`store`, fed by the swapped credentials).
                // Keeping `osxkeychain` here makes git fail on Linux outright.
                if !disabled.contains("credential.helper") { disabled.append("credential.helper") }
                continue

            case ("commit", "gpgsign"), ("tag", "gpgsign"), ("push", "gpgsign"):
                // The signing key stayed on the host: leaving this on turns
                // every commit in the VM into an error.
                guard isTrue(String(value)) else { out.append(raw); continue }
                let name = "\(section).gpgsign"
                if !disabled.contains(name) { disabled.append(name) }
                out.append(indentation(of: raw) + "\(trimmed[..<eq].trimmingCharacters(in: .whitespaces)) = false")

            default:
                out.append(raw)
            }
        }
        return Result(contents: joined(pruneEmptySections(out)),
                      strippedSecrets: stripped, disabled: disabled)
    }

    /// Drop section headers left with no settings under them. Removing
    /// `helper = osxkeychain` otherwise strands a bare `[credential]`, and a
    /// file of nothing but stranded headers should count as nothing at all.
    /// Comments inside a dropped section go with it — they describe the
    /// setting that just left, so keeping them only misleads.
    private static func pruneEmptySections(_ lines: [String]) -> [String] {
        var out: [String] = []
        var header: String?
        var body: [String] = []
        var bodyHasSetting = false

        func flush() {
            guard let h = header else { out += body; body = []; return }
            if bodyHasSetting { out.append(h); out += body }
            header = nil; body = []; bodyHasSetting = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                flush()
                header = line
                continue
            }
            if header == nil { out.append(line); continue }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") {
                bodyHasSetting = true
            }
            body.append(line)
        }
        flush()
        return out
    }

    // MARK: - npm

    /// `~/.npmrc`, minus auth lines and any `prefix` (the managed home pins its
    /// own so globally-installed CLIs land where the guest expects).
    static func npmrc(_ text: String) -> Result {
        var out: [String] = []
        var stripped = 0
        var disabled: [String] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                out.append(raw); continue
            }
            let lower = trimmed.lowercased()
            if ["_authtoken", "_auth", "_password", ":password", "username"]
                .contains(where: { lower.contains($0) }) {
                stripped += 1
                continue
            }
            if lower.hasPrefix("prefix") || lower.hasPrefix("globalconfig") {
                if !disabled.contains("prefix") { disabled.append("prefix") }
                continue
            }
            out.append(raw)
        }
        return Result(contents: joined(out), strippedSecrets: stripped, disabled: disabled)
    }

    // MARK: - PyPI

    /// `~/.pypirc`, minus the passwords. What's left is the index layout, which
    /// is what makes `twine upload -r <name>` resolve at all.
    static func pypirc(_ text: String) -> Result {
        var out: [String] = []
        var stripped = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";")
                || trimmed.hasPrefix("[") {
                out.append(raw); continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { out.append(raw); continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "password" || key == "username" {
                stripped += 1
                continue
            }
            out.append(raw)
        }
        return Result(contents: joined(out), strippedSecrets: stripped, disabled: [])
    }

    // MARK: - helpers

    /// Trailing blank lines collapse to exactly one terminator; an all-blank
    /// result becomes empty so callers can treat "nothing worth keeping" as nil.
    private static func joined(_ lines: [String]) -> String {
        var l = lines
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        guard !l.isEmpty else { return "" }
        return l.joined(separator: "\n") + "\n"
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isTrue(_ v: String) -> Bool {
        ["true", "yes", "on", "1"].contains(unquote(v).lowercased())
    }

    private static func unquote(_ v: String) -> String {
        var s = v
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        return s
    }

    /// `[section]` / `[section "sub"]`, matching git-config(1) (subsection is
    /// case-sensitive and backslash-escaped; the section name is not).
    private static func header(_ line: String) -> (String, String) {
        var body = line
        if body.hasPrefix("[") { body.removeFirst() }
        if let close = body.lastIndex(of: "]") { body = String(body[..<close]) }
        body = body.trimmingCharacters(in: .whitespaces)
        if let q = body.firstIndex(of: "\"") {
            var sub = String(body[body.index(after: q)...])
            if sub.hasSuffix("\"") { sub.removeLast() }
            sub = sub.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\", with: "\\")
            return (body[..<q].trimmingCharacters(in: .whitespaces).lowercased(), sub)
        }
        return (body.lowercased(), "")
    }

    /// Fold values continued with a trailing backslash into one logical line,
    /// so the token filter sees the whole value.
    private static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        var pending = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
                pending += l.dropLast()
            } else {
                out.append(pending + l)
                pending = ""
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out
    }
}
