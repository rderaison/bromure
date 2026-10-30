import Foundation

/// The app's data folder — its *state*: profiles, VM disks, settings,
/// secrets, traces — and where it lives.
///
/// `name` is the folder under ~/Library/Application Support (and under
/// ~/Library/Logs): "BromureAC", unless the bundle's Info.plist names another
/// with `BromureSupportDirName`. That folder is the **default state**: the one
/// a Dock or Finder launch opens with no environment.
///
/// A build signed by a different team gets a different Data Protection
/// Keychain master key (`SecretsVault`), so it can't decrypt anything the
/// release build encrypted — its logins, workspace secrets and model keys —
/// and the release can't read what it writes. Giving such a build its own
/// folder keeps the two from locking each other out. The `bromure-ac` CLI
/// inside the bundle reads the same Info.plist, so it reaches the same
/// instance's control socket.
///
/// A state can also be chosen **at launch** (BUILD_INSTRUCTIONS.md, "States"), so
/// one build can run on another data set and several instances can run side
/// by side, each on its own state:
///
///   BROMURE_STATE_DIR=/abs/path   that directory is the state
///   BROMURE_STATE=<name>          `<name>` under `…/Application Support/<name>-states/`
///                                 ("work", or the default folder's own name, is
///                                 the default state)
///
/// The CLI's `--state <name|path>` sets one of these before anything reads
/// them. `url` is the state directory every data path hangs off; the ~50
/// sites that used to rebuild `applicationSupportDirectory/<name>` go through
/// it. Logs follow the state: `<state>/logs/` for a state chosen at launch,
/// `~/Library/Logs/<name>` for the default one, as always.
///
/// Bromure Sidecar shares this file (Sources/AgentHost/Shared) to find the
/// Bromure AC on this Mac it attaches to. Its own folder stays
/// BromureSidecar, so it reads a key that says whose folder this is:
/// `BromureACSupportDirName`. It attaches to the default state only.
enum ACSupportDir {
    static let defaultName = "BromureAC"
    /// The name every tool calls the default state by.
    static let defaultStateName = "work"

    #if AGENT_HOST
    static let infoPlistKey = "BromureACSupportDirName"
    #else
    static let infoPlistKey = "BromureSupportDirName"
    #endif

    /// The default state's folder name (Info.plist, else "BromureAC").
    static let name: String = resolve(
        Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)

    /// A symlink to the binary outside its bundle (`~/.local/bin/bromure-ac`,
    /// `/usr/local/bin/bromure-cli`) has no Info.plist around it: `Bundle.main`
    /// is found by walking up from the executable path *as invoked*, so this
    /// folder's name, the bundle identifier the settings live under and the
    /// build name would all read as missing, and the CLI would talk to the
    /// wrong data. Run the real binary instead, with the same arguments
    /// (argv[0] included, so `bromure-cli` stays `bromure-cli`) and
    /// environment. A symlinked *directory* on the way (`…-builds/stable/`)
    /// is fine: the bundle is still around the executable. First thing in
    /// `main()`; a no-op for the app itself.
    static func reexecIfInvokedThroughSymlink() {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return }
        let invoked = String(cString: buf)
        let real = URL(fileURLWithPath: invoked).resolvingSymlinksInPath().path
        guard real != invoked, Bundle.main.bundleURL.pathExtension != "app",
              FileManager.default.isExecutableFile(atPath: real) else { return }
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(real, &argv)   // returns only on failure: carry on as invoked
    }

    /// A single path component, or the default: never a path that escapes
    /// Application Support.
    static func resolve(_ configured: String?) -> String {
        guard let s = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s != ".", s != "..", !s.contains("/"), !s.contains(":")
        else { return defaultName }
        return s
    }

    #if !AGENT_HOST
    /// Where a state lives and how it was chosen.
    struct State: Equatable {
        /// "work" for the default state, else the state's name (the
        /// directory's last path component for one given by path).
        let stateName: String
        /// The state directory.
        let url: URL
        /// True for the default state: the Info.plist folder, reachable with
        /// no environment.
        let isDefault: Bool
        /// How the state was chosen, for `instance.json` and the log.
        let source: Source

        enum Source: String { case infoPlist, environmentName, environmentPath }

        /// Where this state's logs go.
        var logsURL: URL {
            isDefault
                ? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/\(url.lastPathComponent)", isDirectory: true)
                : url.appendingPathComponent("logs", isDirectory: true)
        }
    }

    /// The state this process runs on. Resolved once, on first use — after
    /// the CLI's `--state` pre-scan has set the environment.
    static let state: State = resolveState(
        environment: liveEnvironment(["BROMURE_STATE_DIR", "BROMURE_STATE"]),
        defaultFolderName: name,
        applicationSupport: applicationSupportDirectory)

    /// `getenv` at the time of the call: `ProcessInfo.environment` may be a
    /// snapshot from before `applyStateArgument`'s `setenv`.
    private static func liveEnvironment(_ keys: [String]) -> [String: String] {
        var env: [String: String] = [:]
        for k in keys { if let v = getenv(k) { env[k] = String(cString: v) } }
        return env
    }

    /// The state directory. Every data path hangs off it.
    static var url: URL { state.url }
    /// "work", or the state's name.
    static var stateName: String { state.stateName }
    /// True when this process runs on the default state.
    static var isDefault: Bool { state.isDefault }
    /// This state's log directory.
    static var logsURL: URL { state.logsURL }

    /// `~/Library/Application Support/<name>-states/`: the named states that
    /// aren't the default one.
    static var statesRoot: URL {
        applicationSupportDirectory.appendingPathComponent("\(name)-states", isDirectory: true)
    }
    /// `~/Library/Application Support/<name>-builds/`: immutable app bundles,
    /// one folder per build, `stable` a symlink to the one the default state
    /// runs on.
    static var buildsRoot: URL {
        applicationSupportDirectory.appendingPathComponent("\(name)-builds", isDirectory: true)
    }
    /// The default state's directory, whatever this process runs on.
    static var defaultStateURL: URL {
        applicationSupportDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// The directory of a state named on a command line: "work" (or the
    /// default folder's name) is the default state, anything else a folder
    /// under `statesRoot`. Nil for a name that isn't a single path component.
    static func stateURL(named raw: String) -> URL? {
        guard let n = validStateName(raw) else { return nil }
        if n == defaultStateName || n == name { return defaultStateURL }
        return statesRoot.appendingPathComponent(n, isDirectory: true)
    }

    /// A state name: one path component, no leading dot (".snapshots" is
    /// ours), no ":" (a Finder "/").
    static func validStateName(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != ".", s != "..", !s.hasPrefix("."),
              !s.contains("/"), !s.contains(":") else { return nil }
        return s
    }

    /// Resolution order: BROMURE_STATE_DIR → BROMURE_STATE → the default
    /// folder. Pure, for the tests.
    static func resolveState(environment: [String: String], defaultFolderName: String,
                             applicationSupport: URL) -> State {
        let defaultURL = applicationSupport.appendingPathComponent(defaultFolderName, isDirectory: true)
        let statesRoot = applicationSupport.appendingPathComponent("\(defaultFolderName)-states", isDirectory: true)
        if let raw = environment["BROMURE_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            if url.path == defaultURL.standardizedFileURL.path {
                return State(stateName: defaultStateName, url: defaultURL, isDefault: true, source: .environmentPath)
            }
            return State(stateName: url.lastPathComponent, url: url, isDefault: false, source: .environmentPath)
        }
        if let raw = environment["BROMURE_STATE"], let n = validStateName(raw) {
            if n == defaultStateName || n == defaultFolderName {
                return State(stateName: defaultStateName, url: defaultURL, isDefault: true, source: .environmentName)
            }
            return State(stateName: n, url: statesRoot.appendingPathComponent(n, isDirectory: true),
                         isDefault: false, source: .environmentName)
        }
        return State(stateName: defaultStateName, url: defaultURL, isDefault: true, source: .infoPlist)
    }

    /// A window title with the state's name when it isn't the default one
    /// ("Bromure Agentic Coding · repro-42"): Mission Control, the Dock
    /// menu and the window switcher then say which instance this is.
    static func badged(_ title: String) -> String {
        isDefault ? title : "\(title) · \(stateName)"
    }

    /// The CLI's `--state <name|path>` (or `--state=…`), taken out of the
    /// arguments before ArgumentParser sees them and turned into the
    /// environment the app, its CLI verbs and the agent they autostart all
    /// read. A value with a "/" is a path; anything else a name. Returns the
    /// remaining arguments, or nil with a message when the value is unusable.
    struct ArgumentFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func applyStateArgument(_ args: [String]) -> Result<[String], ArgumentFailure> {
        var rest: [String] = []
        var value: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--state" {
                guard i + 1 < args.count else {
                    return .failure(ArgumentFailure(description: "--state needs a value: a state name or a directory"))
                }
                value = args[i + 1]; i += 2; continue
            }
            if a.hasPrefix("--state=") { value = String(a.dropFirst("--state=".count)); i += 1; continue }
            rest.append(a); i += 1
        }
        guard let value else { return .success(args) }
        if value.contains("/") || value.hasPrefix("~") {
            setenv("BROMURE_STATE_DIR", (value as NSString).expandingTildeInPath, 1)
            unsetenv("BROMURE_STATE")
        } else {
            guard validStateName(value) != nil else {
                return .failure(ArgumentFailure(description: "--state: '\(value)' isn't a state name"))
            }
            setenv("BROMURE_STATE", value, 1)
            unsetenv("BROMURE_STATE_DIR")
        }
        return .success(rest)
    }
    #endif
}

/// The app's settings, per state.
///
/// `UserDefaults.standard` is per bundle ID: two instances of one build on two
/// states would share the automation port, the remote-access port and, above
/// all, the persisted VM subnet (`vmnet.switch.subnetBase172`), and so could
/// not run at once. `ACDefaults.standard` is the store every setting goes
/// through instead: `.standard` for the default state (nothing changes for
/// an install that never chose a state), a suite named after the bundle and
/// the state (`<bundle id>.state.<name>`, so `defaults read` finds it) for
/// any other. `@AppStorage` takes it as `store:`. A unit test keeps
/// `UserDefaults.standard` out of Sources/AgentCoding.
///
/// Settings that describe the Mac rather than a state — the VM MTU, display
/// scale, key repeat — stay in SandboxEngine's `.standard` reads, shared by
/// every state on purpose.
enum ACDefaults {
    #if AGENT_HOST
    static let standard: UserDefaults = .standard
    static let suiteName: String? = nil
    #else
    static let standard: UserDefaults = {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    /// The suite this state's settings live in; nil for the default state
    /// (the bundle's own domain).
    static let suiteName: String? = ACSupportDir.isDefault ? nil : suiteName(forState: ACSupportDir.stateName)

    /// The settings domain of a state: the bundle's own for the default
    /// state, `<bundle id>.state.<name>` for another.
    static func suiteName(forState name: String) -> String? {
        name == ACSupportDir.defaultStateName ? nil : "\(bundleDomain).state.\(name)"
    }

    /// The default state's settings domain (`defaults read <this>`).
    static var bundleDomain: String {
        Bundle.main.bundleIdentifier ?? "io.bromure.agentic-coding"
    }
    #endif
}
