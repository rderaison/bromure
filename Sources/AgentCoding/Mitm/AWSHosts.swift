import Foundation

/// Which hosts are AWS: the one test the resigner, the AWS guardrail and the
/// minted-credential rewrite share. Its own file so the guardrail policy --
/// compiled into the iOS client too -- doesn't need the resigner.
public enum AWSHosts {
    /// Every partition's DNS suffix and dual-stack DNS suffix, from the AWS
    /// SDKs' partition table (botocore `partitions.json`: `dnsSuffix`,
    /// `dualStackDnsSuffix`). aws and aws-us-gov share theirs.
    public static let partitionDNSSuffixes = [
        "amazonaws.com", "api.aws",                                  // aws, aws-us-gov
        "amazonaws.com.cn", "api.amazonwebservices.com.cn",          // aws-cn
        "amazonaws.eu", "api.amazonwebservices.eu",                  // aws-eusc
        "c2s.ic.gov", "api.aws.ic.gov",                              // aws-iso
        "sc2s.sgov.gov", "api.aws.scloud",                           // aws-iso-b
        "cloud.adc-e.uk", "api.cloud-aws.adc-e.uk",                  // aws-iso-e
        "csp.hci.ic.gov", "api.aws.hci.ic.gov",                      // aws-iso-f
    ]

    /// An AWS endpoint, in any partition, on its IPv4 or dual-stack name
    /// (regional, FIPS and bucket-style S3 hosts included). The one test the
    /// resigner, the AWS guardrail and the minted-credential rewrite share:
    /// a name one of them missed was a way around the others (Finding
    /// CWE-669, "Credential mint skips other partitions' dual-stack AWS
    /// hosts").
    public static func isAWSHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return partitionDNSSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}
