using Bromure.AC.Core.Imports;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class AwsConfigParserTests
{
    [Fact]
    public void Parse_DefaultProfile_IsSurfacedWhenComplete()
    {
        var contents = """
            [default]
            sso_start_url = https://example.awsapps.com/start
            sso_region    = us-east-1
            sso_account_id = 111122223333
            sso_role_name  = AdministratorAccess
            region         = us-west-2
            """;

        var profiles = AwsConfigParser.Parse(contents);
        profiles.Should().HaveCount(1);
        var p = profiles[0];
        p.Name.Should().Be("default");
        p.SsoAccountId.Should().Be("111122223333");
        p.Region.Should().Be("us-west-2");
        p.SsoRegion.Should().Be("us-east-1");
    }

    [Fact]
    public void Parse_NamedProfile_FoldsInSsoSession()
    {
        var contents = """
            [profile prod]
            sso_session     = my-org
            sso_account_id  = 444455556666
            sso_role_name   = ReadOnly
            region          = eu-west-1

            [sso-session my-org]
            sso_start_url   = https://my-org.awsapps.com/start
            sso_region      = eu-west-1
            """;

        var profiles = AwsConfigParser.Parse(contents);
        profiles.Should().HaveCount(1);
        profiles[0].Name.Should().Be("prod");
        profiles[0].SsoStartUrl.Should().Be("https://my-org.awsapps.com/start");
        profiles[0].SsoSessionName.Should().Be("my-org");
    }

    [Fact]
    public void Parse_ProfileMissingMandatoryField_IsDropped()
    {
        var contents = """
            [profile incomplete]
            sso_start_url = https://example.awsapps.com/start
            """;

        var profiles = AwsConfigParser.Parse(contents);
        profiles.Should().BeEmpty();
    }

    [Fact]
    public void Parse_CommentsAndBlankLines_AreIgnored()
    {
        var contents = """
            # comment
            ; semicolon comment

            [default]
            sso_start_url = https://example.awsapps.com/start  # not a comment per AWS spec — kept as-is
            sso_region    = us-east-1
            sso_account_id = 111122223333
            sso_role_name  = Admin
            """;

        var profiles = AwsConfigParser.Parse(contents);
        profiles.Should().HaveCount(1);
        // AWS treats # in a value position literally, matching the macOS
        // parser's behaviour (it doesn't strip in-line comments).
        profiles[0].SsoStartUrl.Should().Contain("https://example.awsapps.com/start");
    }
}
