import Foundation

/// The install's bromure.io enrollment (macOS: the Enroll / Unenroll /
/// enrollment-status commands and ACAppDelegate's enrollment lifecycle):
/// enrolled, the heartbeat, the egress-IP heartbeat and the event uploader
/// run, their uploads over the install's mTLS leaf (BACMTLS); unenrolled,
/// they stop and buffered events are dropped. The enrollment code is the
/// user's to enter (`bromure-ac cloud enroll`); it's never logged.
extension Daemon {
    /// The lifecycle wired at start: applied now and on every change.
    // @port-skip linux-only: the daemon's share of ACAppDelegate's enrollment lifecycle (launch + onStateChange)
    func wireCloudEnrollment() async {
        await MainActor.run {
            Self.applyEnrollmentState()
            BACEnrollment.onStateChange = { Self.applyEnrollmentState() }
        }
    }

    /// Restart so a fresh enrollment heartbeats at once, and an unenroll
    /// stops it (macOS: BACEnrollment.onStateChange's body).
    // @port-skip linux-only: ACAppDelegate's BACEnrollment.onStateChange handler, without the menu and toolbar
    @MainActor static func applyEnrollmentState() {
        BACHeartbeat.shared.stop()
        BACIPRegister.shared.stop()
        if BACEnrollmentStore.load() != nil {
            BACHeartbeat.shared.start()
            BACIPRegister.shared.start()
            BACEventEmitter.shared.ensureUploader()
        } else {
            BACEventEmitter.shared.reset()
        }
        // The HTTP-log uploader follows (macOS: refreshStreamingState).
        refreshStreamingState(store: LinuxSessionHost.shared?.daemon?.mitm?.traces.withLockedValue { $0 })
    }

    /// `GET /cloud`: the enrollment state.
    // @port Status.run() h=87d8bf927cca38e9 @8775ec87
    func cloudStatus() -> ControlResponse {
        // Where the enrollment's secrets are kept: the file fallback is weaker.
        let vault: JSONValue = SecretsVault.masterKeySource.map { .string($0.rawValue) } ?? .null
        guard let install = BACEnrollmentStore.load() else { return ControlResponse(200, ["enrolled": false, "vault": vault]) }
        return ControlResponse(200, .object([
            "vault": vault,
            "enrolled": true,
            "workspace": .string(install.orgSlug),
            "user": .string(install.userEmail),
            "installId": .string(install.installId),
            "device": .string(install.deviceName),
            "server": .string(install.serverURL.absoluteString),
            "enrolledAt": .string(ISO8601DateFormatter().string(from: install.enrolledAt)),
            "bearer": .string(BACEnrollmentStore.loadInstallToken() != nil ? "present" : "missing"),
            "leafCert": .string(BACEnrollmentStore.loadLeafCertPem() == nil ? "not yet issued" : "present"),
        ]))
    }

    /// `POST /cloud/enroll {"code", "serverURL"?, "deviceName"?}`: enroll
    /// this install with a bromure.io workspace (an admin's 6-word code).
    /// 409 when already enrolled; 400 with the reason otherwise.
    // @port Enroll.run() h=4c618f01547bcda8 @8775ec87
    func cloudEnroll(_ body: JSONValue) async -> ControlResponse {
        guard let code = body["code"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return .error(400, "An enrollment code is required")
        }
        // A server URL given must be one (never a silent fall back to production).
        var url: URL?
        if let raw = body["serverURL"]?.stringValue {
            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else {
                return .error(400, "serverURL isn't an http(s) URL: \(raw)")
            }
            url = u
        }
        let device = body["deviceName"]?.stringValue ?? ProcessInfo.processInfo.hostName
        do {
            let install = try await BACEnrollment.shared.enroll(code: code, serverURL: url, deviceName: device)
            return ControlResponse(200, .object([
                "ok": true, "workspace": .string(install.orgSlug), "user": .string(install.userEmail),
                "installId": .string(install.installId), "server": .string(install.serverURL.absoluteString),
                "device": .string(install.deviceName),
                "leafCert": .string(BACEnrollmentStore.loadLeafCertPem() == nil ? "not yet issued" : "present"),
            ]))
        } catch let e as BACEnrollmentError {
            if case .alreadyEnrolled = e { return .error(409, e.localizedDescription) }
            return .error(400, e.localizedDescription)
        } catch {
            return .error(400, "enroll failed: \(error.localizedDescription)")
        }
    }

    /// `POST /cloud/unenroll`: sign this install out of its workspace.
    // @port Unenroll.run() h=97cdebd0f9cba6d0 @8775ec87
    func cloudUnenroll() async -> ControlResponse {
        guard BACEnrollmentStore.load() != nil else { return .error(409, "not enrolled — nothing to do") }
        await BACEnrollment.shared.unenroll()
        return ControlResponse(200, ["ok": true])
    }
}
