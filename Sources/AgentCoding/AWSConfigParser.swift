import Foundation

public struct DiscoveredSSOProfile: Identifiable, Hashable, Sendable {
    public let name: String
    public let ssoStartURL: String
    public let ssoAccountID: String
    public let ssoRoleName: String
    public let ssoRegion: String
    public let region: String
    public var id: String { name }
}

public enum AWSConfigParser {

    public static func discover(configPath: String? = nil) -> [DiscoveredSSOProfile] {
        let path = configPath ?? defaultConfigPath()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        let (profiles, ssoSessions) = parseSections(contents)
        return profiles.compactMap { resolveProfile($0, ssoSessions: ssoSessions) }
    }

    // MARK: - Private

    private static func defaultConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.aws/config"
    }

    private struct RawSection {
        var name: String
        var fields: [String: String] = [:]
    }

    private static func parseSections(_ text: String) -> (profiles: [RawSection], ssoSessions: [String: RawSection]) {
        var profiles: [RawSection] = []
        var ssoSessions: [String: RawSection] = [:]
        var current: RawSection?
        var currentKind: String?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if let section = current {
                    storeSection(section, kind: currentKind, profiles: &profiles, ssoSessions: &ssoSessions)
                }
                let header = trimmed.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces)

                if header.hasPrefix("profile ") {
                    let name = String(header.dropFirst("profile ".count))
                        .trimmingCharacters(in: .whitespaces)
                    current = RawSection(name: name)
                    currentKind = "profile"
                } else if header.hasPrefix("sso-session ") {
                    let name = String(header.dropFirst("sso-session ".count))
                        .trimmingCharacters(in: .whitespaces)
                    current = RawSection(name: name)
                    currentKind = "sso-session"
                } else if header == "default" {
                    current = RawSection(name: "default")
                    currentKind = "profile"
                } else {
                    current = nil
                    currentKind = nil
                }
                continue
            }

            guard current != nil else { continue }
            if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = trimmed[trimmed.startIndex..<eqIdx]
                    .trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIdx)...]
                    .trimmingCharacters(in: .whitespaces)
                current!.fields[key] = value
            }
        }
        if let section = current {
            storeSection(section, kind: currentKind, profiles: &profiles, ssoSessions: &ssoSessions)
        }
        return (profiles, ssoSessions)
    }

    private static func storeSection(
        _ section: RawSection,
        kind: String?,
        profiles: inout [RawSection],
        ssoSessions: inout [String: RawSection]
    ) {
        switch kind {
        case "profile":     profiles.append(section)
        case "sso-session": ssoSessions[section.name] = section
        default:            break
        }
    }

    private static func resolveProfile(
        _ section: RawSection,
        ssoSessions: [String: RawSection]
    ) -> DiscoveredSSOProfile? {
        var fields = section.fields

        if let sessionName = fields["sso_session"],
           let session = ssoSessions[sessionName] {
            for (k, v) in session.fields where fields[k] == nil {
                fields[k] = v
            }
        }

        guard let startURL = fields["sso_start_url"],
              let accountID = fields["sso_account_id"],
              let roleName = fields["sso_role_name"] else {
            return nil
        }

        let ssoRegion = fields["sso_region"] ?? fields["region"] ?? ""
        let region = fields["region"] ?? ssoRegion

        return DiscoveredSSOProfile(
            name: section.name,
            ssoStartURL: startURL,
            ssoAccountID: accountID,
            ssoRoleName: roleName,
            ssoRegion: ssoRegion,
            region: region
        )
    }
}
