import Foundation
import Testing

/// Finding (CWE-88): "Approved apt names can remove packages or regex-install
/// many of them as root". sandboxd handed apt-get any token of package-name
/// shape, but apt reads a name that isn't exactly a package as something else:
/// `python3-` removes python3 and its reverse deps, `a.+` is a regex over the
/// archive. Each name must now be an exact package in apt's cache first.
///
/// Drives bromure-sandboxd's apt_install against a fake apt that behaves like
/// apt 2.8: package lists empty until `apt-get update`, `apt-cache show`
/// falling back to a regex for a name that isn't a package.
@Suite("Sandbox: approved apt names install only exact packages")
struct SandboxAptExactNameTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var runnable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    private static let driver = #"""
        import importlib.machinery, importlib.util, json, os, re, sys, types
        # sandboxd's policy module refuses to load off a Linux arch.
        os.uname = lambda: types.SimpleNamespace(sysname="Linux", nodename="t", release="6.8",
                                                 version="", machine="aarch64")
        path = sys.argv[1]
        sys.path.insert(0, os.path.dirname(path))
        loader = importlib.machinery.SourceFileLoader("sandboxd", path)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sandboxd", loader))
        loader.exec_module(m)
        m.log = lambda *a: None

        ARCHIVE = ["adduser", "apt", "bash", "curl", "g++", "python3", "python3-apt", "systemd"]

        def scenario(packages, lists=False):
            state = {"lists": lists, "calls": []}
            def run(argv):
                state["calls"].append(argv)
                if argv[:2] == ["apt-get", "update"]:
                    state["lists"] = True
                    return 0, "Reading package lists..."
                if argv[0] == "apt-cache":
                    name = argv[-1]
                    known = ARCHIVE if state["lists"] else []
                    try:
                        hits = [name] if name in known else [p for p in known if re.search(name, p)]
                    except re.error:
                        hits = []
                    if not hits:
                        return 100, "E: No packages found"
                    return 0, "\n\n".join("Package: %s\nVersion: 1" % p for p in hits)
                if argv[:2] == ["apt-get", "install"]:
                    return 0, "installed"
                return 1, "unexpected %r" % argv
            code, out = m.apt_install(packages, run=run)
            installs = [c for c in state["calls"] if c[:2] == ["apt-get", "install"]]
            return {"code": code, "out": out, "installs": installs,
                    "updates": sum(1 for c in state["calls"] if c[:2] == ["apt-get", "update"])}

        print(json.dumps({
            "remove": scenario(["python3-"], lists=True),
            "regex": scenario(["curl", "a.+"], lists=True),
            "force": scenario(["g++-"], lists=True),
            "exact": scenario(["g++", "python3=1", "curl/noble"], lists=True),
            "noLists": scenario(["curl"]),
            "option": scenario(["--purge"], lists=True),
        }))
        """#

    private static func drive() throws -> [String: [String: Any]] {
        let sandboxd = root.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-sandboxd")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-I", "-c", driver, sandboxd.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    @Test("a name that is a remove/force modifier or a regex never reaches apt-get install",
          .enabled(if: SandboxAptExactNameTests.runnable))
    func modifiersAndRegexRefused() throws {
        let r = try Self.drive()
        for key in ["remove", "regex", "force", "option"] {
            let s = try #require(r[key])
            #expect(s["code"] as? Int == 2, "\(key): \(s["out"] ?? "")")
            #expect((s["installs"] as? [Any])?.isEmpty == true, "\(key) reached apt-get install")
        }
        #expect((r["remove"]?["out"] as? String)?.contains("python3-") == true)
        #expect((r["regex"]?["out"] as? String)?.contains("a.+") == true)
    }

    @Test("exact names, with a version or release, install; missing lists are refreshed once",
          .enabled(if: SandboxAptExactNameTests.runnable))
    func exactNamesInstall() throws {
        let r = try Self.drive()
        let exact = try #require(r["exact"])
        #expect(exact["code"] as? Int == 0)
        #expect(exact["installs"] as? [[String]] == [["apt-get", "install", "-y", "--no-install-recommends", "--",
                                                      "g++", "python3=1", "curl/noble"]])
        #expect(exact["updates"] as? Int == 0)
        let fresh = try #require(r["noLists"])
        #expect(fresh["code"] as? Int == 0)
        #expect(fresh["updates"] as? Int == 1)
        #expect((fresh["installs"] as? [Any])?.count == 1)
    }
}
