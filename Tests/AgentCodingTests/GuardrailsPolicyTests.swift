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

@Suite("Guardrails — HTTPS databases")
struct GuardrailsDatabaseTests {
    func cfg(_ engine: HTTPDatabaseEndpoint.Engine, _ host: String,
             _ mode: GuardrailsPolicy.Mode) -> GuardrailsConfig {
        GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                         databases: [.init(engine: engine, host: host, mode: mode)])
    }
    func deny(_ c: GuardrailsConfig, _ host: String, _ method: String,
              _ path: String, _ query: String? = nil) -> Bool {
        c.deny(host: host, method: method, path: path,
               amzTarget: nil, formAction: nil, dbQuery: query) != nil
    }

    // MARK: Mongo Data API (path-based)

    @Test("Mongo classifies by action segment")
    func mongoClassify() {
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/app/x/endpoint/data/v1/action/find").0 == .read)
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/action/aggregate").0 == .read)
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/action/deleteMany").0 == .destructive)
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/action/deleteOne?x=1").0 == .destructive)
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/action/updateOne").0 == .otherWrite)
        #expect(GuardrailsConfig.classifyMongoDataAPI(path: "/action/insertMany").0 == .otherWrite)
    }

    @Test("Mongo modes + host scope")
    func mongoModes() {
        let h = "data.mongodb-api.com"
        let ro = cfg(.mongoDataAPI, h, .readOnly)
        #expect(deny(ro, h, "POST", "/action/insertOne"))      // write blocked
        #expect(deny(ro, h, "POST", "/action/deleteOne"))      // destructive blocked
        #expect(!deny(ro, h, "POST", "/action/find"))          // read allowed
        let dest = cfg(.mongoDataAPI, h, .destructive)
        #expect(deny(dest, h, "POST", "/action/deleteMany"))   // destructive blocked
        #expect(!deny(dest, h, "POST", "/action/insertOne"))   // write allowed
        // Unconfigured host untouched.
        #expect(!deny(dest, "other.example.com", "POST", "/action/deleteMany"))
    }

    // MARK: ClickHouse (SQL keyword)

    @Test("ClickHouse classifies leading SQL keyword")
    func chClassify() {
        func k(_ s: String) -> GuardrailsConfig.AWSKind? {
            GuardrailsConfig.classifyClickHouseSQL(s)?.0
        }
        #expect(k("SELECT 1") == .read)
        #expect(k("  select * from t") == .read)
        #expect(k("-- c\nSELECT 1") == .read)
        #expect(k("/* c */ SHOW TABLES") == .read)
        #expect(k("WITH x AS (SELECT 1) SELECT * FROM x") == .read)
        #expect(k("DROP TABLE t") == .destructive)
        #expect(k("TRUNCATE TABLE t") == .destructive)
        #expect(k("DELETE FROM t WHERE x=1") == .destructive)
        #expect(k("ALTER TABLE t DELETE WHERE x=1") == .destructive)
        #expect(k("ALTER TABLE t ADD COLUMN c Int32") == .otherWrite)
        #expect(k("INSERT INTO t VALUES (1)") == .otherWrite)
        #expect(k("CREATE TABLE t (x Int32)") == .otherWrite)
        #expect(k("") == nil)
    }

    @Test("ClickHouse URL query-param extraction (proxy-side)")
    func chUrlExtraction() {
        // The proxy lifts the SQL out of the URL into dbQuery.
        #expect(HTTPMitmConnection.urlQueryParam("query", inPath: "/?query=SELECT+1") == "SELECT 1")
        #expect(HTTPMitmConnection.urlQueryParam("query", inPath: "/?query=DROP%20TABLE%20t&database=x") == "DROP TABLE t")
        #expect(HTTPMitmConnection.urlQueryParam("query", inPath: "/") == nil)
        #expect(HTTPMitmConnection.urlQueryParam("query", inPath: "/?database=x") == nil)
    }

    @Test("ClickHouse mode via extracted SQL")
    func chModes() {
        let h = "ch.example.com"
        let ro = cfg(.clickHouse, h, .readOnly)
        // SQL the proxy extracted (URL param or body) → dbQuery.
        #expect(!deny(ro, h, "GET", "/?query=SELECT+1", "SELECT 1"))
        #expect(deny(ro, h, "POST", "/", "INSERT INTO t VALUES (1)"))
        #expect(deny(ro, h, "POST", "/", "DROP TABLE t"))
        #expect(!deny(ro, h, "POST", "/", "SELECT * FROM t"))
        let dest = cfg(.clickHouse, h, .destructive)
        #expect(deny(dest, h, "POST", "/", "TRUNCATE TABLE t"))
        #expect(!deny(dest, h, "POST", "/", "INSERT INTO t VALUES (1)"))
        // Read-only with no visible SQL blocks (can't prove a read).
        #expect(deny(ro, h, "POST", "/", nil))
        // Destructive with no visible SQL errs open.
        #expect(!deny(dest, h, "POST", "/", nil))
    }

    // MARK: Elasticsearch (method + path)

    @Test("Elasticsearch classifies method + path")
    func esClassify() {
        func k(_ m: String, _ p: String) -> GuardrailsConfig.AWSKind {
            GuardrailsConfig.classifyElasticsearch(method: m, path: p).0
        }
        #expect(k("GET", "/idx/_search") == .read)
        #expect(k("POST", "/idx/_search") == .read)
        #expect(k("POST", "/_msearch") == .read)
        #expect(k("DELETE", "/idx") == .destructive)
        #expect(k("POST", "/idx/_delete_by_query") == .destructive)
        #expect(k("PUT", "/idx/_doc/1") == .otherWrite)
        #expect(k("POST", "/_bulk") == .otherWrite)
    }

    @Test("Elasticsearch modes")
    func esModes() {
        let h = "es.example.com"
        let ro = cfg(.elasticsearch, h, .readOnly)
        #expect(!deny(ro, h, "POST", "/idx/_search"))    // read allowed
        #expect(deny(ro, h, "POST", "/_bulk"))           // write blocked
        #expect(deny(ro, h, "DELETE", "/idx"))           // destructive blocked
        let dest = cfg(.elasticsearch, h, .destructive)
        #expect(deny(dest, h, "DELETE", "/idx"))
        #expect(deny(dest, h, "POST", "/idx/_delete_by_query"))
        #expect(!deny(dest, h, "POST", "/_bulk"))        // write allowed
    }

    @Test("dbNeedsQuery only for ClickHouse hosts")
    func needsQuery() {
        let ch = cfg(.clickHouse, "ch.example.com", .readOnly)
        #expect(ch.dbNeedsQuery(host: "ch.example.com"))
        #expect(!ch.dbNeedsQuery(host: "other.com"))
        let mongo = cfg(.mongoDataAPI, "m.example.com", .readOnly)
        #expect(!mongo.dbNeedsQuery(host: "m.example.com"))
    }

    @Test("Off never blocks; isActive reflects databases")
    func offAndActive() {
        let off = cfg(.clickHouse, "ch.example.com", .off)
        #expect(!deny(off, "ch.example.com", "POST", "/", "DROP TABLE t"))
        #expect(!off.isActive)
        #expect(cfg(.clickHouse, "ch.example.com", .readOnly).isActive)
    }
}
