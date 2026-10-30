import Foundation
import Testing
@testable import bromure_ac

@Suite("Support directory name")
struct SupportDirectoryTests {
    @Test("No Info.plist key means the release folder")
    func defaultName() {
        #expect(ACSupportDir.resolve(nil) == "BromureAC")
        // The test runner's bundle has no BromureSupportDirName.
        #expect(ACSupportDir.name == "BromureAC")
    }

    @Test("bromure-ac reads its own folder's key (the Sidecar reads BromureACSupportDirName)")
    func infoPlistKey() {
        #expect(ACSupportDir.infoPlistKey == "BromureSupportDirName")
    }

    @Test("A configured name is used, trimmed")
    func configured() {
        #expect(ACSupportDir.resolve("BromureACDev") == "BromureACDev")
        #expect(ACSupportDir.resolve("  BromureACDev\n") == "BromureACDev")
    }

    @Test("A name that isn't one path component falls back to the release folder")
    func rejected() {
        for bad in ["", "   ", ".", "..", "../Elsewhere", "a/b", "/tmp", "a:b"] {
            #expect(ACSupportDir.resolve(bad) == "BromureAC", "\(bad)")
        }
    }
}

@Suite("State chosen at launch")
struct StateResolutionTests {
    let support = URL(fileURLWithPath: "/Users/t/Library/Application Support", isDirectory: true)

    func resolve(_ env: [String: String], folder: String = "BromureACDev") -> ACSupportDir.State {
        ACSupportDir.resolveState(environment: env, defaultFolderName: folder, applicationSupport: support)
    }

    @Test("No environment: the Info.plist folder is the default state, 'work'")
    func noEnvironment() {
        let s = resolve([:])
        #expect(s.isDefault)
        #expect(s.stateName == "work")
        #expect(s.url.path == "/Users/t/Library/Application Support/BromureACDev")
        #expect(s.source == .infoPlist)
        #expect(s.logsURL.path.hasSuffix("Library/Logs/BromureACDev"))
    }

    @Test("BROMURE_STATE names a folder under <default>-states")
    func namedState() {
        let s = resolve(["BROMURE_STATE": "repro-42"])
        #expect(!s.isDefault)
        #expect(s.stateName == "repro-42")
        #expect(s.url.path == "/Users/t/Library/Application Support/BromureACDev-states/repro-42")
        #expect(s.source == .environmentName)
        // Logs live inside the state.
        #expect(s.logsURL.path == "/Users/t/Library/Application Support/BromureACDev-states/repro-42/logs")
    }

    @Test("'work' and the folder's own name are the default state")
    func workAliases() {
        for n in ["work", "BromureACDev"] {
            let s = resolve(["BROMURE_STATE": n])
            #expect(s.isDefault, "\(n)")
            #expect(s.stateName == "work", "\(n)")
            #expect(s.url.path == "/Users/t/Library/Application Support/BromureACDev", "\(n)")
        }
    }

    @Test("BROMURE_STATE_DIR is the state directory itself, and wins over BROMURE_STATE")
    func pathState() {
        let s = resolve(["BROMURE_STATE_DIR": "/tmp/brm-x/", "BROMURE_STATE": "other"])
        #expect(!s.isDefault)
        #expect(s.stateName == "brm-x")
        #expect(s.url.path == "/tmp/brm-x")
        #expect(s.source == .environmentPath)
        #expect(s.logsURL.path == "/tmp/brm-x/logs")
    }

    @Test("A path that is the default folder is the default state")
    func pathToDefault() {
        let s = resolve(["BROMURE_STATE_DIR": "/Users/t/Library/Application Support/BromureACDev"])
        #expect(s.isDefault)
        #expect(s.stateName == "work")
    }

    @Test("A bad name is ignored, not honoured")
    func badName() {
        for bad in ["", "a/b", "..", ".snapshots", "a:b"] {
            let s = resolve(["BROMURE_STATE": bad])
            #expect(s.isDefault, "\(bad)")
        }
    }

    @Test("State names: one component, not hidden")
    func validNames() {
        #expect(ACSupportDir.validStateName("repro-42") == "repro-42")
        #expect(ACSupportDir.validStateName(" work ") == "work")
        #expect(ACSupportDir.validStateName(".snapshots") == nil)
        #expect(ACSupportDir.validStateName("a/b") == nil)
        #expect(ACSupportDir.validStateName("") == nil)
    }

    @Test("--state is taken out of the arguments and put in the environment")
    func stateArgument() throws {
        defer { unsetenv("BROMURE_STATE"); unsetenv("BROMURE_STATE_DIR") }
        unsetenv("BROMURE_STATE"); unsetenv("BROMURE_STATE_DIR")

        var r = ACSupportDir.applyStateArgument(["vm", "ls"])
        #expect(try r.get() == ["vm", "ls"])
        #expect(getenv("BROMURE_STATE") == nil)

        r = ACSupportDir.applyStateArgument(["--state", "repro-1", "vm", "ls"])
        #expect(try r.get() == ["vm", "ls"])
        #expect(String(cString: getenv("BROMURE_STATE")) == "repro-1")
        #expect(getenv("BROMURE_STATE_DIR") == nil)

        r = ACSupportDir.applyStateArgument(["vm", "--state=/tmp/s1", "ls"])
        #expect(try r.get() == ["vm", "ls"])
        #expect(String(cString: getenv("BROMURE_STATE_DIR")) == "/tmp/s1")
        #expect(getenv("BROMURE_STATE") == nil)   // the path replaces the name

        if case .success = ACSupportDir.applyStateArgument(["--state"]) { Issue.record("missing value accepted") }
        if case .success = ACSupportDir.applyStateArgument(["--state", "a:b"]) { Issue.record("bad name accepted") }
    }
}

@Suite("Instance lock")
struct InstanceLockTests {
    @Test("A state's lock and the record of its holder")
    func lockAndRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brm-instance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ACInstance.running(stateURL: dir).locked == false)
        try ACInstance.acquire(mode: .headless, stateURL: dir)
        #expect(ACInstance.isHolder)
        // Taking it again in the same process is a no-op.
        try ACInstance.acquire(mode: .headless, stateURL: dir)

        let info = try #require(ACInstance.read(stateURL: dir))
        #expect(info.pid == getpid())
        #expect(info.mode == "headless")
        #expect(info.statePath == dir.path)
        #expect(info.automationPort == nil)
        ACInstance.recordAutomationPort(49152)
        #expect(ACInstance.read(stateURL: dir)?.automationPort == 49152)

        // Another process would see it held. (flock locks are per open file
        // description, so this process's own probe shares them: check the
        // lock through a child instead.)
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", "python3 -c 'import fcntl,sys; f=open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_SH|fcntl.LOCK_NB)' \"$1\"",
                           "_", dir.appendingPathComponent(ACInstance.lockFileName).path]
        try probe.run(); probe.waitUntilExit()
        #expect(probe.terminationStatus != 0, "a second process could take the lock")

        ACInstance.release()
        #expect(!ACInstance.isHolder)
        #expect(ACInstance.read(stateURL: dir) == nil)
        let again = Process()
        again.executableURL = probe.executableURL
        again.arguments = probe.arguments
        try again.run(); again.waitUntilExit()
        #expect(again.terminationStatus == 0, "the lock outlived release()")
    }

    @Test("The build name comes from the bundle's folder under …-builds, else 'dev'")
    func buildName() {
        // The test runner isn't under a builds folder.
        #expect(ACInstance.buildName == "dev")
    }
}
