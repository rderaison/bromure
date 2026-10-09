import Darwin
import Foundation
import MachO

// MARK: - Durable trace of the GUI process
//
// A quit with no crash report leaves nothing behind when the app wasn't
// started from a terminal: its stderr — its own logs, NSLog's copy, a Swift
// fatal error's text, the "caught signal N" line of the cleanup handler —
// went to /dev/null. This keeps a copy in ~/Library/Logs/BromureAC/
// bromure-ac.log, with launch / quit / fatal-signal stamps around it, so the
// last words of the previous run are always readable. stderr keeps flowing
// to wherever it went (a terminal, nowhere): the file is a tee, not a
// redirect. GUI process only; CLI verbs and engine children stay quiet.
enum AppLog {
    /// Rotate above this size at launch; one previous file is kept (.1).
    static let maxBytes: UInt64 = 8 << 20

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BromureAC/bromure-ac.log")
    }

    private static var fileFD: Int32 = -1
    private static var originalStderr: Int32 = -1
    /// Pre-rendered fatal-signal breadcrumbs, one per signal number, so the
    /// handler only ever calls write(2): 32 slots × 96 bytes.
    private static let crumbSlot = 96
    private static var crumbs: UnsafeMutablePointer<UInt8>?
    private static var crumbLengths: UnsafeMutablePointer<Int32>?
    // Type position: the C struct (in expression position `sigaction` is the function).
    private static var previousActions: [Int32: sigaction] = [:]

    /// Call once, first thing in the GUI process.
    static func install() {
        let path = url
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        rotateIfLarge(path)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        fileFD = fd
        teeStderr()
        stamp("launch pid \(getpid()) \(build()) \(ProcessInfo.processInfo.operatingSystemVersionString)")
        atexit { AppLog.exitTrace() }
        installExitHook()
        installFatalSignalBreadcrumbs()
    }

    /// The process is exiting through exit(3) — a quit, or anything else
    /// calling it (a library, a CLI path): stamp it with the backtrace of
    /// the caller. atexit handlers run inside exit() on the calling thread,
    /// so the stack names who asked. (_exit and fatal signals skip atexit;
    /// the signal breadcrumbs cover the latter.) Into the log and, when
    /// started from a terminal, its stderr too.
    static func exitTrace() {
        stamp("exit pid \(getpid()) on \(Thread.isMainThread ? "the main thread" : "a background thread"), called from:",
              alsoToTerminal: true)
        writeBacktrace()
    }

    private static func writeBacktrace() {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, Int32(frames.count))
        guard n > 0 else { return }
        if fileFD >= 0 { backtrace_symbols_fd(&frames, n, fileFD) }
        if originalStderr >= 0 { backtrace_symbols_fd(&frames, n, originalStderr) }
    }

    // MARK: _exit hook
    //
    // _exit / _Exit end the process at once — no atexit, no stamp — and a
    // macOS 15 user's app vanished that way (status 1) right after a Claude
    // sign-in. Every call this binary makes to them (our code, and libghostty,
    // linked in statically) goes through its GOT; pointing those slots at a
    // hook that logs the caller's backtrace, then calls the real _exit,
    // names who did it. Apple's frameworks live in the shared cache and are
    // left alone. A forked child (forkpty → exec failed → _exit) just exits:
    // it's not the app ending, and it mustn't log from a forked process.

    private typealias ExitFn = @convention(c) (Int32) -> Void
    private static var realExit: ExitFn?
    private static var exitTargets: [UInt] = []
    private static var appPID: pid_t = 0

    private static let exitHook: ExitFn = { code in
        if getpid() == AppLog.appPID {
            AppLog.stamp("_exit(\(code)) pid \(getpid()) on \(Thread.isMainThread ? "the main thread" : "a background thread") — ending without exit handlers, called from:",
                         alsoToTerminal: true)
            AppLog.writeBacktrace()
        }
        AppLog.realExit?(code)
    }

    private static func installExitHook() {
        guard let me = dlopen(nil, RTLD_NOW), let real = dlsym(me, "_exit") else { return }
        appPID = getpid()
        realExit = unsafeBitCast(real, to: ExitFn.self)
        let names: [String] = ["_exit", "_Exit"]
        exitTargets = names.compactMap { name in dlsym(me, name).map { UInt(bitPattern: $0) } }
        // Called for every image already loaded, then for each new one.
        _dyld_register_func_for_add_image { header, _ in AppLog.hookExitCalls(in: header) }
    }

    /// Point `image`'s GOT slots for _exit/_Exit at the hook. Shared-cache
    /// images (the system) are skipped.
    private static func hookExitCalls(in image: UnsafePointer<mach_header>?) {
        guard let image, image.pointee.flags & 0x8000_0000 == 0 else { return }   // MH_DYLIB_IN_CACHE
        let mh = UnsafeRawPointer(image).assumingMemoryBound(to: mach_header_64.self)
        let hookAddr = UInt(bitPattern: unsafeBitCast(exitHook, to: UnsafeRawPointer.self))
        let page = UInt(vm_page_size)
        for (seg, sect) in [("__DATA_CONST", "__got"), ("__DATA", "__got"), ("__DATA", "__la_symbol_ptr"),
                            ("__AUTH_CONST", "__auth_got"), ("__DATA_CONST", "__auth_got")] {
            var size: UInt = 0
            guard let data = getsectiondata(mh, seg, sect, &size), size > 0 else { continue }
            let slots = UnsafeMutableRawPointer(data).assumingMemoryBound(to: UInt.self)
            for i in 0..<(Int(size) / MemoryLayout<UInt>.size) where exitTargets.contains(slots[i]) {
                let start = UInt(bitPattern: slots + i) & ~(page - 1)
                guard let p = UnsafeMutableRawPointer(bitPattern: start),
                      mprotect(p, Int(page), PROT_READ | PROT_WRITE) == 0 else { continue }
                slots[i] = hookAddr
                mprotect(p, Int(page), PROT_READ)
            }
        }
    }

    /// One dated line straight into the file (not via stderr, so it lands
    /// even when the tee is gone).
    /// `alsoToTerminal`: the original stderr too (the exit traces, whose
    /// backtrace goes there as well when started from a terminal).
    static func stamp(_ text: String, alsoToTerminal: Bool = false) {
        guard fileFD >= 0 else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "=== \(f.string(from: Date())) \(text)\n"
        line.utf8CString.withUnsafeBufferPointer { buf in
            writeAll(fileFD, UnsafeRawPointer(buf.baseAddress!), buf.count - 1)
            if alsoToTerminal, originalStderr >= 0 {
                writeAll(originalStderr, UnsafeRawPointer(buf.baseAddress!), buf.count - 1)
            }
        }
    }

    // MARK: stderr tee

    /// fd 2 becomes a pipe; a thread copies everything to the file and to
    /// the original fd 2.
    private static func teeStderr() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        originalStderr = dup(STDERR_FILENO)
        guard dup2(fds[1], STDERR_FILENO) >= 0 else {
            close(fds[0]); close(fds[1]); return
        }
        close(fds[1])
        let readFD = fds[0], file = fileFD, orig = originalStderr
        let pump = Thread {
            let cap = 1 << 14
            let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 1)
            defer { buf.deallocate() }
            while true {
                let n = read(readFD, buf, cap)
                if n < 0 { if errno == EINTR { continue }; break }
                if n == 0 { break }
                writeAll(file, buf, n)
                if orig >= 0 { writeAll(orig, buf, n) }
            }
        }
        pump.name = "bromure-ac.stderr-tee"
        pump.qualityOfService = .utility
        pump.start()
    }

    /// Whole-buffer write with partial-write and EINTR handling; gives up
    /// on any other error (a closed original stderr just stops receiving).
    private static func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int) {
        var done = 0
        while done < count {
            let n = write(fd, p + done, count - done)
            if n < 0 { if errno == EINTR { continue }; return }
            done += n
        }
    }

    private static func rotateIfLarge(_ path: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let previous = path.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: path, to: previous)
    }

    private static func build() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let buildNo = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(buildNo))"
    }

    // MARK: fatal-signal breadcrumbs

    /// A crash the system (or the terminal layer's own crash handler) may or
    /// may not report still gets one line here. The handler is
    /// async-signal-safe — it writes pre-rendered bytes with write(2) — then
    /// hands the signal to whatever handler was installed before (a crash
    /// reporter's, or the default), so nothing else changes.
    private static func installFatalSignalBreadcrumbs() {
        let signals: [(Int32, String)] = [
            (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"),
            (SIGABRT, "SIGABRT"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE"),
        ]
        let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 32 * crumbSlot)
        table.initialize(repeating: 0, count: 32 * crumbSlot)
        let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: 32)
        lengths.initialize(repeating: 0, count: 32)
        for (sig, name) in signals where sig >= 0 && sig < 32 {
            let text = "\n=== fatal signal \(sig) (\(name)) pid \(getpid()) — see the crash report or the sentry envelope\n"
            let bytes = Array(text.utf8.prefix(crumbSlot - 1))
            for (i, b) in bytes.enumerated() { table[Int(sig) * crumbSlot + i] = b }
            lengths[Int(sig)] = Int32(bytes.count)
        }
        crumbs = table
        crumbLengths = lengths
        for (sig, _) in signals {
            var previous = sigaction()
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { sig, _, _ in AppLog.onFatal(sig) }
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            if sigaction(sig, &action, &previous) == 0 {
                previousActions[sig] = previous
            }
        }
    }

    /// Runs in signal context: pre-rendered bytes, write(2), then re-deliver
    /// with the previous disposition restored. Nothing here allocates.
    private static func onFatal(_ sig: Int32) {
        if let table = crumbs, let lengths = crumbLengths, sig >= 0, sig < 32, fileFD >= 0 {
            let n = Int(lengths[Int(sig)])
            if n > 0 { _ = write(fileFD, table + Int(sig) * crumbSlot, n) }
        }
        if var previous = previousActions[sig] {
            sigaction(sig, &previous, nil)
        } else {
            signal(sig, SIG_DFL)
        }
        raise(sig)
    }
}

/// `__exit-hook-test`: a named caller for the hook's backtrace to show.
@inline(never) func exitHookTestBailOut() -> Never { _exit(3) }
