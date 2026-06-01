import Foundation
import Testing
@testable import bromure_ac

@Suite("GuardrailsConfig kube verb filtering")
struct GuardrailsConfigTests {
    let host = "k8s.example.com"
    func cfg(_ mode: GuardrailsPolicy.Mode) -> GuardrailsConfig {
        GuardrailsConfig(kubernetes: mode, kubeHosts: ["k8s.example.com"])
    }

    @Test("Off never blocks")
    func off() {
        let c = cfg(.off)
        for m in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
            #expect(c.kubeBlockReason(host: host, method: m) == nil)
        }
    }

    @Test("Read-only blocks every non-read verb")
    func readOnly() {
        let c = cfg(.readOnly)
        for m in ["GET", "HEAD", "OPTIONS"] {
            #expect(c.kubeBlockReason(host: host, method: m) == nil, "\(m) should be allowed")
        }
        for m in ["POST", "PUT", "PATCH", "DELETE"] {
            #expect(c.kubeBlockReason(host: host, method: m) != nil, "\(m) should be blocked")
        }
    }

    @Test("Destructive blocks only DELETE")
    func destructive() {
        let c = cfg(.destructive)
        #expect(c.kubeBlockReason(host: host, method: "DELETE") != nil)
        for m in ["GET", "POST", "PUT", "PATCH"] {
            #expect(c.kubeBlockReason(host: host, method: m) == nil, "\(m) should be allowed")
        }
    }

    @Test("Only the profile's kube hosts are filtered")
    func hostScope() {
        let c = cfg(.readOnly)
        // A non-kube host (e.g. an LLM API) is never touched by the kube guard.
        #expect(c.kubeBlockReason(host: "api.openai.com", method: "POST") == nil)
        #expect(c.kubeBlockReason(host: "api.x.ai", method: "DELETE") == nil)
    }

    @Test("Host match is case-insensitive")
    func caseInsensitive() {
        let c = cfg(.readOnly)
        #expect(c.kubeBlockReason(host: "K8S.Example.COM", method: "DELETE") != nil)
    }

    @Test("Method match is case-insensitive")
    func methodCaseInsensitive() {
        let c = cfg(.destructive)
        #expect(c.kubeBlockReason(host: host, method: "delete") != nil)
    }

    @Test("Inactive when no kube hosts")
    func noHosts() {
        let c = GuardrailsConfig(kubernetes: .readOnly, kubeHosts: [])
        #expect(c.kubeBlockReason(host: host, method: "DELETE") == nil)
        #expect(c.isActive == false)
    }
}

@Suite("GuardrailsConfig AWS action filtering")
struct GuardrailsAWSTests {
    func cfg(_ mode: GuardrailsPolicy.Mode) -> GuardrailsConfig {
        GuardrailsConfig(kubernetes: .off, kubeHosts: [], aws: mode)
    }
    let dynamo = "dynamodb.us-east-1.amazonaws.com"
    let ec2 = "ec2.us-east-1.amazonaws.com"
    let s3 = "my-bucket.s3.us-east-1.amazonaws.com"

    @Test("Action classification by prefix")
    func classify() {
        #expect(GuardrailsConfig.classifyAWS(action: "DeleteTable") == .destructive)
        #expect(GuardrailsConfig.classifyAWS(action: "TerminateInstances") == .destructive)
        #expect(GuardrailsConfig.classifyAWS(action: "DeregisterImage") == .destructive)
        #expect(GuardrailsConfig.classifyAWS(action: "ListBuckets") == .read)
        #expect(GuardrailsConfig.classifyAWS(action: "DescribeInstances") == .read)
        #expect(GuardrailsConfig.classifyAWS(action: "GetItem") == .read)
        #expect(GuardrailsConfig.classifyAWS(action: "PutObject") == .otherWrite)
        #expect(GuardrailsConfig.classifyAWS(action: "CreateBucket") == .otherWrite)
    }

    @Test("JSON-protocol services use X-Amz-Target")
    func amzTarget() {
        let ro = cfg(.readOnly)
        // DeleteTable blocked in read-only…
        #expect(ro.awsBlockReason(host: dynamo, method: "POST",
            amzTarget: "DynamoDB_20120810.DeleteTable", formAction: nil) != nil)
        // …GetItem allowed.
        #expect(ro.awsBlockReason(host: dynamo, method: "POST",
            amzTarget: "DynamoDB_20120810.GetItem", formAction: nil) == nil)

        let dest = cfg(.destructive)
        #expect(dest.awsBlockReason(host: dynamo, method: "POST",
            amzTarget: "DynamoDB_20120810.DeleteTable", formAction: nil) != nil)
        // PutItem is a write but not destructive → allowed in destructive mode.
        #expect(dest.awsBlockReason(host: dynamo, method: "POST",
            amzTarget: "DynamoDB_20120810.PutItem", formAction: nil) == nil)
    }

    @Test("Query-protocol services use the Action body param")
    func formAction() {
        let dest = cfg(.destructive)
        #expect(dest.awsBlockReason(host: ec2, method: "POST",
            amzTarget: nil, formAction: "TerminateInstances") != nil)
        #expect(dest.awsBlockReason(host: ec2, method: "POST",
            amzTarget: nil, formAction: "DescribeInstances") == nil)
    }

    @Test("S3 / REST falls back to HTTP method")
    func s3Method() {
        let dest = cfg(.destructive)
        #expect(dest.awsBlockReason(host: s3, method: "DELETE", amzTarget: nil, formAction: nil) != nil)
        #expect(dest.awsBlockReason(host: s3, method: "GET", amzTarget: nil, formAction: nil) == nil)
        let ro = cfg(.readOnly)
        #expect(ro.awsBlockReason(host: s3, method: "PUT", amzTarget: nil, formAction: nil) != nil)
        #expect(ro.awsBlockReason(host: s3, method: "GET", amzTarget: nil, formAction: nil) == nil)
    }

    @Test("Only AWS hosts are filtered; off never blocks")
    func scopeAndOff() {
        #expect(cfg(.readOnly).awsBlockReason(host: "api.openai.com", method: "POST",
            amzTarget: "X.DeleteThing", formAction: nil) == nil)
        #expect(cfg(.off).awsBlockReason(host: ec2, method: "POST",
            amzTarget: nil, formAction: "TerminateInstances") == nil)
    }
}

@Suite("Guardrails — DigitalOcean / Docker / git forges")
struct GuardrailsMoreTests {
    func deny(_ c: GuardrailsConfig, _ host: String, _ method: String, _ path: String = "/") -> Bool {
        c.deny(host: host, method: method, path: path, amzTarget: nil, formAction: nil) != nil
    }

    @Test("DigitalOcean is method-based")
    func digitalOcean() {
        let ro = GuardrailsConfig(kubernetes: .off, kubeHosts: [], digitalOcean: .readOnly)
        #expect(deny(ro, "api.digitalocean.com", "POST"))
        #expect(deny(ro, "api.digitalocean.com", "DELETE"))
        #expect(!deny(ro, "api.digitalocean.com", "GET"))
        let dest = GuardrailsConfig(kubernetes: .off, kubeHosts: [], digitalOcean: .destructive)
        #expect(deny(dest, "api.digitalocean.com", "DELETE"))
        #expect(!deny(dest, "api.digitalocean.com", "POST"))
    }

    @Test("Docker only filters configured registry hosts")
    func docker() {
        let c = GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                 docker: .destructive, dockerHosts: ["ghcr.io"])
        #expect(deny(c, "ghcr.io", "DELETE"))          // delete image
        #expect(!deny(c, "ghcr.io", "PUT"))            // push allowed in destructive
        #expect(!deny(c, "quay.io", "DELETE"))         // not a configured host
        let ro = GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                  docker: .readOnly, dockerHosts: ["ghcr.io"])
        #expect(deny(ro, "ghcr.io", "PUT"))            // push blocked
        #expect(!deny(ro, "ghcr.io", "GET"))           // pull allowed
    }

    @Test("Git forge: REST verbs + git push path")
    func gitForge() {
        let ro = GuardrailsConfig(kubernetes: .off, kubeHosts: [], github: .readOnly)
        #expect(deny(ro, "api.github.com", "PATCH", "/repos/x/y"))
        #expect(!deny(ro, "api.github.com", "GET", "/repos/x/y"))
        #expect(deny(ro, "github.com", "POST", "/x/y.git/git-receive-pack"))   // push blocked
        #expect(!deny(ro, "github.com", "POST", "/x/y.git/git-upload-pack"))   // fetch allowed

        let dest = GuardrailsConfig(kubernetes: .off, kubeHosts: [], github: .destructive)
        #expect(deny(dest, "api.github.com", "DELETE", "/repos/x/y"))          // delete repo
        #expect(!deny(dest, "github.com", "POST", "/x/y.git/git-receive-pack")) // push allowed
    }

    @Test("Git forges are scoped to their own toggle")
    func gitScope() {
        let c = GuardrailsConfig(kubernetes: .off, kubeHosts: [], gitlab: .readOnly)
        #expect(deny(c, "gitlab.com", "POST", "/api/v4/x"))
        #expect(!deny(c, "github.com", "POST", "/x.git/git-receive-pack"))
        #expect(!deny(c, "bitbucket.org", "DELETE", "/2.0/repos/x"))
    }
}
