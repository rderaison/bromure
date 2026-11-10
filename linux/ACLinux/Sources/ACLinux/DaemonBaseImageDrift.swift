import Foundation
import NIOConcurrencyHelpers

/// Base-image drift (macOS: ACAppDelegate's drift check in launch and
/// resolveRemoteLaunchPrompts): a workspace records which base its system
/// disk was cloned from; once a newer base is on disk, its next start offers
/// the upgrade (a disk reset), unless the user said "No" to that very base
/// or "Remind me later" within the day. Asked through the client
/// (PendingPromptBroker), as macOS asks a remote start; an unattended start
/// boots as-is.
extension Daemon {
    /// Tests: the owner's answer, by workspace (nil: asked through the broker).
    static let driftAnswerForTesting = NIOLockedValueBox<(@Sendable (UUID) async -> Int)?>(nil)

    /// One launch question (the drift offer) up per workspace at a time
    /// (macOS: ACAppDelegate.LaunchQuestionGate).
    // @port-skip linux-only: container of LaunchQuestionGate's port
    struct LaunchQuestionGate {
        private var up = Set<Profile.ID>()
        /// False: this workspace already has one up: don't ask, don't boot.
        // @port ACAppDelegate.LaunchQuestionGate.begin(_: Profile.ID) h=ee2262ef9a771569 @4237c02e
        mutating func begin(_ id: Profile.ID) -> Bool { up.insert(id).inserted }
        // partial: present but marked @port-skip ("see LaunchQuestionGate.begin"), so portmap didn't claim it
        // @port ACAppDelegate.LaunchQuestionGate.end(_: Profile.ID) h=ba2c869405284a63 @d3ebbda2
        mutating func end(_ id: Profile.ID) { up.remove(id) }
        // partial: present but marked @port-skip, as above
        // @port ACAppDelegate.LaunchQuestionGate.isUp(_: Profile.ID) h=e86b95b6a6fd8ff6 @d3ebbda2
        func isUp(_ id: Profile.ID) -> Bool { up.contains(id) }
    }

    enum UpgradeAnswerOutcome: Equatable {
        case applied
        case diskInUse(upgradeSkipped: Bool)
    }

    /// The base image on disk now (its version stamp), or nil when none
    /// (an empty stamp is none).
    // @port ACAppDelegate.readCurrentBaseVersion() h=d25ad68d47b75cd9 @4237c02e
    func readCurrentBaseVersion() -> String? {
        (try? String(contentsOfFile: config.imageDir + "/base.version", encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `current` is a later base than `recorded`: by major, then by
    /// dot-revision, numerically; stamps that aren't numbers compare as
    /// different (macOS's baseImageNeedsUpdate fallback). Linux only offers
    /// a strictly newer base: an older one (a downgrade, install.sh copying
    /// an older image) isn't an upgrade.
    // @port-skip linux-only: the strictly-newer test of baseImageUpgradeOfferDue (macOS: any different stamp)
    static func baseVersion(_ current: String, isNewerThan recorded: String) -> Bool {
        func parts(_ s: String) -> (Int, Int)? {
            let p = s.split(separator: ".", maxSplits: 1).map(String.init)
            guard let major = p.first.flatMap({ Int($0) }) else { return nil }
            guard p.count == 2 else { return (major, 0) }
            guard let rev = Int(p[1]) else { return nil }
            return (major, rev)
        }
        guard let c = parts(current), let r = parts(recorded) else { return current != recorded }
        return c > r
    }

    /// The base on disk is newer than the one this workspace's disk was
    /// cloned from, and the user hasn't said "No" to this very base or
    /// "Remind me later" within the day: the upgrade offer is due.
    // partial: a strictly newer base only (macOS: any other stamp)
    // @port ACAppDelegate.baseImageUpgradeOfferDue(_: Profile, current: String?) h=e733f1404194b42c @4237c02e
    func baseImageUpgradeOfferDue(_ profile: Profile, current: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: vmDir(profile.id.uuidString.lowercased()) + "/disk.raw"),
              let recorded = profile.baseImageVersionAtClone,
              let current, Self.baseVersion(current, isNewerThan: recorded) else { return false }
        if profile.baseImageUpgradeDeclinedFor == current { return false }
        if let until = profile.baseImageUpgradeRemindAfter, until > Date() { return false }
        return true
    }

    /// The offer's buttons, in order: index 0 upgrades; the other two launch
    /// as-is and remember the answer.
    static let baseImageUpgradeButtons = ["Yes, upgrade", "No", "Remind me later"]

    // @port ACAppDelegate.static driftPromptParts(recorded: String, current: String) h=1b94b9eae6e1b5a8 @4237c02e
    static func driftPromptParts(recorded: String, current: String) -> (title: String, message: String) {
        ("A newer base image is available.",
         "This workspace runs base v\(recorded); v\(current) is on disk. Upgrade it now? Upgrading resets the workspace disk — anything installed inside the VM is wiped; your project folder is untouched. “No” keeps this base until the next one ships; “Remind me later” asks again on the first boot after tomorrow.")
    }

    /// "Yes, upgrade" answered after the workspace started anyway (another
    /// start, during the question): what happened, and what to do.
    // @port ACAppDelegate.static upgradeSkippedParts(_: String) h=2291473722e53285 @4237c02e
    static func upgradeSkippedParts(_ name: String) -> (title: String, message: String) {
        (String(format: NSLocalizedString("“%@” wasn't upgraded", comment: "base image upgrade skipped"), name),
         NSLocalizedString(
            "It started on its current disk while the question was up (an automation launched it). Shut it down and start it again to be asked again.",
            comment: "base image upgrade skipped"))
    }

    /// The workspace's VM has its disk open (running, or a start under way).
    // @port ACAppDelegate.diskInUse(_: Profile.ID) h=a9a77dd071a6cd22 @d3ebbda2
    func diskInUse(_ id: Profile.ID) -> Bool {
        let key = id.uuidString.lowercased()
        return live[key] != nil || starting.contains(key) || repairMarks.contains(key) || hasRescue(for: key)
    }

    /// Apply the offer's answer: "Yes" resets the disk now; "No" keeps quiet
    /// until a different base ships; "Remind me later" keeps quiet until the
    /// next boot after a day. A boot that began meanwhile has the disk open:
    /// "Yes" isn't carried out (and says so), the other answers are
    /// recorded; either way that boot owns the workspace.
    // partial: the disk is the daemon's <state>/vms/<id>/disk.raw (macOS: store.resetDisk)
    // @port ACAppDelegate.applyBaseImageUpgradeAnswer(_: Int, profile: inoutProfile, current: String) h=301124efe0c30f97 @4237c02e
    @discardableResult
    func applyBaseImageUpgradeAnswer(_ index: Int, profile: inout Profile, current: String) -> UpgradeAnswerOutcome {
        let busy = diskInUse(profile.id)
        switch index {
        case 0:
            if busy { return .diskInUse(upgradeSkipped: true) }
            // macOS's resetDisk: the system disk (the next boot clones the
            // base again; the home is its own image) and any saved state.
            let dir = vmDir(profile.id.uuidString.lowercased())
            try? FileManager.default.removeItem(atPath: dir + "/disk.raw")
            try? FileManager.default.removeItem(atPath: snapshotDir(profile.id.uuidString.lowercased()))
            emitDiskResetEvent(profile: profile, reason: "base_image_drift")
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(profile.name)': system disk reset to base v\(current) (upgrade)\n".utf8))
        case 1:
            profile.baseImageUpgradeDeclinedFor = current
            profile.baseImageUpgradeRemindAfter = nil
            recordBaseImageUpgradeAnswer(profileID: profile.id, declinedFor: current, remindAfter: nil)
        default:
            let until = Date().addingTimeInterval(24 * 3600)
            profile.baseImageUpgradeDeclinedFor = nil
            profile.baseImageUpgradeRemindAfter = until
            recordBaseImageUpgradeAnswer(profileID: profile.id, declinedFor: nil, remindAfter: until)
        }
        return busy ? .diskInUse(upgradeSkipped: false) : .applied
    }

    // @port ACAppDelegate.recordBaseImageUpgradeAnswer(profileID: UUID, declinedFor: String?, remindAfter: Date?) h=31fadbec9ad1e5bb @4237c02e
    func recordBaseImageUpgradeAnswer(profileID: UUID, declinedFor: String?, remindAfter: Date?) {
        guard var p = profileStore.loadAll().first(where: { $0.id == profileID }) else { return }
        p.baseImageUpgradeDeclinedFor = declinedFor
        p.baseImageUpgradeRemindAfter = remindAfter
        try? profileStore.save(p)
    }

    /// Which base image a freshly cloned system disk came from, on the
    /// stored record.
    // @port ACAppDelegate.stampBaseImageVersionAtClone(_: String, profileID: UUID) h=a6128e135b97ddae @4237c02e
    func stampBaseImageVersionAtClone(_ version: String, profileID: UUID) {
        guard var p = profileStore.loadAll().first(where: { $0.id == profileID }) else { return }
        p.baseImageVersionAtClone = version
        try? profileStore.save(p)
    }

    /// The disk-reset event, with the base versions, so the cloud can tell
    /// "this install was reset" against the supply-chain timeline.
    // @port ACAppDelegate.emitDiskResetEvent(profile: Profile, reason: String) h=97b9a94368ec7a89 @4237c02e
    func emitDiskResetEvent(profile: Profile, reason: String) {
        var data: [String: AnyJSON] = [
            "reason": .string(reason),
        ]
        if let v = profile.baseImageVersionAtClone {
            data["base_image_version_at_clone"] = .string(v)
        }
        if let v = readCurrentBaseVersion() {
            data["base_image_version_current"] = .string(v)
        }
        BACEventEmitter.shared.emitDetached(
            profileID: profile.id,
            eventType: "vm.disk_reset",
            eventData: data)
    }

    /// The start's drift question (macOS: launch's drift check, and
    /// resolveRemoteLaunchPrompts for a remote start): nil to go on booting
    /// (no offer due, unattended, "No", "Remind me later", or "Yes" with the
    /// disk reset), else why this start stops (a question already up, or the
    /// workspace started meanwhile). Nobody answering is "Remind me later".
    // partial: its drift half (a compromised workspace's start is refused, Daemon.start); the outcome is in the start's response
    // @port ACAppDelegate.resolveRemoteLaunchPrompts(_: Profile, detached: Bool, freshBootFallback: Bool, quiet: Bool) h=dfb9e70adf2469a8 @4237c02e
    // partial: drift half only. The compromised half is a 409 refusal in Daemon.start (see confirmWipeAndProceedAsync)
    // @port ACAppDelegate.launchNeedsPreflightPrompt(_: Profile) h=4c595c376c12e021 @d3ebbda2
    func resolveDriftPrompt(_ rec: VMRecord, unattended: Bool) async -> ControlResponse? {
        guard !rec.managed, var profile = existingProfile(for: rec) else { return nil }
        let current = readCurrentBaseVersion()
        guard baseImageUpgradeOfferDue(profile, current: current),
              let recorded = profile.baseImageVersionAtClone, let current else { return nil }
        if unattended {
            // Nobody to ask: launch as-is (the disk is kept, the way "No"
            // keeps it; an upgrade is the owner's call).
            FileHandle.standardError.write(Data(
                "[ac] '\(profile.name)' is on base v\(recorded), current v\(current) — unattended start launches as-is\n".utf8))
            return nil
        }
        guard launchQuestions.begin(profile.id) else {
            return .error(409, "'\(rec.name)' already has a question up (a newer base image): answer it first")
        }
        let (title, message) = Self.driftPromptParts(recorded: recorded, current: current)
        let index: Int
        if let answer = Self.driftAnswerForTesting.withLockedValue({ $0 }) {
            index = await answer(profile.id)
        } else {
            index = await PendingPromptBroker.shared.askAsync(
                profileID: profile.id, title: title, message: message,
                buttons: Self.baseImageUpgradeButtons, fallback: 2)
        }
        launchQuestions.end(profile.id)
        // Deleted while the question was up: nothing to boot.
        guard registry.find(rec.id) != nil else { return .error(404, "'\(rec.name)' was removed") }
        if case .diskInUse(let skipped) = applyBaseImageUpgradeAnswer(index, profile: &profile, current: current) {
            if skipped {
                let (title, message) = Self.upgradeSkippedParts(profile.name)
                return .error(409, title + ": " + message)
            }
            // That other start owns the workspace.
            return live[rec.id] != nil ? ControlResponse(200, ["status": "running"])
                : .error(409, "VM '\(rec.name)' is already starting")
        }
        return nil
    }
}
