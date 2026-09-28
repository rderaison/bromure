import Foundation
import Testing
@testable import bromure_ac

@Suite("OCSF export mapping")
struct OCSFExportTests {
    private let pid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let t = Date(timeIntervalSince1970: 1_775_014_138.811)

    private func map(_ type: String, _ data: [String: AnyJSON]) throws -> [String: Any] {
        try #require(OCSFExporter.event(profileID: pid, workspace: "demo", eventType: type,
                                        eventData: data, time: t))
    }

    @Test("A denied connection is Network Activity with OpenShell's field shape")
    func networkDeny() throws {
        let e = try map("egress.firewall", ["action": .string("deny"), "layer": .string("sni"),
                                            "proto": .string("tcp"), "host": .string("httpbin.org"),
                                            "port": .int(443)])
        #expect(e["class_uid"] as? Int == 4001)
        #expect(e["category_uid"] as? Int == 4)
        #expect(e["activity_id"] as? Int == 1)
        #expect(e["type_uid"] as? Int == 400101)
        #expect(e["action_id"] as? Int == 2)
        #expect(e["disposition"] as? String == "Blocked")
        #expect(e["severity_id"] as? Int == 3)
        #expect(e["time"] as? Int == 1_775_014_138_811)
        #expect(e["message"] as? String == "CONNECT denied httpbin.org:443")
        let dst = try #require(e["dst_endpoint"] as? [String: Any])
        #expect(dst["domain"] as? String == "httpbin.org")
        #expect(dst["port"] as? Int == 443)
        let container = try #require(e["container"] as? [String: Any])
        #expect(container["uid"] as? String == pid.uuidString.lowercased())
        #expect(container["name"] as? String == "demo")
        let meta = try #require(e["metadata"] as? [String: Any])
        #expect(meta["version"] as? String == "1.8.0")
        #expect((e["unmapped"] as? [String: Any])?["bromure_event_type"] as? String == "egress.firewall")
    }

    @Test("An OpenShell L7 decision is HTTP Activity; audit is allowed at Low severity")
    func l7() throws {
        let e = try map("egress.firewall", ["action": .string("audit"), "layer": .string("l7"),
                                            "host": .string("api.example.com"), "port": .int(443),
                                            "method": .string("POST"), "path": .string("/v1/x?y=1"),
                                            "rule": .string("api"), "reason": .string("not permitted")])
        #expect(e["class_uid"] as? Int == 4002)
        #expect(e["activity_name"] as? String == "Post")
        #expect(e["action"] as? String == "Allowed")
        #expect(e["severity_id"] as? Int == 2)
        let req = try #require(e["http_request"] as? [String: Any])
        #expect(req["http_method"] as? String == "POST")
        let url = try #require(req["url"] as? [String: Any])
        #expect(url["path"] as? String == "/v1/x")
        #expect(url["query_string"] as? String == "y=1")
        let rule = try #require(e["firewall_rule"] as? [String: Any])
        #expect(rule["name"] as? String == "api")
        #expect(rule["type"] as? String == "openshell")
        #expect(e["status_detail"] as? String == "not permitted")
    }

    @Test("Exfiltration is a high-severity Detection Finding alert")
    func finding() throws {
        let e = try map("credential.exfiltration", ["observed_host": .string("evil.example"),
                                                    "declared_host": .string("api.github.com")])
        #expect(e["class_uid"] as? Int == 2004)
        #expect(e["is_alert"] as? Bool == true)
        #expect(e["severity"] as? String == "High")
        #expect((e["finding_info"] as? [String: Any])?["uid"] as? String == "credential-exfiltration")
    }

    @Test("Commands and file access map to System Activity classes")
    func systemActivity() throws {
        #expect(try map("command.run", ["command": .string("ls")])["class_uid"] as? Int == 1007)
        let f = try map("file.write", ["path": .string("/home/ubuntu/a.txt")])
        #expect(f["class_uid"] as? Int == 1001)
        #expect(f["activity_name"] as? String == "Update")
    }

    @Test("Downgrade to 1.3.0 strips newer fields")
    func downgrade() throws {
        var e = try map("egress.firewall", ["action": .string("allow"), "host": .string("a.com"), "port": .int(443)])
        OCSFExporter.downgrade(&e, to: "1.3.0")
        #expect(e["container"] == nil)
        #expect(e["observation_point_id"] == nil)
        #expect((e["metadata"] as? [String: Any])?["version"] as? String == "1.3.0")
    }

    @Test("Every record serializes to JSON")
    func serializes() throws {
        for type in ["egress.firewall", "guardrails.block", "credential.token_swap", "vm.disk_reset", "mystery"] {
            let e = try map(type, ["host": .string("h.example"), "n": .int(1), "a": .array([.bool(true), .null])])
            #expect(JSONSerialization.isValidJSONObject(e), "\(type)")
        }
    }
}
