import Foundation

/// The proxy's trace for the CLI and a fat client's Trace Inspector (macOS:
/// the automation server's /trace routes over MitmEngine.traceStore).
extension Daemon {
    /// `GET|DELETE /trace`, `GET /trace/records`, `GET /trace/body`
    /// (`?profile=`, `?id=&kind=`); nil for any other path.
    // @port ACAutomationServer.handleTraceRoute(fd: Int32, method: String, path: String) h=7f3400e099ae79fd @7dd92fdf
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case (let m, let p) where p == "/trace" || p.hasPrefix("/trace?") || p.hasPrefix("/trace/"): h=d65fdfd9969838f9 @f127f8ab
    // partial: DELETE /trace case
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onClearTrace h=36666f0771dbb649 @d3ebbda2
    func traceRoute(_ method: String, _ path: String) async -> ControlResponse? {
        guard path == "/trace" || path.hasPrefix("/trace?") || path.hasPrefix("/trace/") else { return nil }
        // Split "/path?a=b&c=d" into the bare path + a decoded query map.
        let bare: String
        var query: [String: String] = [:]
        if let qIdx = path.firstIndex(of: "?") {
            bare = String(path[..<qIdx])
            for pair in path[path.index(after: qIdx)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        } else {
            bare = path
        }
        let profileKey = query["profile"]
        guard let mitm else { return .error(503, "The Bromure proxy isn't running") }

        switch bare {
        case "/trace/records":
            guard method == "GET" else { return .error(405, "Method not allowed") }
            let recs = await MainActor.run { Self.traceRecords(mitm, profileKey) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let rows: [JSONValue] = recs.compactMap { rec in
                guard let data = try? encoder.encode(rec) else { return nil }
                return try? JSONDecoder().decode(JSONValue.self, from: data)
            }
            return ControlResponse(200, ["records": .array(rows)])
        case "/trace/body":
            guard method == "GET" else { return .error(405, "Method not allowed") }
            guard let idStr = query["id"], let id = UUID(uuidString: idStr),
                  let kind = query["kind"].flatMap(TraceStore.BodyKind.init(rawValue:)) else {
                return .error(400, "id and kind (request|response) required")
            }
            let data = await MainActor.run { Self.loadTraceBody(mitm, id, kind) }
            return ControlResponse(200, ["body": .string(data?.base64EncodedString() ?? "")])
        case "/trace":
            switch method {
            case "GET":
                let rows = await MainActor.run { Self.traceList(mitm, profileKey) }
                return ControlResponse(200, ["trace": JSONValue(foundation: rows) ?? .array([])])
            case "DELETE":
                let n = await MainActor.run { mitm.traces.withLockedValue { $0 }?.clear() ?? 0 }
                return ControlResponse(200, ["cleared": .number(Double(n))])
            default:
                return .error(405, "Method not allowed")
            }
        default:
            return .error(404, "Not found", ["path": .string(path)])
        }
    }

    /// Newest first; previews only (no secret values).
    // @port ACAppDelegate.automationTraceList(_: String?) h=d7fbe52a7b667aeb @7057d502
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListTrace h=e3a2e9c503ffccad @d3ebbda2
    @MainActor
    static func traceList(_ mitm: MitmProxy, _ profileKey: String?) -> [[String: Any]] {
        guard let store = mitm.traces.withLockedValue({ $0 }) else { return [] }
        let wantID: Profile.ID? = profileKey.flatMap { LinuxSessionHost.shared?.profileByNameOrID($0)?.id }
        let iso = ISO8601DateFormatter()
        return store.recent.compactMap { rec -> [String: Any]? in
            if let wantID, rec.profileID != wantID { return nil }
            return [
                "id": rec.id.uuidString,
                "time": iso.string(from: rec.timestamp),
                "profileId": rec.profileID.uuidString,
                "profileShort": String(rec.profileID.uuidString.prefix(8)).lowercased(),
                "host": rec.host,
                "port": rec.port,
                "method": rec.method,
                "path": rec.path,
                "status": rec.statusCode,
                "requestBytes": rec.requestBytes,
                "responseBytes": rec.responseBytes,
                "latencyMs": rec.latencyMs,
                "swaps": rec.swaps.count,
                "leaks": rec.leaks.map {
                    ["header": $0.header, "preview": $0.valuePreview, "suspicion": $0.suspicion.rawValue]
                },
                "conversation": rec.isConversation,
            ]
        }
    }

    /// Full records (newest first), optionally one workspace's: the fat
    /// client's Trace Inspector binds to these.
    // @port ACAppDelegate.automationTraceRecords(_: String?) h=78344f1160a31ba2 @7057d502
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListTraceRecords h=66727b3f5617966d @d3ebbda2
    @MainActor
    static func traceRecords(_ mitm: MitmProxy, _ profileKey: String?) -> [TraceRecord] {
        guard let store = mitm.traces.withLockedValue({ $0 }) else { return [] }
        let wantID: Profile.ID? = profileKey.flatMap { LinuxSessionHost.shared?.profileByNameOrID($0)?.id }
        return store.recent.filter { wantID == nil || $0.profileID == wantID }
    }

    /// One record's captured body, decrypted for the client.
    // @port ACAppDelegate.automationLoadTraceBody(_: UUID, _: TraceStore.BodyKind) h=4dec182992b385ae @7057d502
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onLoadTraceBody h=50e29fc842e693b0 @d3ebbda2
    @MainActor
    static func loadTraceBody(_ mitm: MitmProxy, _ id: UUID, _ kind: TraceStore.BodyKind) -> Data? {
        guard let store = mitm.traces.withLockedValue({ $0 }),
              let rec = store.recent.first(where: { $0.id == id }) else { return nil }
        return store.loadBody(for: rec, kind: kind)
    }
}
