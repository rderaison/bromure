import Darwin
import Foundation

/// One running app per state.
///
/// The GUI process (`run`, windowed or headless) takes `<state>/instance.lock`
/// with `flock(2)` before it touches anything else in the state — the control
/// socket above all: `ACAutomationServer` unlinks a stale socket when it
/// starts, which, without this lock, let a second process on the same state
/// silently steal the CLI from the first. A second launch now exits with
/// "state X is in use by pid N (build Y)".
///
/// Next to the lock, `instance.json` says who holds it: pid, build (name,
/// version, commit), state, mode, the automation port once it is bound, and
/// when it started. `state ls` and `instance ls` read it; the lock is what
/// says whether it is still true (a crashed instance leaves the file, the
/// kernel drops the lock).
enum ACInstance {
    static let lockFileName = "instance.lock"
    static let infoFileName = "instance.json"

    /// How the app was started.
    enum Mode: String { case gui, headless, hidden }

    /// What a holder recorded about itself.
    struct Info: Codable, Equatable {
        var pid: Int32
        var build: String
        var version: String?
        var commit: String?
        var bundlePath: String
        var state: String
        var statePath: String
        var mode: String
        var automationPort: Int?
        var startedAt: Date
    }

    enum Failure: Error, CustomStringConvertible {
        case inUse(by: Info?, state: String)
        case io(String)

        var description: String {
            switch self {
            case .inUse(let info, let state):
                if let info {
                    return "state '\(state)' is in use by pid \(info.pid) (build \(info.build))"
                }
                return "state '\(state)' is in use by another instance"
            case .io(let s): return s
            }
        }
    }

    private static var lockFD: Int32 = -1
    private static var heldStateURL: URL?

    /// True once this process holds its state's lock.
    static var isHolder: Bool { lockFD >= 0 }

    /// Take the state's lock, or throw `.inUse` with whatever the holder wrote.
    /// Creates the state directory. Idempotent.
    static func acquire(mode: Mode, stateURL: URL = ACSupportDir.url) throws {
        if isHolder { return }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let lockURL = stateURL.appendingPathComponent(lockFileName)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("can't open \(lockURL.path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                throw Failure.inUse(by: read(stateURL: stateURL), state: ACSupportDir.stateName)
            }
            throw Failure.io("can't lock \(lockURL.path): \(String(cString: strerror(err)))")
        }
        lockFD = fd
        heldStateURL = stateURL
        write(Info(pid: getpid(), build: buildName, version: bundleVersion, commit: bundleCommit,
                   bundlePath: Bundle.main.bundleURL.path, state: ACSupportDir.stateName,
                   statePath: stateURL.path, mode: mode.rawValue, automationPort: nil,
                   startedAt: Date()))
    }

    /// Record the automation server's bound port (0 until it listens).
    static func recordAutomationPort(_ port: Int?) {
        guard isHolder, var info = read(stateURL: heldStateURL ?? ACSupportDir.url) else { return }
        info.automationPort = port
        write(info)
    }

    /// At a clean quit: drop `instance.json` and the lock.
    static func release() {
        guard isHolder, let stateURL = heldStateURL else { return }
        try? FileManager.default.removeItem(at: stateURL.appendingPathComponent(infoFileName))
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
        heldStateURL = nil
    }

    /// Whether some process holds the lock of the state at `stateURL`, and
    /// what it wrote about itself (nil when nothing is recorded; the lock is
    /// the truth, the file the label).
    static func running(stateURL: URL) -> (locked: Bool, info: Info?) {
        let info = read(stateURL: stateURL)
        let lockURL = stateURL.appendingPathComponent(lockFileName)
        let fd = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return (false, info) }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return (false, info)
        }
        return (errno == EWOULDBLOCK, info)
    }

    static func read(stateURL: URL) -> Info? {
        guard let data = try? Data(contentsOf: stateURL.appendingPathComponent(infoFileName)) else { return nil }
        return try? decoder.decode(Info.self, from: data)
    }

    private static func write(_ info: Info) {
        guard let stateURL = heldStateURL, let data = try? encoder.encode(info) else { return }
        try? data.write(to: stateURL.appendingPathComponent(infoFileName), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Which build this is

    /// The build's name: `BromureBuildName` in Info.plist (scripts/devbuild.sh
    /// stamps it), else the folder the bundle sits in under
    /// `…-builds/<name>/`, else "dev" for a bundle run from a checkout.
    static var buildName: String {
        if let n = Bundle.main.object(forInfoDictionaryKey: "BromureBuildName") as? String, !n.isEmpty {
            return n
        }
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == ACSupportDir.buildsRoot.lastPathComponent {
            return parent.lastPathComponent
        }
        return "dev"
    }
    static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    static var bundleCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "BromureCommit") as? String
    }
}
