import Foundation
import Testing
@testable import ACLinux

/// The guest agent's systemd unit and launcher exist twice: in the image
/// (setup.sh) and in the agent, which converges a workspace to its copy. A
/// difference would rewrite them on every boot, or boot new images with a
/// unit the agent then replaces.
@Suite("Guest agent unit and launcher")
struct AgentdUnitTests {
    static let vmSetup = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup").path

    static func agentdConstant(_ name: String) throws -> String {
        let src = try String(contentsOfFile: vmSetup + "/bromure-agentd.py", encoding: .utf8)
        let open = "\(name) = r\"\"\""
        let start = try #require(src.range(of: open)).upperBound
        let end = try #require(src.range(of: "\"\"\"", range: start..<src.endIndex)).lowerBound
        return String(src[start..<end])
    }

    static func heredoc(after line: String, tag: String) throws -> String {
        let src = try String(contentsOfFile: vmSetup + "/setup.sh", encoding: .utf8)
        let start = try #require(src.range(of: line + " <<'\(tag)'\n")).upperBound
        let end = try #require(src.range(of: "\n\(tag)\n", range: start..<src.endIndex)).lowerBound
        return String(src[start..<end]) + "\n"
    }

    @Test func theImageAndTheAgentCarryTheSameUnit() throws {
        let unit = try Self.agentdConstant("_UNIT_CONTENT")
        #expect(try Self.heredoc(after: "cat > /etc/systemd/system/bromure-agentd.service", tag: "EOU") == unit)
        // Started early, stopped at shutdown, through the launcher.
        #expect(unit.contains("DefaultDependencies=no\n") && unit.contains("Conflicts=shutdown.target\n"))
        #expect(unit.contains("ExecStart=/usr/bin/python3 -s /usr/local/lib/bromure/agentd-launch.py\n"))
        #expect(unit.contains("ConditionPathExists=/mnt/bromure-meta/bromure-agentd.py\n"))
    }

    @Test func theImageAndTheAgentCarryTheSameLauncher() throws {
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
        #expect(try Self.heredoc(after: "cat > /usr/local/lib/bromure/agentd-launch.py", tag: "EOP") == launcher)
    }

    /// The image's prepared cache (prepare_image, at install) is the
    /// launcher's: the same key and the same compile, or every new
    /// workspace's first boot would miss it.
    @Test func thePreparedBytecodeUsesTheLaunchersKey() throws {
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
        let src = try String(contentsOfFile: Self.vmSetup + "/bromure-agentd.py", encoding: .utf8)
        let start = try #require(src.range(of: "def prepare_image():")).lowerBound
        let prepare = String(src[start...].prefix(6000))
        let key = "key = (hashlib.sha256(src).hexdigest() + \" \" + sys.version).encode()"
        #expect(launcher.contains(key) && prepare.contains(key))
        #expect(launcher.contains("P = \"/mnt/bromure-meta/bromure-agentd.py\"") && launcher.contains("compile(src, P, \"exec\")"))
        #expect(prepare.contains("compile(src, \"/mnt/bromure-meta/bromure-agentd.py\", \"exec\")"))
        #expect(launcher.contains("CACHE = \"/var/cache/bromure-agentd/agentd.bin\"") && prepare.contains("\"agentd.bin\""))
        // postinstall.sh runs it after the catalog steps.
        let post = try String(contentsOfFile: Self.vmSetup + "/postinstall.sh", encoding: .utf8)
        #expect(post.contains("bromure-agentd.py --prepare-image"))
    }

    /// The launcher runs a script as `python3 script` would: as __main__,
    /// with its own __file__; from the cache the second time.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func theLauncherRunsTheAgentAndCachesItsBytecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/cache", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/agent.py"
        try "import sys\nprint(__name__, __file__ == sys.argv[0], __file__.endswith('agent.py'))\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
            .replacingOccurrences(of: "/mnt/bromure-meta/bromure-agentd.py", with: script)
            .replacingOccurrences(of: "/var/cache/bromure-agentd/agentd.bin", with: dir + "/cache/agentd.bin")
        try launcher.write(toFile: dir + "/launch.py", atomically: true, encoding: .utf8)
        func run() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-s", dir + "/launch.py"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run() == "__main__ True True\n", "compiled")
        #expect(FileManager.default.fileExists(atPath: dir + "/cache/agentd.bin"), "and cached")
        #expect(try run() == "__main__ True True\n", "from the cache")
        try "print('changed')\n".write(toFile: script, atomically: true, encoding: .utf8)
        #expect(try run() == "changed\n", "a new source is compiled, not the cached one run")
    }

    // MARK: the early start (boot gate, early root setup, meta mount)

    @Test func theImageAndTheAgentCarryTheSameBootUnits() throws {
        for (name, line, tag) in [
            ("_MODULES_LOAD_CONTENT", "cat > /etc/modules-load.d/bromure.conf", "EOL"),
            ("_EARLY_ROOT_CONTENT", "cat > /usr/local/lib/bromure/early-root.sh", "EOE"),
            ("_EARLY_UNIT_CONTENT", "cat > /etc/systemd/system/bromure-early.service", "EOY"),
            ("_GATE_UNIT_CONTENT", "cat > /etc/systemd/system/bromure-boot-gate.service", "EOG"),
            ("_META_MOUNT_UNIT_CONTENT", "cat > '/etc/systemd/system/mnt-bromure\\x2dmeta.mount'", "EOM"),
        ] {
            #expect(try Self.heredoc(after: line, tag: tag) == Self.agentdConstant(name), "\(name)")
        }
    }

    /// The agent starts as soon as its share is mounted and waits for the
    /// gate itself; the gate comes after what the old ordering gave it.
    @Test func theAgentStartsFromTheMetaShareBehindTheBootGate() throws {
        let unit = try Self.agentdConstant("_UNIT_CONTENT")
        #expect(unit.contains("Wants=bromure-boot-gate.service bromure-early.service\n"))
        #expect(unit.contains("After=mnt-bromure\\x2dmeta.mount systemd-journald.socket\n"))
        #expect(unit.contains("Environment=BROMURE_AGENTD_EARLY=1\n") && unit.contains("Nice=-15\n"))
        let gate = try Self.agentdConstant("_GATE_UNIT_CONTENT")
        #expect(gate.contains("After=local-fs.target systemd-tmpfiles-setup.service bromure-early.service\n"))
        #expect(gate.contains("ExecStart=/usr/bin/touch /run/bromure-boot-gate\n"))
        let early = try Self.agentdConstant("_EARLY_UNIT_CONTENT")
        #expect(early.contains("After=mnt-bromure\\x2dmeta.mount\n") && early.contains("Before=bromure-boot-gate.service shutdown.target\n"))
        let mount = try Self.agentdConstant("_META_MOUNT_UNIT_CONTENT")
        #expect(mount.contains("DefaultDependencies=no\n") && mount.contains("What=bromure-meta\nWhere=/mnt/bromure-meta\nType=virtiofs\nOptions=ro\n"))
        #expect(try Self.agentdConstant("_MODULES_LOAD_CONTENT").contains("\nvmw_vsock_virtio_transport\n"))
    }

    /// Root's early script mounts the home only in the plain case, after
    /// every check, and never formats, repairs or resizes: those stay the
    /// agent's.
    @Test func theEarlyRootScriptOnlyMountsACleanLabelledHome() throws {
        let script = try Self.agentdConstant("_EARLY_ROOT_CONTENT")
        let mount = try #require(script.range(of: "mount -o noatime")).lowerBound
        for guard_ in ["[ \"$mode\" = ext4 ] || exit 0", "virtiofs-tags/bromure-home\" ] || exit 0",
                       "LABEL=bromure-home$NL\"*) ;; *) continue ;;", "TYPE=ext4$NL\"*) ;; *) exit 0 ;;",
                       "FS_STATE=clean$NL\"*) ;; *) exit 0 ;;", "*needs_recovery*) exit 0 ;;"] {
            let at = try #require(script.range(of: guard_), "\(guard_)").lowerBound
            #expect(at < mount, "\(guard_) comes before the mount")
        }
        for never in ["mkfs", "e2fsck", "resize2fs", "wipefs", " dd "] { #expect(!script.contains(never), "\(never)") }
    }

    static let python = "/usr/bin/python3"

    /// Runs `body` with the agent loaded as module `m`; its stdout.
    static func agentd(_ body: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        // -B: no __pycache__ left beside the agent (a bundled resource).
        p.arguments = ["-I", "-B", "-c", """
            import importlib.util, os, sys, tempfile
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m.log = lambda *a, **k: None

            """ + body, vmSetup + "/bromure-agentd.py"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? text : text + "\nFAILED: " + errors
    }

    /// The home is formatted only on a positive "nothing on this disk":
    /// never because a probe failed or said nothing.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func onlyADiskProbedEmptyIsABlankHome() throws {
        #expect(try Self.agentd("""
            assert m._blockdev_is_blank({"BLKID_RC": "2", "DEV_BYTES": "1024"})
            for info in (None, {}, {"DEV_BYTES": "1024"}, {"BLKID_RC": "0", "TYPE": "ext4"},
                         {"BLKID_RC": "2", "TYPE": "ext4"}, {"BLKID_RC": "1"}, {"BLKID_RC": ""}):
                assert not m._blockdev_is_blank(info), info
            home = {"BLKID_RC": "0", "TYPE": "ext4", "LABEL": "bromure-home"}
            def find(probes):
                m._candidate_home_disks = lambda: sorted(probes)
                m._probe_blockdev = lambda d: probes[d]
                return m._find_home_device()
            # The labelled home wins over a blank disk before it.
            assert find({"/dev/vdb": {"BLKID_RC": "2"}, "/dev/vdc": home}) == ("/dev/vdc", home)
            # A first boot: the blank disk.
            assert find({"/dev/vdb": None, "/dev/vdc": {"BLKID_RC": "2"}})[0] == "/dev/vdc"
            # A disk that couldn't be probed, or holds something else: no home, nothing to format.
            assert find({"/dev/vdb": None}) == ("", None)
            assert find({"/dev/vdb": {"BLKID_RC": "0", "TYPE": "xfs"}}) == ("", None)
            assert find({"/dev/vdb": {"BLKID_RC": "0", "TYPE": "ext4", "LABEL": "data"}}) == ("", None)
            print("ok")
            """) == "ok\n")
    }

    /// A check of the home only when its superblock asks for one.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func aCleanHomeIsNotChecked() throws {
        #expect(try Self.agentd("""
            ran = []
            m._device_mounted = lambda d: False
            m._have_sudo = lambda: True
            class R: returncode = 0; stdout = ""; stderr = ""
            m.subprocess.run = lambda a, **k: (ran.append(a), R())[1]
            m._fsck_home_if_needed("/dev/vdb", {"FS_STATE": "clean", "FS_FEATURES": "has_journal extent"})
            assert ran == [], ran
            m._fsck_home_if_needed("/dev/vdb", {"FS_STATE": "clean", "FS_FEATURES": "has_journal needs_recovery"})
            m._fsck_home_if_needed("/dev/vdb", {"FS_STATE": "not clean", "FS_FEATURES": "has_journal"})
            m._fsck_home_if_needed("/dev/vdb", {})
            assert ran == [["sudo", "e2fsck", "-y", "/dev/vdb"]] * 3, ran
            m._device_mounted = lambda d: True
            m._fsck_home_if_needed("/dev/vdb", {})
            assert len(ran) == 3, "never a mounted device"
            print("ok")
            """) == "ok\n")
    }

    /// The first command waits for the shares and the network, bounded.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func theFirstCommandWaitsForTheSharesAndTheNetwork() throws {
        #expect(try Self.agentd("""
            import time
            assert m._wait_for("x", lambda: True, 1.0)
            t0 = time.monotonic()
            assert not m._wait_for("x", lambda: False, 0.05)
            assert 0.05 <= time.monotonic() - t0 < 1.0
            calls = {"shares": 0, "ip": 0, "route": 0, "dns": 0}
            def after(key, n):
                def f(*a):
                    calls[key] += 1
                    return calls[key] > n
                return f
            m._shares_mounted = after("shares", 3)
            m._primary_nic = lambda: "eth9"
            ip = after("ip", 4)
            m._nic_ipv4 = lambda nic: "10.0.0.2" if ip() else ""
            m._has_default_route = after("route", 2)
            m._dns_ready = after("dns", 2)
            m._wait_first_command_gates()
            assert calls["shares"] == 4 and calls["ip"] >= 5 and calls["route"] >= 3 and calls["dns"] == 3, calls
            # The boot gate: only under the early-start unit, and only once.
            gate = os.path.join(tempfile.mkdtemp(), "gate")
            m._BOOT_GATE = gate
            waits = []
            real = m._wait_for
            m._wait_for = lambda what, ready, timeout, step=0.002: (waits.append(ready()), True)[1]
            os.environ.pop("BROMURE_AGENTD_EARLY", None)
            m._wait_boot_gate()
            assert waits == []
            os.environ["BROMURE_AGENTD_EARLY"] = "1"
            m._wait_boot_gate()
            open(gate, "w").close()
            m._wait_boot_gate()
            assert waits == [False] and "BROMURE_AGENTD_EARLY" not in os.environ, waits
            print("ok")
            """) == "ok\n")
    }

    /// /boot/efi mounted on first access (not at boot, where its check held
    /// the disk), binfmt_misc at boot (not on first access, where its
    /// automount held networkd and resolved).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func efiIsMountedOnFirstAccessAndBinfmtAtBoot() throws {
        #expect(try Self.agentd("""
            f = "LABEL=root\\t/\\text4\\tdefaults\\t0\\t1\\nLABEL=EFI      /boot/efi       vfat     umask=0077 0  2\\n# /boot/efi comment\\n"
            got = m._fstab_efi_lazy(f)
            assert got.split("\\n")[1].split() == ["LABEL=EFI", "/boot/efi", "vfat", "umask=0077,nofail,x-systemd.automount", "0", "2"], got
            assert got.split("\\n")[0] == f.split("\\n")[0] and got.split("\\n")[2:] == f.split("\\n")[2:]
            assert m._fstab_efi_lazy(got) is None, "already so"
            half = f.replace("umask=0077", "umask=0077,nofail")
            assert "umask=0077,nofail,x-systemd.automount" in m._fstab_efi_lazy(half)
            assert m._fstab_efi_lazy("LABEL=root / ext4 defaults 0 1\\n") is None

            d = tempfile.mkdtemp()
            unit = os.path.join(d, "proc-sys-fs-binfmt_misc.mount")
            m._BINFMT_MOUNT_UNITS = (os.path.join(d, "none.mount"), unit)
            m._BINFMT_MOUNT_WANT = os.path.join(d, "wants", "proc-sys-fs-binfmt_misc.mount")
            assert m._binfmt_mount_unit() is None, "a system without the unit"
            open(unit, "w").close()
            assert m._binfmt_mount_unit() == unit
            os.mkdir(os.path.join(d, "wants")); os.symlink(unit, m._BINFMT_MOUNT_WANT)
            assert m._binfmt_mount_unit() is None, "enabled already"
            print("ok")
            """) == "ok\n")
        let setup = try String(contentsOfFile: Self.vmSetup + "/setup.sh", encoding: .utf8)
        #expect(setup.contains("LABEL=EFI      /boot/efi       vfat     umask=0077,nofail,x-systemd.automount 0  2\n"))
        #expect(setup.contains("\nsystemctl enable proc-sys-fs-binfmt_misc.mount >/dev/null 2>&1 || true\n"))
    }

    /// dockerd starts on first use (its socket) or, after the shell, when a
    /// container has a restart policy: not at every boot.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func dockerStartsOnDemand() throws {
        let setup = try String(contentsOfFile: Self.vmSetup + "/setup.sh", encoding: .utf8)
        #expect(setup.contains("\nsystemctl disable docker.service containerd.service >/dev/null 2>&1 || true\nsystemctl enable docker.socket >/dev/null 2>&1 || true\n"))
        #expect(try Self.agentd("""
            ran = []
            class R:
                returncode = 0
                def __init__(self, out=""): self.stdout = out; self.stderr = ""
            policy = [""]
            m.subprocess.run = lambda a, **k: (ran.append(a), R(policy[0]))[1]
            m._have_sudo = lambda: True
            m.shutil.which = lambda n: "/usr/bin/" + n
            m._docker_running = lambda: True
            m.task_docker_autostart()
            assert ran == [], "already running"
            m._docker_running = lambda: False
            m.task_docker_autostart()
            assert len(ran) == 1 and ran[0][:3] == ["sudo", "sh", "-c"] and "RestartPolicy" in ran[0][3], ran
            policy[0] = "/var/lib/docker/containers/abc/hostconfig.json\\n"
            m.task_docker_autostart()
            assert ran[-1] == ["sudo", "systemctl", "start", "--no-block", "docker"], ran
            # Converging an older system disk: only when a boot-time want is there.
            del ran[:]
            m._DOCKER_BOOT_WANTS = (os.path.join(tempfile.mkdtemp(), "docker.service"),)
            m.task_docker_on_demand()
            assert ran == []
            open(m._DOCKER_BOOT_WANTS[0], "w").close()
            m.task_docker_on_demand()
            assert len(ran) == 1 and "systemctl disable docker.service containerd.service" in ran[0][3] and "systemctl enable docker.socket" in ran[0][3], ran
            print("ok")
            """) == "ok\n")
    }
}
