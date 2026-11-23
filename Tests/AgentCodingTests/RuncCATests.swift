import Foundation
import Testing

/// "SSL MITM in the docker containers": a container sees its image's trust
/// store, not the VM's, so TLS through the MITM proxy failed in containers
/// and in `docker build` steps. agentd installs a runc wrapper
/// (/usr/local/sbin/runc, first on containerd's and BuildKit's PATH) whose
/// helper edits each container's OCI spec: a CA bundle mounted at
/// /dev/bromure-ca, the CA variables the image didn't set, an annotation
/// that `docker exec` follows. These run the helper itself against fake
/// bundles.
@Suite("Containers trust the MITM CA (runc wrapper)",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct RuncCATests {
    static let agentd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
    static let ca = "-----BEGIN CERTIFICATE-----\nBROMURECA\n-----END CERTIFICATE-----\n"
    static let imageRoot = "-----BEGIN CERTIFICATE-----\nIMAGEROOT\n-----END CERTIFICATE-----\n"
    static let vmRoot = "-----BEGIN CERTIFICATE-----\nVMROOT\n-----END CERTIFICATE-----\n"

    /// One of agentd's string constants.
    static func constant(_ name: String) throws -> String {
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-I", "-c", """
            import importlib.util, sys
            s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            sys.stdout.write(getattr(m, sys.argv[2]))
            """, agentd.path, name]
        let out = Pipe()
        py.standardOutput = out
        py.standardError = FileHandle.nullDevice
        try py.run(); py.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    struct Box {
        let dir: URL
        var bundle: URL { dir.appendingPathComponent("bundle") }
        var rootfs: URL { bundle.appendingPathComponent("rootfs") }
        var config: URL { bundle.appendingPathComponent("config.json") }
        var log: URL { dir.appendingPathComponent("log") }
    }

    static func box(env: [String] = ["PATH=/usr/bin"], devTmpfs: Bool = true) throws -> Box {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runcca-\(UUID().uuidString)")
        let b = Box(dir: dir)
        try FileManager.default.createDirectory(at: b.rootfs, withIntermediateDirectories: true)
        try ca.write(to: dir.appendingPathComponent("ca.pem"), atomically: true, encoding: .utf8)
        try vmRoot.write(to: dir.appendingPathComponent("vm-roots.crt"), atomically: true, encoding: .utf8)
        let mounts: [[String: Any]] = devTmpfs
            ? [["destination": "/proc", "type": "proc"], ["destination": "/dev", "type": "tmpfs", "source": "tmpfs"]]
            : [["destination": "/dev", "type": "bind", "source": "/dev"]]
        let spec: [String: Any] = ["ociVersion": "1.2.0", "root": ["path": "rootfs"],
                                   "process": ["args": ["sh"], "env": env], "mounts": mounts]
        try JSONSerialization.data(withJSONObject: spec).write(to: b.config)
        return b
    }

    /// Run the helper as the wrapper would, with `args` (runc's).
    @discardableResult
    static func helper(_ b: Box, _ args: [String], realRunc: String? = nil) throws -> Int32 {
        let script = b.dir.appendingPathComponent("helper.py")
        try constant("_RUNC_CA_HELPER").write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path] + args
        var env = ["BROMURE_CA_PEM": b.dir.appendingPathComponent("ca.pem").path,
                   "BROMURE_VM_ROOTS": b.dir.appendingPathComponent("vm-roots.crt").path,
                   "BROMURE_RUNC_CA_LOG": b.log.path, "PATH": "/usr/bin:/bin"]
        if let realRunc { env["BROMURE_REAL_RUNC"] = realRunc }
        p.environment = env
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    static func spec(_ b: Box) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: b.config)) as? [String: Any])
    }

    static func env(_ s: [String: Any]) -> [String] {
        ((s["process"] as? [String: Any])?["env"] as? [String]) ?? []
    }

    @Test("create: the image's roots plus the CA, mounted read-only at /dev/bromure-ca, the variables, the annotation")
    func create() throws {
        let b = try Self.box(env: ["PATH=/usr/bin", "PIP_CERT=/mine.pem"])
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let certs = b.rootfs.appendingPathComponent("etc/ssl/certs")
        try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
        try Self.imageRoot.write(to: certs.appendingPathComponent("ca-certificates.crt"), atomically: true, encoding: .utf8)
        // Global options before the subcommand, as containerd's shim passes them.
        #expect(try Self.helper(b, ["--root", "/run/containerd/runc/moby", "--log", "/x/log.json",
                                    "--log-format", "json", "create", "--bundle", b.bundle.path,
                                    "--pid-file", "/x/pid", "abc"]) == 0)
        let s = try Self.spec(b)
        let mount = try #require((s["mounts"] as? [[String: Any]])?.first { $0["destination"] as? String == "/dev/bromure-ca" })
        #expect(mount["type"] as? String == "bind")
        #expect((mount["options"] as? [String])?.contains("ro") == true)
        let out = URL(fileURLWithPath: try #require(mount["source"] as? String))
        let bundle = try String(contentsOf: out.appendingPathComponent("ca-certificates.crt"), encoding: .utf8)
        #expect(bundle.contains("IMAGEROOT") && bundle.contains("BROMURECA") && !bundle.contains("VMROOT"))
        #expect(try String(contentsOf: out.appendingPathComponent("bromure-ca.pem"), encoding: .utf8).contains("BROMURECA"))
        let env = Self.env(s)
        #expect(env.contains("SSL_CERT_FILE=/dev/bromure-ca/ca-certificates.crt"))
        #expect(env.contains("REQUESTS_CA_BUNDLE=/dev/bromure-ca/ca-certificates.crt"))
        #expect(env.contains("NODE_EXTRA_CA_CERTS=/dev/bromure-ca/bromure-ca.pem"))
        #expect(env.contains("PIP_CERT=/mine.pem") && !env.contains("PIP_CERT=/dev/bromure-ca/ca-certificates.crt"),
                "what the image or the user set stays")
        #expect((s["annotations"] as? [String: String])?["io.bromure.ca"] == "1")
        // Run again (a retried create): nothing doubled.
        try Self.helper(b, ["create", "--bundle", b.bundle.path, "abc"])
        let again = try Self.spec(b)
        #expect((again["mounts"] as? [[String: Any]])?.filter { $0["destination"] as? String == "/dev/bromure-ca" }.count == 1)
        #expect(Self.env(again).filter { $0.hasPrefix("SSL_CERT_FILE=") }.count == 1)
    }

    @Test("BuildKit's `runc run --bundle`; an image without roots gets the VM's; a symlink can't leave the image")
    func runAndSymlinks() throws {
        let b = try Self.box()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        // The image's store links out of it: absolute, and through `..`.
        let certs = b.rootfs.appendingPathComponent("etc/ssl/certs")
        try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
        let outside = b.dir.appendingPathComponent("secret.crt")
        try "-----BEGIN CERTIFICATE-----\nSECRET\n-----END CERTIFICATE-----\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: certs.appendingPathComponent("ca-certificates.crt").path,
                                                   withDestinationPath: outside.path)
        let pki = b.rootfs.appendingPathComponent("etc/pki/tls/certs")
        try FileManager.default.createDirectory(at: pki, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: pki.appendingPathComponent("ca-bundle.crt").path,
                                                   withDestinationPath: "../../../../../../../secret.crt")
        try Self.helper(b, ["run", "--bundle=\(b.bundle.path)", "buildkit-step"])
        let bundle = try String(contentsOf: b.bundle.appendingPathComponent("bromure-ca/ca-certificates.crt"), encoding: .utf8)
        #expect(!bundle.contains("SECRET"), "never a file outside the image")
        #expect(bundle.contains("VMROOT") && bundle.contains("BROMURECA"))
        // A link that stays inside the image is followed there.
        let b2 = try Self.box()
        defer { try? FileManager.default.removeItem(at: b2.dir) }
        let certs2 = b2.rootfs.appendingPathComponent("etc/ssl/certs")
        let real = b2.rootfs.appendingPathComponent("etc/ssl/real")
        try FileManager.default.createDirectory(at: certs2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Self.imageRoot.write(to: real.appendingPathComponent("roots.pem"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: certs2.appendingPathComponent("ca-certificates.crt").path,
                                                   withDestinationPath: "/etc/ssl/real/roots.pem")
        try Self.helper(b2, ["run", "-b", b2.bundle.path, "step"])
        let bundle2 = try String(contentsOf: b2.bundle.appendingPathComponent("bromure-ca/ca-certificates.crt"), encoding: .utf8)
        #expect(bundle2.contains("IMAGEROOT") && !bundle2.contains("VMROOT"))
    }

    @Test("never in the way: no own /dev, no CA, a broken spec -- the spec stays as it was, exit 0")
    func leftAlone() throws {
        let b = try Self.box(devTmpfs: false)
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let before = try Data(contentsOf: b.config)
        #expect(try Self.helper(b, ["create", "--bundle", b.bundle.path, "x"]) == 0)
        #expect(try Data(contentsOf: b.config) == before, "a container on the VM's /dev isn't touched")
        let c = try Self.box()
        defer { try? FileManager.default.removeItem(at: c.dir) }
        try FileManager.default.removeItem(at: c.dir.appendingPathComponent("ca.pem"))
        let cBefore = try Data(contentsOf: c.config)
        #expect(try Self.helper(c, ["create", "--bundle", c.bundle.path, "x"]) == 0)
        #expect(try Data(contentsOf: c.config) == cBefore)
        try Data("{not json".utf8).write(to: c.config)
        #expect(try Self.helper(c, ["create", "--bundle", c.bundle.path, "x"]) == 0)
        #expect(try String(contentsOf: c.log, encoding: .utf8).contains("create"), "the failure is logged")
    }

    @Test("exec: the variables for a container carrying the annotation only")
    func exec() throws {
        let b = try Self.box()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        // A stand-in for the real runc: `state` answers the annotation as
        // ANNOTATED says, and records the --root it was given.
        let fake = b.dir.appendingPathComponent("runc")
        try """
        #!/bin/sh
        echo "$@" > '\(b.dir.path)/state-args'
        if [ -f '\(b.dir.path)/annotated' ]; then
            echo '{"id":"c","bundle":"/nowhere","annotations":{"io.bromure.ca":"1"}}'
        else
            echo '{"id":"c","bundle":"/nowhere"}'
        fi
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = b.dir.appendingPathComponent("process.json")
        try JSONSerialization.data(withJSONObject: ["args": ["sh"], "env": ["PATH=/usr/bin"]]).write(to: process)
        let args = ["--root", "/run/x", "exec", "--process", process.path, "--detach", "c"]
        try Self.helper(b, args, realRunc: fake.path)
        var env = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: process)) as? [String: Any])["env"] as? [String]
        #expect(env == ["PATH=/usr/bin"], "not one of ours: left alone")
        #expect(try String(contentsOf: b.dir.appendingPathComponent("state-args"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "--root /run/x state c")
        FileManager.default.createFile(atPath: b.dir.appendingPathComponent("annotated").path, contents: nil)
        try Self.helper(b, args, realRunc: fake.path)
        env = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: process)) as? [String: Any])["env"] as? [String]
        #expect(env?.contains("SSL_CERT_FILE=/dev/bromure-ca/ca-certificates.crt") == true)
        #expect(env?.contains("NODE_EXTRA_CA_CERTS=/dev/bromure-ca/bromure-ca.pem") == true)
    }

    @Test("the wrapper: the helper for create/run/exec, its failure ignored, then the real runc; installed by a rename")
    func wrapper() throws {
        let w = try Self.constant("_RUNC_WRAPPER")
        #expect(w.hasPrefix("#!/bin/sh\n"))
        #expect(w.contains("create|run|exec)"))
        #expect(w.contains("/usr/bin/python3 -I /usr/local/libexec/bromure-runc-ca \"$@\" </dev/null >/dev/null 2>&1"))
        #expect(w.hasSuffix("exec \"$real\" \"$@\"\n"))
        #expect(try Self.constant("_RUNC_WRAPPER_PATH") == "/usr/local/sbin/runc")
        let src = try String(contentsOf: Self.agentd, encoding: .utf8)
        #expect(src.contains("_install_file_atomic(_RUNC_CA_HELPER_PATH, _RUNC_CA_HELPER)\n            and _install_file_atomic(_RUNC_WRAPPER_PATH, _RUNC_WRAPPER)"))
        // The wrapper hands every other command straight through.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runcw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", w]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}
