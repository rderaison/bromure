import Foundation
import Darwin

/// `POST /vms/{id}/exec` (non-interactive) and `POST /vms/{id}/file`, run on
/// this Mac as the user. The client was written for a Linux guest whose home
/// is /home/ubuntu (drop folders, pinned transcripts): that prefix maps to
/// the real home. The rest of what it runs (tmux, ps, find, python3…) works
/// on macOS as is, given the shims first on the PATH.
enum HostExec {
    static let guestHome = "/home/ubuntu"

    static func mapHome(_ s: String) -> String {
        s.replacingOccurrences(of: guestHome, with: NSHomeDirectory())
    }

    static func run(_ body: [String: Any]) -> (status: Int, body: [String: Any]) {
        let timeout = TimeInterval((body["timeout"] as? Int) ?? 30)
        let r: HostProcess.Result
        if let argv = body["argv"] as? [String], let first = argv.first {
            // A verbatim argument vector: run it without a shell, resolving
            // the program on our PATH.
            let mapped = argv.map(mapHome)
            r = HostProcess.run(executable: "/usr/bin/env", args: [first] + mapped.dropFirst(),
                                env: HostEnvironment.forCommands(), cwd: NSHomeDirectory(), timeout: timeout)
        } else {
            let command = (body["command"] as? String) ?? ""
            guard !command.isEmpty else { return (400, ["error": "Missing 'command' field"]) }
            r = HostProcess.run(executable: "/bin/bash", args: ["-c", mapHome(command)],
                                env: HostEnvironment.forCommands(), cwd: NSHomeDirectory(), timeout: timeout)
        }
        if UserDefaults.standard.bool(forKey: "debugExec") {
            // `defaults write io.bromure.native debugExec -bool YES`: every
            // client command, how it ended, and the start of what it said.
            let cmd = (body["command"] as? String) ?? ((body["argv"] as? [String])?.joined(separator: " ") ?? "")
            AgentHostLog.log("exec[\(r.status)\(r.timedOut ? " timeout" : "")] \(cmd.prefix(400))\n"
                + "  stdout: \(r.stdout.prefix(300))\n  stderr: \(r.stderr.prefix(300))")
            // The whole of the last command that printed nothing, to re-run.
            if r.stdout.isEmpty {
                try? cmd.write(to: AgentHostPaths.support.appendingPathComponent("last-empty-exec.sh"),
                               atomically: true, encoding: .utf8)
            }
        }
        return (200, ["stdout": r.stdout, "stderr": r.stderr,
                      "exitCode": r.timedOut ? 124 : Int(r.status)])
    }

    static let readMax = 8 << 20

    /// bromure-agentd's `_file_op`, on this Mac.
    static func fileOp(_ spec: [String: Any]) -> [String: Any] {
        let op = spec["op"] as? String ?? ""
        let path = mapHome(spec["path"] as? String ?? "")
        let fm = FileManager.default
        guard path.hasPrefix("/") else { return ["error": "path must be absolute", "exit_code": 1] }
        do {
            switch op {
            case "list":
                let url = URL(fileURLWithPath: path)
                let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
                let entries: [[String: Any]] = items.map { u in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    return ["name": u.lastPathComponent,
                            "dir": (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                            "link": v?.isSymbolicLink == true,
                            "size": v?.fileSize ?? 0,
                            "mtime": Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)]
                }
                return ["entries": entries, "exit_code": 0]
            case "read":
                let offset = UInt64(spec["offset"] as? Int ?? 0)
                let length = min(max(0, spec["length"] as? Int ?? readMax), readMax)
                guard let h = FileHandle(forReadingAtPath: path) else {
                    return ["error": "can't read \(path)", "exit_code": 1]
                }
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                try h.seek(toOffset: offset)
                let data = try h.read(upToCount: length) ?? Data()
                return ["data": data.base64EncodedString(), "size": Int(size),
                        "eof": offset + UInt64(data.count) >= size, "exit_code": 0]
            case "write":
                let data = Data(base64Encoded: spec["data"] as? String ?? "") ?? Data()
                if spec["append"] as? Bool == true, let h = FileHandle(forWritingAtPath: path) {
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                } else {
                    try data.write(to: URL(fileURLWithPath: path))
                }
                return ["exit_code": 0]
            case "mkdir":
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                return ["exit_code": 0]
            case "untar":
                let archive = mapHome(spec["archive"] as? String ?? "")
                guard archive.hasPrefix("/") else { return ["error": "archive must be absolute", "exit_code": 1] }
                defer { try? fm.removeItem(atPath: archive) }
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                // bsdtar refuses absolute names and `..` by default (no -P).
                let r = HostProcess.run(executable: "/usr/bin/tar", args: ["-xf", archive, "-C", path],
                                        env: ["PATH": "/usr/bin:/bin"], timeout: 120)
                return r.status == 0 ? ["exit_code": 0] : ["error": r.stderr, "exit_code": 1]
            case "remove":
                try fm.removeItem(atPath: path)
                return ["exit_code": 0]
            default:
                return ["error": "unknown file op \(op)", "exit_code": 1]
            }
        } catch {
            return ["error": error.localizedDescription, "exit_code": 1]
        }
    }
}

/// The interactive exec stream behind every client terminal: the HTTP
/// response header, then PTY frames both ways — `[type u8][len u32be]
/// [payload]`, 0 data, 1 resize (cols u16be, rows u16be), 2 exit (i32be),
/// 3 stdin EOF — the framing bromure-agentd speaks over vsock. A `view`
/// attach becomes a grouped tmux session on window `window`.
enum PTYBridge {
    static func run(clientFD: Int32, body: [String: Any]) {
        let cols = UInt16(clamping: body["cols"] as? Int ?? 80)
        let rows = UInt16(clamping: body["rows"] as? Int ?? 24)
        let command = (body["command"] as? String) ?? ""
        let shellCommand: String
        if let view = body["view"] as? String {
            shellCommand = Tmux.viewAttachCommand(view: view, window: body["window"] as? Int,
                                                  sizePassive: body["sizePassive"] as? Bool == true)
        } else if command.isEmpty {
            shellCommand = "exec \(shellQuote(Tmux.userShell)) -l"
        } else {
            shellCommand = HostExec.mapHome(command)
        }
        var env = HostEnvironment.forCommands()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let (pid, master) = PTYSpawn.spawn(path: "/bin/sh", argv: ["/bin/sh", "-c", shellCommand],
                                           env: env.map { "\($0.key)=\($0.value)" }, win: &win)
        guard pid > 0, master >= 0 else {
            let msg = #"{"error":"couldn't start a terminal"}"#
            ControlServer.writeAll(clientFD, Data("HTTP/1.1 500 Error\r\nContent-Type: application/json\r\nContent-Length: \(msg.utf8.count)\r\nConnection: close\r\n\r\n\(msg)".utf8))
            close(clientFD)
            return
        }
        ControlServer.writeAll(clientFD, Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n".utf8))

        let done = DispatchSemaphore(value: 0)
        // Client → PTY.
        Thread.detachNewThread {
            var header = [UInt8](repeating: 0, count: 5)
            while readFull(clientFD, &header, 5) {
                let len = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
                guard len <= 1 << 20 else { break }
                var payload = [UInt8](repeating: 0, count: len)
                if len > 0, !readFull(clientFD, &payload, len) { break }
                switch header[0] {
                case 0:
                    ControlServer.writeAll(master, Data(payload))
                case 1 where len >= 4:
                    var ws = winsize(ws_row: UInt16(payload[2]) << 8 | UInt16(payload[3]),
                                     ws_col: UInt16(payload[0]) << 8 | UInt16(payload[1]),
                                     ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(master, TIOCSWINSZ, &ws)
                default:
                    break
                }
            }
            // The client went away: hang the terminal up.
            kill(pid, SIGHUP)
            done.signal()
        }
        // PTY → client, then the exit frame.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 1 << 15)
            while true {
                let n = read(master, &buf, buf.count)
                if n > 0 {
                    sendFrame(clientFD, 0, Array(buf[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            let be = UInt32(bitPattern: code).bigEndian
            sendFrame(clientFD, 2, withUnsafeBytes(of: be) { Array($0) })
            // Wakes the reader: its read() on the socket sees the shutdown.
            shutdown(clientFD, SHUT_RDWR)
            done.signal()
        }
        done.wait()
        done.wait()
        close(master)
        close(clientFD)
    }

    private static func sendFrame(_ fd: Int32, _ type: UInt8, _ payload: [UInt8]) {
        var frame = [type]
        let len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: len) { frame += $0 }
        frame += payload
        ControlServer.writeAll(fd, Data(frame))
    }

    private static func readFull(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}
