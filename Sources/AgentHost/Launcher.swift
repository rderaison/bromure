import AppKit
import Darwin

/// `bromure-native claude [args…]` (or the `bromure-claude` link to it):
/// start Claude in the current folder as a hosted session and attach this
/// terminal to it. Detaching, or closing the terminal, leaves the agent
/// running — it stays reachable from Bromure AC and from the menu.
enum Launcher {
    static func runClaude(args: [String]) -> Int32 {
        guard ensureAppRunning() else {
            FileHandle.standardError.write(Data("bromure-claude: Bromure Native isn't running and couldn't be started.\n".utf8))
            return 1
        }
        let body: [String: Any] = ["tool": "claude", "cwd": FileManager.default.currentDirectoryPath,
                                   "extraArgs": args]
        guard let r = request("POST", "/agent-sessions/start", body: body),
              let window = r["window"] as? Int else {
            FileHandle.standardError.write(Data("bromure-claude: couldn't start the session.\n".utf8))
            return 1
        }
        let attach = Tmux.viewAttachCommand(view: "cli-\(getpid())", window: window, sizePassive: false)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(attach), nil]
        execve("/bin/sh", argv, cEnv)
        perror("bromure-claude: exec")
        return 1
    }

    /// The control socket answers, or the app was launched and it came up.
    private static func ensureAppRunning() -> Bool {
        if request("GET", "/health", body: nil) != nil { return true }
        // This binary lives in the app bundle; open that bundle.
        let exe = URL(fileURLWithPath: AgentHostPaths.executable)
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", app.path]
            try? p.run()
            p.waitUntilExit()
        }
        for _ in 0..<50 {
            if request("GET", "/health", body: nil) != nil { return true }
            usleep(200_000)
        }
        return false
    }

    /// One control-socket request; the JSON body of a 2xx reply.
    static func request(_ method: String, _ path: String, body: [String: Any]?) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(AgentHostPaths.controlSocket.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        let payload = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        ControlServer.writeAll(fd, Data(head.utf8) + payload)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let status = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
            .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard (200..<300).contains(status) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data[sep.upperBound...])) as? [String: Any]
    }
}
