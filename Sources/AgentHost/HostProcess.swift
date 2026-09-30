import Foundation

/// Runs a process to completion with a timeout, capturing both streams.
enum HostProcess {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
    }

    static func run(executable: String, args: [String], env: [String: String],
                    cwd: String? = nil, stdin: Data? = nil, timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch {
            return Result(status: 127, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }
        if let stdin {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        // Drain both pipes concurrently: a child that fills one while we
        // block reading the other would deadlock.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            timedOut = true
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(1, timeout), execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self),
                      timedOut: timedOut)
    }
}

/// The environment of everything the agent host runs for a client: the
/// user's own login PATH (so `git`, `claude`, `node` resolve as in their
/// terminal) behind our `bin/` of compatibility shims.
enum HostEnvironment {
    private static let lock = NSLock()
    private static var loginPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

    /// Ask the user's login shell for its PATH once (in the background — a
    /// slow .zshrc must not hold up launch). Marker-delimited: rc files print.
    static func captureLoginPath() {
        DispatchQueue.global(qos: .utility).async {
            let r = HostProcess.run(executable: Tmux.userShell,
                                    args: ["-l", "-i", "-c", "printf '\\n@@PATH@@%s@@\\n' \"$PATH\""],
                                    env: ["HOME": NSHomeDirectory(), "USER": NSUserName(),
                                          "TERM": "dumb", "LANG": "en_US.UTF-8"],
                                    timeout: 15)
            guard let s = r.stdout.range(of: "@@PATH@@"),
                  let e = r.stdout.range(of: "@@", range: s.upperBound..<r.stdout.endIndex) else {
                AgentHostLog.log("env: couldn't read the login PATH (status \(r.status))")
                return
            }
            let path = String(r.stdout[s.upperBound..<e.lowerBound])
            guard !path.isEmpty else { return }
            lock.lock(); loginPath = path; lock.unlock()
            AgentHostLog.log("env: login PATH captured")
        }
    }

    static func forCommands() -> [String: String] {
        lock.lock(); let path = loginPath; lock.unlock()
        return [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": Tmux.userShell,
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "PATH": AgentHostPaths.binDir.path + ":" + path,
        ]
    }

    /// `bin/tmux` (our server, whatever tmux the user has) and `bin/ps`
    /// (GNU's `etimes`, which the client's liveness probe asks for and BSD
    /// ps lacks). Rewritten at every launch: the app may have moved.
    static func writeShims() {
        AgentHostPaths.linkStableExecutable()
        let tmux = """
        #!/bin/sh
        # Bromure Sidecar: our tmux server, on its own socket.
        exec \(shellQuote(Tmux.binary)) -L \(Tmux.socketName) -f \(shellQuote(AgentHostPaths.tmuxConf.path)) "$@"

        """
        // BSD ps prints etime as [[dd-]hh:]mm:ss; GNU's etimes is seconds.
        let ps = #"""
        #!/bin/bash
        # Bromure Sidecar: GNU ps's `etimes` (elapsed seconds) on BSD ps.
        # And a terminal's processes (`-t TTY -o a=,b=`) oldest first: the
        # client takes the first non-shell foreground process as the tab's
        # agent, which holds on Linux (pids ascend) but not here — Claude
        # keeps a `caffeinate` child in the foreground, and a wrapped pid
        # listed it first, so a young helper passed for the agent.
        tty=0; spec=""; nx=0
        for a in "$@"; do
          if [ $nx = 1 ]; then spec="$a"; nx=0; continue; fi
          case "$a" in -t) tty=1 ;; -o) nx=1 ;; esac
        done
        if [ $tty = 1 ] && [ -n "$spec" ] && [[ "$spec" != *etime* ]] && [[ "$spec" =~ ^([a-z]+=,)*[a-z]+=$ ]]; then
          args=(); nx=0
          for a in "$@"; do
            if [ $nx = 1 ]; then args+=("etime=,$a"); nx=0; continue; fi
            [ "$a" = "-o" ] && nx=1
            args+=("$a")
          done
          /bin/ps "${args[@]}" | awk '{
            f = $1; d = 0
            if (index(f, "-")) { split(f, a, "-"); d = a[1]; f = a[2] }
            n = split(f, t, ":"); s = 0
            for (j = 1; j <= n; j++) s = s * 60 + t[j]
            sub(/^[ \t]*[^ \t]+[ \t]+/, "")
            printf "%d\t%s\n", d * 86400 + s, $0
          }' | sort -s -t "$(printf '\t')" -k1,1nr | cut -f2-
          exit ${PIPESTATUS[0]}
        fi
        case " $* " in *etimes*) ;; *) exec /bin/ps "$@" ;; esac
        args=()
        for a in "$@"; do args+=("${a//etimes/etime}"); done
        /bin/ps "${args[@]}" | awk '{
          out = ""
          for (i = 1; i <= NF; i++) {
            f = $i
            if (f ~ /^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/) {
              d = 0
              if (index(f, "-")) { split(f, a, "-"); d = a[1]; f = a[2] }
              n = split(f, t, ":"); s = 0
              for (j = 1; j <= n; j++) s = s * 60 + t[j]
              f = d * 86400 + s
            }
            out = out (i > 1 ? " " : "") f
          }
          print out
        }'

        """#
        // BSD find has no -printf (the file browser lists folders with
        // `-printf '%y%f\0'`): such calls go to our own `__find` (a readdir
        // walk, FindCommand). Nor can BSD's -newerXt parse GNU's "@<epoch>"
        // (the client floors transcripts with `-newermt @N`): turned into a
        // date BSD reads.
        let find = #"""
        #!/bin/bash
        # Bromure Sidecar: GNU find's -printf and `-newermt @<epoch>` on macOS.
        for a in "$@"; do
          [ "$a" = "-printf" ] && exec \#(shellQuote(AgentHostPaths.stableExecutable)) __find "$@"
        done
        args=(); conv=0
        for a in "$@"; do
          if [ $conv = 1 ] && [[ "$a" == @* ]]; then
            a=$(/bin/date -r "${a#@}" '+%Y-%m-%d %H:%M:%S')
          fi
          conv=0
          case "$a" in -newer[amcB]t) conv=1 ;; esac
          args+=("$a")
        done
        exec /usr/bin/find "${args[@]}"

        """#
        // GNU stat's -c FORMAT (the review window asks for %s, the size).
        let stat = #"""
        #!/bin/bash
        # Bromure Sidecar: GNU stat's `-c FORMAT` on BSD stat.
        args=(); fmt=0
        for a in "$@"; do
          if [ $fmt = 1 ]; then args+=("-f" "${a//%s/%z}"); fmt=0; continue; fi
          case "$a" in
            -c) fmt=1 ;;
            -c*) f="${a#-c}"; args+=("-f" "${f//%s/%z}") ;;
            *) args+=("$a") ;;
          esac
        done
        exec /usr/bin/stat "${args[@]}"

        """#
        for (name, body) in [("tmux", tmux), ("ps", ps), ("find", find), ("stat", stat)] {
            let url = AgentHostPaths.binDir.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
