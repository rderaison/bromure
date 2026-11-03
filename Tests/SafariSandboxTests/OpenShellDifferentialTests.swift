import Foundation
import Testing
@testable import SandboxEngine

/// Differential test against NVIDIA OpenShell's own engine. The oracle side
/// (OpenShell's Rego rules + request parsers, run in their crate) writes one
/// decision per generated case; this replays every case through Bromure's
/// evaluator and writes each disagreement to `mismatches.jsonl`.
///
///     OPENSHELL_DIFF_DIR=<dir with cases.jsonl + oracle.jsonl> \
///       swift test --filter OpenShellDifferentialTests
@Suite("OpenShell differential (reference engine)")
struct OpenShellDifferentialTests {
    @Test("Bromure agrees with OpenShell's engine on every generated case",
          .enabled(if: ProcessInfo.processInfo.environment["OPENSHELL_DIFF_DIR"] != nil))
    func differential() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPENSHELL_DIFF_DIR"]!)
        func lines(_ name: String) throws -> [[String: Any]] {
            try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").compactMap {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
        }
        let cases = try lines("cases.jsonl")
        var oracle: [Int: [String: Any]] = [:]
        for o in try lines("oracle.jsonl") { if let id = o["id"] as? Int { oracle[id] = o } }

        var parsed: [String: Result<OpenShellPolicy, Error>] = [:]
        var mismatches: [[String: Any]] = []
        var counts: [String: Int] = [:]
        func bump(_ k: String) { counts[k, default: 0] += 1 }

        for c in cases {
            guard let id = c["id"] as? Int, let o = oracle[id], o["panic"] == nil else { continue }
            let text = c["policy"] as? String ?? ""
            let result = parsed[text] ?? Result { try OpenShellPolicy.parse(text) }
            parsed[text] = result
            var record: [String: Any] = ["id": id]
            let oracleLoads = o["load_ok"] as? Bool ?? false
            guard case .success(let policy) = result else {
                bump("compared.load")
                if oracleLoads {
                    record["kind"] = "load"; record["bromure"] = "rejected"; record["oracle"] = "loaded"
                    if case .failure(let e) = result { record["bromure_error"] = "\(e)" }
                    mismatches.append(record)
                }
                continue
            }
            bump("compared.load")
            if !oracleLoads {
                record["kind"] = "load"; record["bromure"] = "loaded"; record["oracle"] = "rejected"
                record["oracle_error"] = o["load_error"]
                mismatches.append(record)
                continue
            }
            let identity = OpenShellPolicy.BinaryIdentity(
                exe: c["binary"] as? String ?? "", sha256: "x",
                ancestors: (c["ancestors"] as? [String] ?? []).map { .init(exe: $0, sha256: "x") })
            let host = c["host"] as? String ?? ""
            let port = UInt16(c["port"] as? Int ?? 443)
            var bromureL4 = false
            if case .allow = policy.evaluateConnect(hostnames: [host], ip: nil, port: port,
                                                    identity: identity, enforceBinaries: true) { bromureL4 = true }
            let oracleL4 = o["l4_allowed"] as? Bool ?? false
            bump("compared.l4")
            if bromureL4 != oracleL4 {
                record["kind"] = "l4"; record["bromure"] = bromureL4; record["oracle"] = oracleL4
                mismatches.append(record)
                continue
            }
            // Destination plan over injected DNS answers (the proxy resolves,
            // validates every address, then dials only those).
            if oracleL4, let answers = c["resolved"] as? [String], let oracleDest = o["dest_ok"] as? Bool {
                bump("compared.destination")
                let lookup = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let resolved = OpenShellPolicy.IPAddress(lookup).map { [$0] } ?? answers.compactMap(OpenShellPolicy.IPAddress.init)
                let verdict = policy.destinationPlan(host: host, port: port, identity: identity, enforceBinaries: true)
                    .flatMap { OpenShellPolicy.validateDestination($0, host: host, port: port, resolved: resolved) }
                var bromureDest = false, bromureReason = ""
                switch verdict {
                case .success: bromureDest = true
                case .failure(let d): bromureReason = d.reason
                }
                if bromureDest != oracleDest {
                    record["kind"] = "destination"; record["bromure"] = bromureDest; record["oracle"] = oracleDest
                    record["bromure_reason"] = bromureReason; record["oracle_reason"] = o["dest_reason"]
                    mismatches.append(record)
                    continue
                }
            }
            guard oracleL4, let req = c["request"] as? [String: Any], o["l7_error"] == nil else { continue }
            let oracleL7: Bool = (o["l7_inspected"] as? Bool == false) ? true : (o["l7_allowed"] as? Bool ?? true)
            var headers = ["content-type": "application/json"]
            if let v = req["mcp_version"] as? String { headers["mcp-protocol-version"] = v }
            for (k, v) in (req["headers"] as? [String: String]) ?? [:] { headers[k.lowercased()] = v }
            let d = policy.evaluateRequest(host: host, port: port, method: req["method"] as? String ?? "GET",
                                           target: req["target"] as? String ?? "/", headers: headers,
                                           body: (req["body"] as? String).map { Data($0.utf8) },
                                           identity: identity, enforceBinaries: true)
            let bromureL7: Bool
            var reason = ""
            switch d {
            case .allow: bromureL7 = true
            case .violation(let r, _, _): bromureL7 = false; reason = r
            }
            bump("compared.l7.\(o["l7_protocol"] as? String ?? "uninspected")")
            if bromureL7 != oracleL7 {
                record["kind"] = "l7"; record["protocol"] = o["l7_protocol"] ?? "uninspected"
                record["bromure"] = bromureL7; record["oracle"] = oracleL7
                record["bromure_reason"] = reason; record["oracle_reason"] = o["l7_reason"] ?? ""
                mismatches.append(record)
                continue
            }
            // Client text messages once the upgrade went through.
            if bromureL7, let msgs = req["ws_messages"] as? [String], let ws = o["ws"] as? [[String: Any]] {
                for (i, text) in msgs.enumerated() where i < ws.count {
                    bump("compared.ws_message")
                    let v = policy.websocketMessageDecision(host: host, port: port, target: req["target"] as? String ?? "/",
                                                            text: text, identity: identity, enforceBinaries: true)
                    var pass = true, why = ""
                    if case .deny(let r) = v { pass = false; why = r }
                    let oraclePass = ws[i]["pass"] as? Bool ?? false
                    if pass != oraclePass {
                        var r = record
                        r["kind"] = "ws_message"; r["message"] = text; r["bromure"] = pass; r["oracle"] = oraclePass
                        r["bromure_reason"] = why; r["oracle_reason"] = ws[i]["reason"] ?? ""
                        mismatches.append(r)
                    }
                }
            }
        }
        let out = mismatches.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        try (out.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("mismatches.jsonl"),
                                                      atomically: true, encoding: .utf8)
        try String(decoding: JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]), as: UTF8.self)
            .write(to: dir.appendingPathComponent("counts.json"), atomically: true, encoding: .utf8)
        #expect(mismatches.isEmpty, "\(mismatches.count) disagreements — see mismatches.jsonl")
    }
}
