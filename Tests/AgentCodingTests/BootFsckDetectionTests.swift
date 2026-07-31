import Testing
@testable import bromure_ac

// Serial-console fsck-failure detection (UbuntuSandboxVM.fsBootFailureMatch):
// the lines an Ubuntu boot prints when the root fs fails its check and the
// headless guest drops to an emergency shell nobody can type at.
@Suite("Boot fsck-failure detection")
struct BootFsckDetectionTests {

    @Test("real-world failure lines match")
    func matches() {
        let lines = [
            "/dev/vda2: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.",
            "        (i.e., without -a or -p options)",   // continuation — no match expected here
            "[FAILED] Failed to start systemd-fsck-root.service - File System Check on Root Device.",
            "systemd-fsck[312]: fsck failed with exit status 4.",
            "You are in emergency mode. After logging in, type \"journalctl -xb\" to view",
            "Give root password for maintenance",
            "(or press Control-D to continue): Cannot open access to console, the root account is locked.",
            "Failed to check file system on /dev/vda2",
        ]
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[0]) != nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[1]) == nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[3]) != nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[4]) != nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[5]) != nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[6]) != nil)
        #expect(UbuntuSandboxVM.fsBootFailureMatch(in: lines[7]) != nil)
    }

    @Test("healthy boot chatter does not match")
    func healthyBootIsQuiet() {
        let lines = [
            "[  OK  ] Finished systemd-fsck-root.service - File System Check on Root Device.",
            "systemd-fsck[298]: bromure-root: clean, 214041/1281120 files, 3204410/5242880 blocks",
            "EXT4-fs (vda2): mounted filesystem with ordered data mode. Quota mode: none.",
            "Ubuntu 24.04.2 LTS bromure ttyS0",
            "cloud-init[512]: Cloud-init v. 24.1 running 'modules:final'",
            "bromure login: ",
        ]
        for line in lines {
            #expect(UbuntuSandboxVM.fsBootFailureMatch(in: line) == nil, "\(line)")
        }
    }

    @Test("matched line is trimmed and capped")
    func trimAndCap() {
        let long = String(repeating: "x", count: 300) + " RUN fsck MANUALLY.  "
        let match = UbuntuSandboxVM.fsBootFailureMatch(in: long)
        #expect(match != nil)
        #expect((match ?? "").count <= 200)
        #expect(match?.hasSuffix("RUN fsck MANUALLY.") == true)
    }
}
