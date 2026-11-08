import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Glibc
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The kernel sentry on the daemon (macOS: KernelSentryService.attach and
    /// wireSentryModules): a sentry workspace's listener on vsock 5841 takes
    /// the module's hello and pins it host-side; a plain workspace has none.
    /// Its modules come only from a configured catalog, and a launch stages
    /// the cached module of every kernel the workspace is known to have.
    /// Catalogs are served by a stub session (no host is reached).
    @Suite("Kernel sentry on the daemon", .serialized)
    struct DaemonSentryTests {
        static func frame(_ obj: [String: Any]) -> Data {
            let body = try! JSONSerialization.data(withJSONObject: obj)
            var d = Data([UInt8(body.count >> 24 & 0xff), UInt8(body.count >> 16 & 0xff),
                          UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)])
            d.append(body)
            return d
        }

        @Test func aSentryWorkspacesChannelTakesItsHello() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { ProfileStore.defaultRootDir = prior; try? FileManager.default.removeItem(atPath: dir) }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            await MainActor.run {
                KernelSentryService.shared.pinDirectory = { ProfileStore().profileDirectory(for: $0) }
            }
            var p = Profile(name: "watched", tool: .claude, authMode: .token)
            p.kernelSentry = .bestEffort
            p = try ProfileStore().save(p)
            let rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            let uds = dir + "/v.sock"
            let l = try #require(await d.serveSentry(rec, profile: p, udsPath: uds, stored: nil, restoring: false))
            defer { l.stop(); KernelSentryService.shared.dropBridge(p.id)?.closeChannel() }
            // A plain workspace has none.
            #expect(await d.serveSentry(rec, profile: Profile(name: "plain", tool: .claude, authMode: .token),
                                        udsPath: dir + "/w.sock", stored: nil, restoring: false) == nil)

            let fd = try ControlClient.connect(to: uds + "_\(KernelSentryService.vsockPort)")
            defer { close(fd) }
            let secret = String(repeating: "ab", count: 32)
            let hello = Self.frame(["type": "hello", "v": 1, "secret": secret, "boot_id": "b",
                                    "kernel": "6.8.0-139-generic", "module": "1"])
            _ = hello.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, hello.count) }
            var snap: SentryBridge.Snapshot?
            for _ in 0..<100 {
                snap = KernelSentryService.shared.snapshot(p.id)
                if snap?.connected == true && snap?.kernel != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(snap?.connected == true && snap?.kernel == "6.8.0-139-generic", "the sentry is connected")
            let pin = ProfileStore().profileDirectory(for: p).appendingPathComponent("sentry.pin")
            #expect((try? String(contentsOf: pin, encoding: .utf8))?.contains(secret) == true, "its secret pinned host-side")
            // The session's end drops the channel (clearWorkspaceProxyState).
            await d.clearWorkspaceProxyState(p.id)
            #expect(KernelSentryService.shared.snapshot(p.id) == nil)
            await d.shutdown()
        }

        @Test func modulesComeOnlyFromAConfiguredCatalog() {
            #expect(Daemon.makeSentryModuleStore(stateDir: "/nonexistent-state", env: [:]) == nil)
            #expect(Daemon.makeSentryModuleStore(stateDir: "/nonexistent-state", env: ["BROMURE_SENTRY_CATALOG_BASE": ""]) == nil)
            let dir = (try? shortTempDir()) ?? NSTemporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let s = Daemon.makeSentryModuleStore(stateDir: dir, env: ["BROMURE_SENTRY_CATALOG_BASE": "http://127.0.0.1:9/"])
            #expect(s?.root.path == dir + "/sentry-modules")
            #expect(s?.base.absoluteString == "http://127.0.0.1:9/" && s?.requireSignature == false)
        }

        /// A launch's staging (writeCredentialFiles) puts the cached module of
        /// each kernel the workspace is known to have into its meta share's
        /// sentry/, beside the source; a workspace without the sentry gets no
        /// sentry/ at all.
        @Test func aLaunchStagesTheKnownKernelsModules() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../Sources/AgentCoding/Resources/vm-setup").standardized
            let hash = try #require(SentryModuleStore.shippedSourceHash(setupDir: setup))
            let kernel = "6.8.0-1-generic"
            let body = Data("module-\(kernel)".utf8)
            let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let path = "sentry/\(hash)/\(kernel)/bromure_sentry-\(kernel).ko"
            let catalog = #"{"formatVersion":1,"sourceHash":"\#(hash)","modules":[{"kernel":"\#(kernel)","path":"\#(path)","sha256":"\#(sha)","bytes":\#(body.count)}]}"#
            let host = "catalog-\(UUID().uuidString.prefix(8)).test"
            SentryStubProtocol.serve(host, "/sentry/\(hash)/catalog.json", 200, Data(catalog.utf8))
            SentryStubProtocol.serve(host, "/" + path, 200, body)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SentryStubProtocol.self]
            // A local catalog, unsigned (as BROMURE_SENTRY_CATALOG_BASE's are).
            let modules = SentryModuleStore(root: URL(fileURLWithPath: dir + "/sentry-modules", isDirectory: true),
                                            base: URL(string: "https://\(host)/")!, requireSignature: false,
                                            session: URLSession(configuration: config))
            var p = Profile(name: "watched", tool: .claude, authMode: .token)
            p.kernelSentry = .bestEffort
            #expect(await modules.ensure(kernel: kernel, hash: hash) == nil)
            modules.record(kernels: [kernel], for: p.id)

            let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            let store = ProfileStore(rootDir: URL(fileURLWithPath: dir + "/profiles", isDirectory: true))
            func stage(_ p: Profile) throws {
                try Daemon.writeCredentialFiles(p, plan: nil, registration: false, meta: meta, kubeYAML: nil, store: store,
                                                setupDir: setup, sentryModules: modules, seedStandIns: { _, _ in })
            }
            try stage(p)
            let sentry = meta.appendingPathComponent("sentry", isDirectory: true)
            #expect(try Data(contentsOf: sentry.appendingPathComponent("bromure_sentry-\(kernel).ko")) == body)
            #expect(FileManager.default.fileExists(atPath: sentry.appendingPathComponent("src/bromure_sentry.c").path))
            p.kernelSentry = .off
            try stage(p)
            #expect(!FileManager.default.fileExists(atPath: sentry.path), "no sentry: no sentry/")
        }
    }
}
