import Foundation
import SandboxEngine

/// Catalog steps published since the installed image was built (macOS: the
/// launch's image-maintenance check, its second case): offered through the
/// user's fat client (PendingPromptBroker), with macOS's words and buttons,
/// and applied to base.img once accepted (InterimBake's amend). A newer
/// published image is a full update instead, which re-applies every step:
/// no steps are offered under it.
extension Daemon {
    static let newPostinstallStepsButtons = ["Install", "Later"]

    /// The question, as macOS's alert words it.
    // partial: the alert's words and buttons, asked through the fat client (PendingPromptBroker)
    // @port ACAppDelegate.promptNewPostinstallSteps(_: [PostinstallStep]) h=f12e3df8c31ccdc0 @d3ebbda2
    static func newPostinstallStepsPromptParts(_ steps: [PostinstallStep]) -> (title: String, message: String) {
        let list = steps.map { "• \($0.description)" }.joined(separator: "\n")
        return ("New recommended packages",
                "New packages are recommended to be installed:\n\n\(list)\n\nBromure installs them into the base image (a few minutes, in the background VM). Existing workspaces keep running; each one's drift prompt will offer a reset to pick them up.")
    }

    /// The steps to offer: none without an installed image, or when the
    /// catalog publishes a newer image (macOS: catalogIsNewer, a strictly
    /// newer major; a non-numeric one counts when it differs).
    // @port-skip linux-only: the launch check's step half (macOS: inline in applicationDidFinishLaunching's image Task)
    static func postinstallStepsToOffer(_ catalog: ImageCatalog, installedStamp: String?, applied: [String]) -> [PostinstallStep] {
        guard let installed = installedStamp.map(InterimBake.majorVersion(of:)) else { return [] }
        if let published = catalog.image.map({ InterimBake.majorVersion(of: $0.version) }) {
            let newer: Bool
            if let p = Int(published), let i = Int(installed) { newer = p > i } else { newer = published != installed }
            if newer { return [] }
        }
        return catalog.pendingSteps(appliedUUIDs: applied)
    }

    /// The steps the image has: its image-state.json, or for an image that
    /// predates it, the bundled baseline's (macOS: its agents were baked in)
    /// or the list an early Linux bake left in `postinstall-steps`. Not
    /// written back (macOS writes it): the image dir may be another
    /// daemon's, and the answer is the same each time.
    // partial: computed, not written to image-state.json; an early Linux bake's postinstall-steps list
    // @port UbuntuImageManager.migrateLegacyImageStateIfNeeded() h=3a0da86ab214ef81 @84e171b8
    static func appliedPostinstallSteps(imageDir: String, baseline: ImageCatalog) -> [String] {
        if let state = ImageState.load(imageDir: imageDir) { return state.appliedStepUUIDs }
        if let listed = try? String(contentsOfFile: imageDir + "/postinstall-steps", encoding: .utf8) {
            return listed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return baseline.postinstall.map(\.uuid)
    }

    /// At the daemon's start: the steps published since the image was
    /// built, asked about once a fat client is there (nobody to ask yet, or
    /// the client gone before an answer: asked again when one is). "Later"
    /// asks again at the next start, as macOS's next launch.
    // @port-skip linux-only: the launch check, asked when a client is connected (macOS: at launch, on its own screen)
    func offerNewPostinstallSteps(every poll: Duration = .seconds(5)) async {
        let dir = config.imageDir
        guard let stamp = (try? String(contentsOfFile: dir + "/base.version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stamp.isEmpty else { return }
        // The catalog's cache in this user's state (the image dir may be
        // another daemon's).
        let store = ImageCatalogStore(distribution: .agentCoding(imageVersion: InterimBake.majorVersion(of: stamp)),
                                      supportDir: URL(fileURLWithPath: config.stateDir + "/image-catalog", isDirectory: true))
        let catalog = await store.refresh() ?? store.effective()
        let steps = Self.postinstallStepsToOffer(catalog, installedStamp: stamp,
                                                 applied: Self.appliedPostinstallSteps(imageDir: dir, baseline: store.baseline))
        guard !steps.isEmpty else { return }
        let (title, message) = Self.newPostinstallStepsPromptParts(steps)
        while !Task.isCancelled {
            guard PendingPromptBroker.hasLiveListener() else {
                try? await Task.sleep(for: poll)
                continue
            }
            // No time limit of its own (macOS's alert waits): it goes only
            // with the client.
            switch await PendingPromptBroker.shared.answerAsync(
                profileID: nil, title: title, message: message,
                buttons: Self.newPostinstallStepsButtons, fallback: 1, timeout: 24 * 3600) {
            case 0?:
                await applyPostinstallSteps(steps)
                return
            case _?:
                return
            case nil:
                try? await Task.sleep(for: poll)
            }
        }
    }

    /// The accepted steps into base.img, in the background (macOS: an
    /// APFS clone amended and swapped in; workspaces keep running).
    // partial: no progress window (the daemon's log has the steps); remote access isn't paused (the image is promoted by rename)
    // @port ACAppDelegate.startPostinstall(_: [PostinstallStep]) h=f6ec1de66eb5007b @d3ebbda2
    func applyPostinstallSteps(_ steps: [PostinstallStep]) async {
        let env = ProcessInfo.processInfo.environment
        let stamp = (try? String(contentsOfFile: config.imageDir + "/base.version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var o = InterimBake.Options(outputDir: config.imageDir,
                                    cacheDir: (env["XDG_CACHE_HOME"] ?? NSHomeDirectory() + "/.cache") + "/bromure-ac/bake",
                                    vmSetupDir: setupDir.path, imageVersion: InterimBake.majorVersion(of: stamp))
        o.amend = true
        o.postinstallSteps = steps
        o.appliedBefore = Self.appliedPostinstallSteps(imageDir: config.imageDir,
                                                       baseline: ImageDistribution.agentCoding(imageVersion: o.imageVersion).loadBaseline())
        let log = { (line: String) in FileHandle.standardError.write(Data("bromure-ac daemon: [image] \(line)\n".utf8)) }
        do {
            _ = try await InterimBake.bake(o, progress: log)
            let now = (try? String(contentsOfFile: config.imageDir + "/base.version", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            log("Packages installed (base image now v\(now)).")
        } catch {
            log("the recommended packages weren't installed: \(error)")
        }
    }
}
