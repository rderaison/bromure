import Foundation
import Testing
@testable import bromure_ac

@Suite("AWSConfigParser")
struct AWSConfigParserTests {

    private func writeTempConfig(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("Discovers SSO profiles with all required fields")
    func discoverBasic() throws {
        let config = """
        [profile dev]
        sso_start_url = https://my-sso.awsapps.com/start
        sso_account_id = 123456789012
        sso_role_name = AdministratorAccess
        sso_region = us-east-1
        region = us-west-2
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "dev")
        #expect(profiles[0].ssoStartURL == "https://my-sso.awsapps.com/start")
        #expect(profiles[0].ssoAccountID == "123456789012")
        #expect(profiles[0].ssoRoleName == "AdministratorAccess")
        #expect(profiles[0].ssoRegion == "us-east-1")
        #expect(profiles[0].region == "us-west-2")
    }

    @Test("Skips profiles missing required SSO fields")
    func skipIncomplete() throws {
        let config = """
        [profile complete]
        sso_start_url = https://my-sso.awsapps.com/start
        sso_account_id = 123456789012
        sso_role_name = ReadOnly
        sso_region = us-east-1
        region = us-east-1

        [profile missing-role]
        sso_start_url = https://my-sso.awsapps.com/start
        sso_account_id = 123456789012
        sso_region = us-east-1
        region = us-east-1

        [profile static-only]
        region = us-west-2
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "complete")
    }

    @Test("Handles [default] section")
    func defaultSection() throws {
        let config = """
        [default]
        sso_start_url = https://default.awsapps.com/start
        sso_account_id = 111111111111
        sso_role_name = DefaultRole
        sso_region = eu-west-1
        region = eu-west-1
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "default")
    }

    @Test("Discovers multiple profiles")
    func multipleProfiles() throws {
        let config = """
        [profile dev]
        sso_start_url = https://sso.awsapps.com/start
        sso_account_id = 111111111111
        sso_role_name = DevRole
        sso_region = us-east-1
        region = us-east-1

        [profile staging]
        sso_start_url = https://sso.awsapps.com/start
        sso_account_id = 222222222222
        sso_role_name = StagingRole
        sso_region = us-east-1
        region = us-west-2

        [profile prod]
        sso_start_url = https://sso.awsapps.com/start
        sso_account_id = 333333333333
        sso_role_name = ProdRole
        sso_region = us-east-1
        region = eu-west-1
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 3)
        let names = profiles.map(\.name)
        #expect(names.contains("dev"))
        #expect(names.contains("staging"))
        #expect(names.contains("prod"))
    }

    @Test("Resolves sso-session references")
    func ssoSession() throws {
        let config = """
        [sso-session my-session]
        sso_start_url = https://shared.awsapps.com/start
        sso_region = us-east-1

        [profile session-user]
        sso_session = my-session
        sso_account_id = 444444444444
        sso_role_name = SessionRole
        region = us-east-2
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "session-user")
        #expect(profiles[0].ssoStartURL == "https://shared.awsapps.com/start")
        #expect(profiles[0].ssoRegion == "us-east-1")
        #expect(profiles[0].ssoAccountID == "444444444444")
        #expect(profiles[0].ssoRoleName == "SessionRole")
        #expect(profiles[0].region == "us-east-2")
    }

    @Test("Returns empty array for missing config file")
    func missingFile() {
        let profiles = AWSConfigParser.discover(configPath: "/nonexistent/path/config")
        #expect(profiles.isEmpty)
    }

    @Test("Returns empty array for empty config file")
    func emptyFile() throws {
        let path = try writeTempConfig("")
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.isEmpty)
    }

    @Test("Handles inline comments and whitespace")
    func commentsAndWhitespace() throws {
        let config = """
        [profile trimmed]
          sso_start_url = https://sso.awsapps.com/start
          sso_account_id = 555555555555
          sso_role_name = TrimRole
          sso_region = us-east-1
          region = us-east-1
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles.count == 1)
        #expect(profiles[0].ssoStartURL == "https://sso.awsapps.com/start")
    }

    @Test("Profiles are Identifiable by name")
    func identifiable() throws {
        let config = """
        [profile test-id]
        sso_start_url = https://sso.awsapps.com/start
        sso_account_id = 666666666666
        sso_role_name = IDRole
        sso_region = us-east-1
        region = us-east-1
        """
        let path = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }

        let profiles = AWSConfigParser.discover(configPath: path)
        #expect(profiles[0].id == "test-id")
    }
}
