import Foundation
import Testing
@testable import ACLinux
import SandboxEngine

extension DaemonGlobalSuites {
    /// The enrollment store's leaf keys (shared BACEnrollmentStore): a
    /// rotation deletes the previous serial's key, destroy() every key this
    /// install stored, and a renewal requested before a destroy can't store
    /// its leaf after. Gated as AccountSignOutTests (BROMURE_TEST_ISOLATED=1,
    /// XDG_DATA_HOME a temp directory): the store's directory is the user's
    /// data directory otherwise.
    @Suite("Enrollment store", .serialized)
    struct EnrollmentStoreTests {
        static var isolated: Bool {
            let e = ProcessInfo.processInfo.environment
            return e["BROMURE_TEST_ISOLATED"] == "1" && (e["XDG_DATA_HOME"] ?? "").hasPrefix("/tmp/")
        }

        @Test(.enabled(if: isolated)) func leafKeysGoWithTheirLeafAndTheEnrollment() throws {
            let saved = BACSecretStore.backend
            let secrets = AccountSignOutTests.MemorySecrets()
            BACSecretStore.backend = secrets
            defer { BACSecretStore.backend = saved; BACEnrollmentStore.destroy() }
            func hasKey(_ serial: String) -> Bool { BACEnrollmentStore.loadLeafPrivateKey(serialHex: serial) != nil }
            try BACEnrollmentStore.storeLeafCert(certPem: "A", caPem: "CA", privateKeyDER: Data([1]), serialHex: "AA01")
            #expect(hasKey("aa01"))
            try BACEnrollmentStore.storeLeafCert(certPem: "B", caPem: "CA", privateKeyDER: Data([2]), serialHex: "bb02")
            #expect(hasKey("bb02") && !hasKey("aa01"), "the rotated-out leaf's key is gone")
            // A renewal requested before an unenroll: refused after it.
            let epoch = BACEnrollmentStore.epoch
            BACEnrollmentStore.destroy()
            #expect(!hasKey("bb02"), "destroy() deletes the keys")
            #expect(throws: BACEnrollmentError.self) {
                try BACEnrollmentStore.storeLeafCert(certPem: "C", caPem: "CA", privateKeyDER: Data([3]), serialHex: "cc03", epoch: epoch)
            }
            #expect(!hasKey("cc03") && BACEnrollmentStore.loadLeafCertPem() == nil, "nothing written back")
            // The store's directory is the owner's only.
            let dir = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "") + "/BromureAC/managed"
            let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
        }
    }
}
