import Foundation
import Glibc

// `bromure-ac mcp` on a Linux server (MCPServer.swift is shared): the API
// is the daemon's control socket (macOS: the app's localhost port), and the
// four profile tools go through its /profiles routes (macOS: the app's
// AppleScript commands, which have no Linux counterpart).

extension MCP {
    /// The daemon's control socket (unix:<path>); an http://host:port base
    /// still works.
    // partial: this user's control socket (macOS: the app's localhost port)
    // @port MCP.static var defaultAPIURL h=27956c75f269c254 @86956704
    static var defaultAPIURL: String { "unix:" + DaemonConfig.fromEnvironment().controlSocketPath }

    /// Nothing to stop: run() polls its flag on the main run loop.
    // partial: corelibs exposes no CFRunLoopStop (run() polls its flag)
    // @port MCP.static stopMainLoop() h=c2fa2ba00c20a923 @86956704
    static func stopMainLoop() {}
}

// @port-skip linux-only: see MCPLinux.swift
struct MCPAPIError: Error { let message: String }

extension ACMCPServerImpl {
    /// A connected socket to the API at `base` ("unix:<path>", or
    /// http://host:port with a numeric host), and its Host header.
    // partial: unix:<path> (the control socket) too
    // @port ACMCPServerImpl.static openAPI(base: String) h=89ea226b1dfc75bd @86956704
    nonisolated static func openAPI(base: String) -> Result<(fd: Int32, host: String), MCPAPIError> {
        if base.hasPrefix("unix:") {
            let path = String(base.dropFirst("unix:".count))
            guard let fd = P2PIngressForwarder.connectUnix(path) else {
                return .failure(MCPAPIError(message: "No bromure-ac daemon at \(path)"))
            }
            return .success((fd, "localhost"))
        }
        guard let url = URL(string: base), let host = url.host, let port = url.port,
              let fd = P2PTCP.connect(ip: host, port: port, timeout: 5) else {
            return .failure(MCPAPIError(message: "Invalid API URL"))
        }
        return .success((fd, "\(host):\(port)"))
    }

    /// The profile tools over the daemon's /profiles routes, answering as
    /// the AppleScript commands do ("ok", the value, or "error: …").
    // partial: over /profiles routes (no AppleScript); apiKey reads blank (the export strips secrets, as the JSON tool does on macOS)
    // @port ACMCPServerImpl.profileCommand(_: MCPProfileOp) h=7987d6f80751b0c3 @86956704
    func profileCommand(_ op: MCPProfileOp) async throws -> String {
        func seg(_ s: String) -> String { ControlClient.encodeSegment(s) }
        func full(_ p: String) async throws -> [String: Any]? {
            let r = try await apiCall("GET", "/profiles/\(seg(p))?full=1")
            return r["error"] == nil ? r : nil
        }
        func put(_ p: String, _ doc: [String: Any]) async throws -> String {
            let r = try await apiCall("PUT", "/profiles/\(seg(p))", body: doc)
            if r["ok"] as? Bool == true { return "ok" }
            return "error: \(r["error"] as? String ?? "update failed")"
        }
        switch op {
        case .getJSON(let p):
            guard let d = try await full(p) else { return "error: profile not found" }
            return jsonString(d)
        case .setJSON(let p, let json):
            guard let doc = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return "error: JSON body required"
            }
            guard try await full(p) != nil else { return "error: profile not found" }
            var d = doc
            d.removeValue(forKey: "id")   // the workspace keeps its identity
            return try await put(p, d)
        case .getSetting(let p, let k):
            guard let d = try await full(p) else { return "error: profile not found" }
            return Self.setting(d, k)
        case .setSetting(let p, let k, let v):
            guard try await full(p) != nil else { return "error: profile not found" }
            switch Self.settingDoc(k, v) {
            case .success(let doc): return try await put(p, doc)
            case .failure(let e): return "error: \(e.message)"
            }
        }
    }

    /// A simple setting's value from the profile's JSON, as macOS's `get
    /// profile setting` gives it.
    // @port-skip linux-only: see profileCommand
    nonisolated static func setting(_ d: [String: Any], _ k: String) -> String {
        func str(_ key: String) -> String { (d[key] as? String) ?? "" }
        func num(_ key: String) -> String { (d[key] as? NSNumber).map { "\($0.intValue)" } ?? "" }
        switch k {
        case "name", "color", "comments", "tool", "authMode", "closeAction", "keyboardLayoutOverride": return str(k)
        case "apiKey": return str("apiKey")
        case "memoryGB", "keyRepeatDelayMs", "keyRepeatRateHz": return num(k)
        case "folderPathsCount": return "\((d["folderPaths"] as? [Any])?.count ?? 0)"
        case "mcpServerCount": return "\((d["mcpServers"] as? [Any])?.count ?? 0)"
        default: return "error: unknown key '\(k)'"
        }
    }

    /// The one-field document `set profile setting` saves, checked as macOS
    /// checks it.
    // @port-skip linux-only: see profileCommand
    nonisolated static func settingDoc(_ k: String, _ v: String) -> Result<[String: Any], MCPAPIError> {
        switch k {
        case "name", "comments": return .success([k: v])
        case "color":
            guard ProfileColor(rawValue: v) != nil else { return .failure(MCPAPIError(message: "invalid color '\(v)'")) }
            return .success([k: v])
        case "tool":
            guard Profile.Tool(rawValue: v) != nil else { return .failure(MCPAPIError(message: "invalid tool '\(v)'")) }
            return .success([k: v])
        case "authMode":
            guard Profile.AuthMode(rawValue: v) != nil else { return .failure(MCPAPIError(message: "invalid authMode '\(v)'")) }
            return .success([k: v])
        case "closeAction":
            guard Profile.CloseAction(rawValue: v) != nil else { return .failure(MCPAPIError(message: "invalid closeAction '\(v)'")) }
            return .success([k: v])
        case "apiKey", "keyboardLayoutOverride": return .success([k: v.isEmpty ? NSNull() : v])
        case "memoryGB":
            guard let n = Int(v), n >= 1 else { return .failure(MCPAPIError(message: "memoryGB must be a positive integer")) }
            return .success([k: n])
        case "keyRepeatDelayMs", "keyRepeatRateHz": return .success([k: Int(v).map { $0 as Any } ?? NSNull()])
        default: return .failure(MCPAPIError(message: "unknown key '\(k)'"))
        }
    }
}

/// `bromure-ac mcp` for the Linux CLI (MCP is internal to this module).
// @port-skip linux-only: the Linux CLI's entry to the shared MCP command
public enum LinuxMCP {
    // @port-skip linux-only: see LinuxMCP
    public static func run(_ arguments: [String]) throws {
        var command = try MCP.parse(arguments)
        try command.run()
    }
}
