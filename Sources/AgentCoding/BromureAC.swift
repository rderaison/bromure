import ArgumentParser
import Cocoa
import Crypto
import Foundation
import SandboxEngine
import Sparkle
import SwiftUI
@preconcurrency import Virtualization

/// SPM resource bundle, with a fallback for the .app layout. SPM's
/// auto-generated `Bundle.module` looks for the bundle next to
/// `Bundle.main.bundleURL` (the .app root), but codesign requires
/// resources under `Contents/Resources/`. Reading `Bundle.module`
/// directly traps on a fresh-system .app launch — check the resource
/// dir first and only fall back to `Bundle.module` for `swift run`.
let acResourceBundle: Bundle = {
    let bundleName = "bromure_bromure-ac"
    if let resourceURL = Bundle.main.resourceURL,
       let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
        return bundle
    }
    return Bundle.module
}()

@main
struct BromureAC: ParsableCommand {
    /// Built from the invocation name (argv[0]). Invoked as `bromure-cli` we
    /// hide the app-internal commands — Image management (init/info/reset, which
    /// can bounce into the in-app GUI setup flow) and the `mcp` stdio server —
    /// and expose no GUI default, so a bare or unknown invocation prints help
    /// instead of trapping while NSApplication tries to start. Invoked as
    /// `bromure-ac` (the app binary and every child it spawns) everything is
    /// available. `commandName` echoes the actual argv[0] so USAGE reads right.
    static var configuration: CommandConfiguration {
        let argv0 = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        let name = argv0.isEmpty ? "bromure-ac" : argv0
        let asCLI = (name == "bromure-cli")

        // Qualified: `CommandGroup` is ambiguous here (SwiftUI also defines one).
        var groups: [ArgumentParser.CommandGroup] = []
        if !asCLI {
            groups.append(ArgumentParser.CommandGroup(name: "Image management",
                                       subcommands: [Init.self, Info.self, Reset.self,
                                                     InitFossImage.self, VerifyImage.self]))
        }
        groups.append(ArgumentParser.CommandGroup(name: "Workspaces", subcommands: [Profiles.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Tracing", subcommands: [Trace.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Local inference", subcommands: [Model.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Enterprise features",
                                   subcommands: [Enroll.self, Unenroll.self, Status.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Integration",
                                   subcommands: asCLI ? [Remote.self] : [MCP.self, Remote.self]))

        // `run` (the GUI) + `__remote-menu` (SSH ForceCommand target) +
        // `__attach-window` (native terminal view pump) are app-internal;
        // bromure-cli exposes none of them and has no GUI default.
        let topLevel: [ParsableCommand.Type] =
            asCLI ? [] : [Run.self, RemoteMenu.self, VMAttachWindow.self]
        let defaultCmd: ParsableCommand.Type? = asCLI ? nil : Run.self
        return CommandConfiguration(
            commandName: name,
            abstract: "Run Codex / Claude Code in an isolated, persistent VM.",
            subcommands: topLevel,
            groupedSubcommands: groups,
            defaultSubcommand: defaultCmd)
    }

    /// Strip Apple-internal flags (e.g. -AppleLanguages, -AppleLocale) from
    /// CommandLine.arguments so ArgumentParser doesn't reject them. Without
    /// this, `bromure-ac -AppleLanguages "(fr)"` exits with "Unknown option"
    /// before NSApplication starts. Mirrors the browser entry point.
    static func main() {
        // Ignore SIGPIPE process-wide. Our hand-rolled loopback servers (the
        // MITM repair proxy + inference bridge, the automation server, the MLX
        // engine) use raw BSD-socket write()s. Writing to a peer that already
        // closed — e.g. the MITM aborting a slow local-inference request, then
        // the repair proxy finishing and writing the buffered reply back to the
        // now-dead connection — delivers SIGPIPE, whose default disposition
        // kills the process (the repair proxy runs *in the app*, so it took the
        // whole app down). Ignored, write() returns EPIPE and the loop ends
        // cleanly. NIO already ignores SIGPIPE for its own sockets; these
        // don't go through NIO. Runs for every process (GUI, CLI, engine child).
        signal(SIGPIPE, SIG_IGN)

        let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        let args = Array(CommandLine.arguments.dropFirst())
        var filtered: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-Apple") { skipNext = true; continue }
            filtered.append(arg)
        }
        // Invoked as `bromure-cli` (the /usr/local/bin symlink → this binary)
        // with no subcommand: print help instead of falling through to the GUI
        // default subcommand (Run), which traps when there's no .app bundle to
        // host NSApplication. The .app's own `bromure-ac` binary keeps its GUI
        // default. (Bug#4.)
        if filtered.isEmpty, invokedName == "bromure-cli" {
            filtered = ["help"]
        }
        Self.main(filtered)
    }
}

// MARK: - init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the Ubuntu base image (downloads the prebuilt image; local build as fallback)."
    )

    @Flag(name: .long,
          help: "Skip the prebuilt-image download and build locally with setup.sh (~10 min).")
    var buildLocal = false

    @Flag(name: .long,
          help: ArgumentHelp("Fail when the download fails instead of falling back to a local build.",
                             visibility: .hidden))
    var downloadOnly = false

    @Option(name: .long,
            help: ArgumentHelp("Install into this directory instead of Application Support (pipeline tests).",
                               visibility: .hidden))
    var storageDir: String?

    func run() throws {
        let storageDirURL = storageDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let imageManager = try makeImageManager(storageDir: storageDirURL)
        // With a custom storage dir, scope the catalog cache there too —
        // a pipeline test must not pollute (or read) the real app's
        // cached catalog in Application Support.
        let catalogStore = storageDirURL.map { ImageCatalogStore(supportDir: $0) }
            ?? ImageCatalogStore.shared
        // The install path keeps the existing image usable until the
        // new one is ready (writes go to .partial files, then atomic
        // swap), so we don't pre-delete the version stamp. `init` is
        // an explicit user verb — if they typed it, they want the
        // image reinstalled — so always pass force=true.
        // Pump the main RunLoop while an async Task does the actual work.
        // We can't `semaphore.wait()` here because the provisioner VM is
        // @MainActor — a sync block of the main thread starves the main
        // actor's executor and the install hangs at the first MainActor hop.
        // Driving the RunLoop instead lets MainActor continuations run.
        var result: Result<Void, Error>?
        let buildLocal = self.buildLocal
        let downloadOnly = self.downloadOnly
        Task {
            let progress: (String) -> Void = { msg in
                FileHandle.standardError.write(Data("[init] \(msg)\n".utf8))
            }
            // Local build path: the postinstall steps come from the
            // freshest catalog we can get (remote, else the bundled
            // baseline) — a new installation applies all of them
            // without prompting, per the setup consent.
            func buildLocally() async throws {
                _ = await catalogStore.refresh()
                let catalog = catalogStore.effective()
                try await imageManager.createBaseImage(
                    progress: progress,
                    force: true,
                    postinstallSteps: catalog.sortedSteps
                )
            }
            do {
                if buildLocal {
                    try await buildLocally()
                } else {
                    do {
                        try await imageManager.downloadBaseImage(
                            catalogStore: catalogStore, progress: progress)
                    } catch let error where !downloadOnly
                        && UbuntuImageManager.isDownloadSideFailure(error) {
                        // Only download-side failures (catalog, transfer,
                        // checksum, expansion) fall back — a postinstall-VM
                        // failure would hit the identical machinery in the
                        // local bake and fail again after ~10 wasted min.
                        progress("Prebuilt-image download unavailable (\(error.localizedDescription)) — building locally instead.")
                        try await buildLocally()
                    }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        try result!.get()
        print("Base image ready: \(imageManager.baseDiskURL.path)")
    }
}

// MARK: - init-foss-image

/// Publisher-side build (Jenkinsfile.image → scripts/publish-image.sh):
/// produce the redistributable base image containing free software only —
/// no Claude Code / Codex / Grok / gcloud (those are img-catalog.json
/// postinstall steps applied on the end-user's machine) and no Apple
/// fonts. The artifacts land in --output, never in Application Support,
/// so a publish run can't clobber a developer's own base image.
struct InitFossImage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init-foss-image",
        abstract: "Build the redistributable free-software base image (publish pipeline)."
    )

    @Option(name: .long,
            help: "Directory the artifacts land in (base.img, base.version, build-info.json).")
    var output: String

    func run() throws {
        let outputDir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let imageManager = UbuntuImageManager(storageDir: outputDir,
                                              setupDir: try locateSetupDir())

        var result: Result<Void, Error>?
        Task {
            do {
                try await imageManager.createBaseImage(
                    progress: { msg in
                        FileHandle.standardError.write(Data("[init-foss-image] \(msg)\n".utf8))
                    },
                    force: true,
                    includeMacFonts: false,
                    postinstallSteps: []
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        try result!.get()

        // build-info.json: the publish script reads image metadata from
        // here instead of parsing Swift sources.
        let info: [String: String] = [
            "version": UbuntuImageManager.imageVersion,
            "ubuntuRelease": UbuntuImageManager.ubuntuRelease,
            "description": UbuntuImageManager.imageDescription,
            "builtAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDir.appendingPathComponent("build-info.json"))
        print("Free-software image ready: \(imageManager.baseDiskURL.path)")
    }
}

// MARK: - verify-image

/// Publish-pipeline gate: boot a base image headless and require the
/// serial login prompt within the timeout. Run it against a throwaway
/// APFS clone (`cp -c`) — booting dirties the disk (machine-id, journal),
/// and the artifact being published must stay byte-identical to what was
/// checksummed.
struct VerifyImage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-image",
        abstract: "Boot-check a base image: wait for the serial login prompt (run on a clone)."
    )

    @Option(name: .long, help: "Path to the disk image to boot (a disposable clone).")
    var disk: String

    @Option(name: .long, help: "Boot timeout in seconds.")
    var timeout: Int = 300

    func run() throws {
        let diskURL = URL(fileURLWithPath: disk)
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            throw ValidationError("no disk image at \(diskURL.path)")
        }
        let imageManager = try makeImageManager()
        var result: Result<Void, Error>?
        let timeout = TimeInterval(self.timeout)
        Task {
            do {
                try await imageManager.verifyImageBoots(
                    diskURL: diskURL,
                    timeout: timeout,
                    progress: { msg in
                        FileHandle.standardError.write(Data("[verify-image] \(msg)\n".utf8))
                    }
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        try result!.get()
        print("Image boot verification passed: \(diskURL.path)")
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show information about the base image (version, size, path)."
    )

    func run() throws {
        let im = try makeImageManager()
        guard im.hasBaseImage else {
            print("No base image yet. Build it with `bromure-ac init`.")
            return
        }
        let version = (try? String(contentsOf: im.versionStampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let url = im.baseDiskURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let apparent = (attrs[.size] as? NSNumber)?.int64Value
        let onDisk = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
        func human(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        print("Base image")
        print("  version:  \(version)")
        if let apparent { print("  size:     \(human(apparent)) (virtual)") }
        if let onDisk { print("  on disk:  \(human(Int64(onDisk)))") }
        print("  path:     \(url.path)")
    }
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a session against the base image and open the display window.",
        shouldDisplay: false
    )

    @Flag(name: .long,
          help: "Run as a background agent (no window). Used by the CLI to autostart the VM service.")
    var headless = false

    func run() throws {
        let imageManager = try makeImageManager()
        // No base-image gate here. `ACAppDelegate.applicationDidFinishLaunching`
        // checks `imageManager.hasBaseImage` and routes to the in-app
        // setup flow (SetupView → InitializingView) when missing — same
        // path "Rebuild Base Image…" uses. Bouncing the user back to a
        // CLI invocation would defeat the point of having a GUI.

        // Sync subcommand + MainActor.assumeIsolated matches the browser
        // pattern. NSApplication.run() needs to drive the main RunLoop
        // directly; running it inside an async context (`AsyncParsableCommand`
        // + `MainActor.run`) wedges the run loop and the app never appears.
        let headless = self.headless
        MainActor.assumeIsolated {
            FileHandle.standardError.write(Data(
                "[run] launching NSApplication\(headless ? " (headless agent)" : "")…\n".utf8))
            let app = NSApplication.shared
            app.setActivationPolicy(headless ? .accessory : .regular)

            let delegate = ACAppDelegate(imageManager: imageManager, headless: headless)
            app.delegate = delegate
            app.mainMenu = makeMainMenu(delegate: delegate)

            app.run()
        }
    }
}

/// Minimal app menu so ⌘-Q, ⌘-W, etc. work, plus a standard Edit menu so
/// Cut/Copy/Paste/Select-All function in text fields.
@MainActor
private func makeMainMenu(delegate: ACAppDelegate) -> NSMenu {
    let main = NSMenu()
    let appMenuItem = NSMenuItem()
    main.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu

    // Prefer the bundle's display name (Info.plist CFBundleDisplayName /
    // CFBundleName) over `processName`, which returns the executable
    // file name ("bromure-ac") rather than the user-facing app name.
    let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? ProcessInfo.processInfo.processName
    let L = { (k: String) in NSLocalizedString(k, comment: "") }
    appMenu.addItem(withTitle: String(format: L("About %@"), appName),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())

    let prefsItem = NSMenuItem(title: L("Preferences…"),
                                action: #selector(ACAppDelegate.openPreferencesAction(_:)),
                                keyEquivalent: ",")
    prefsItem.target = delegate
    appMenu.addItem(prefsItem)

    let remoteItem = NSMenuItem(title: L("Remote Access…"),
                                action: #selector(ACAppDelegate.openRemoteAccessAction(_:)),
                                keyEquivalent: "")
    remoteItem.target = delegate
    appMenu.addItem(remoteItem)

    let rebuildItem = NSMenuItem(title: L("Rebuild Base Image…"),
                                 action: #selector(ACAppDelegate.rebuildBaseImageAction(_:)),
                                 keyEquivalent: "")
    rebuildItem.target = delegate
    appMenu.addItem(rebuildItem)

    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: String(format: L("Hide %@"), appName),
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
    let hideOthers = NSMenuItem(title: L("Hide Others"),
                                action: #selector(NSApplication.hideOtherApplications(_:)),
                                keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(withTitle: L("Show All"),
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: String(format: L("Quit %@"), appName),
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")

    // Workspaces menu — before Edit. Acts on the unified window's selected
    // workspace + active tab.
    let wsMenuItem = NSMenuItem()
    main.addItem(wsMenuItem)
    let wsMenu = NSMenu(title: L("Workspaces"))
    wsMenuItem.submenu = wsMenu

    let newWsItem = NSMenuItem(title: L("New Workspace…"),
                               action: #selector(ACAppDelegate.newWorkspaceAction(_:)),
                               keyEquivalent: "n")
    newWsItem.keyEquivalentModifierMask = [.command, .shift]
    newWsItem.target = delegate
    wsMenu.addItem(newWsItem)

    let newTabItem = NSMenuItem(title: L("New tab"),
                                action: #selector(ACAppDelegate.newTabAction(_:)),
                                keyEquivalent: "t")   // ⌘T (matches the existing chord)
    newTabItem.target = delegate
    wsMenu.addItem(newTabItem)

    let addToGridItem = NSMenuItem(title: L("Add Terminal to Grid"),
                                   action: #selector(ACAppDelegate.addTerminalToGridAction(_:)),
                                   keyEquivalent: "d")   // ⌘D (matches the existing chord)
    addToGridItem.target = delegate
    wsMenu.addItem(addToGridItem)

    let deleteWsItem = NSMenuItem(title: L("Delete"),
                                  action: #selector(ACAppDelegate.deleteWorkspaceAction(_:)),
                                  keyEquivalent: "")
    deleteWsItem.target = delegate
    wsMenu.addItem(deleteWsItem)

    wsMenu.addItem(NSMenuItem.separator())

    let newWtItem = NSMenuItem(title: L("New worktree"),
                               action: #selector(ACAppDelegate.newWorktreeAction(_:)),
                               keyEquivalent: "g")
    newWtItem.keyEquivalentModifierMask = [.command, .shift]
    newWtItem.target = delegate
    wsMenu.addItem(newWtItem)

    let mergeWtItem = NSMenuItem(title: L("Merge worktree"),
                                 action: #selector(ACAppDelegate.mergeWorktreeAction(_:)),
                                 keyEquivalent: "m")
    mergeWtItem.keyEquivalentModifierMask = [.command, .shift]
    mergeWtItem.target = delegate
    wsMenu.addItem(mergeWtItem)

    let attachTermItem = NSMenuItem(title: L("Attach terminal"),
                                    action: #selector(ACAppDelegate.attachTerminalAction(_:)),
                                    keyEquivalent: "")
    attachTermItem.target = delegate
    wsMenu.addItem(attachTermItem)

    let discardWtItem = NSMenuItem(title: L("Discard worktree"),
                                   action: #selector(ACAppDelegate.discardWorktreeAction(_:)),
                                   keyEquivalent: "")
    discardWtItem.target = delegate
    wsMenu.addItem(discardWtItem)

    // Edit menu — without these items, the responder chain has no
    // Cut/Copy/Paste/Select-All hooks and ⌘V silently fails inside
    // text fields (SecureField especially). Standard idioms; targets
    // are nil so they go to first responder.
    let editMenuItem = NSMenuItem()
    main.addItem(editMenuItem)
    let editMenu = NSMenu(title: L("Edit"))
    editMenuItem.submenu = editMenu
    editMenu.addItem(withTitle: L("Undo"),
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
    let redoItem = NSMenuItem(title: L("Redo"),
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redoItem)
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: L("Cut"),
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
    editMenu.addItem(withTitle: L("Copy"),
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
    editMenu.addItem(withTitle: L("Paste"),
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
    editMenu.addItem(withTitle: L("Select All"),
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

    let windowMenuItem = NSMenuItem()
    main.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: L("Window"))
    windowMenuItem.submenu = windowMenu
    windowMenu.addItem(withTitle: L("Minimize"),
                       action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    windowMenu.addItem(withTitle: L("Close"),
                       action: #selector(NSWindow.performClose(_:)),
                       keyEquivalent: "w")
    windowMenu.addItem(NSMenuItem.separator())
    let pickerItem = NSMenuItem(title: L("Workspace Manager"),
                                action: #selector(ACAppDelegate.openProfileManagerAction(_:)),
                                keyEquivalent: "0")
    pickerItem.target = delegate
    windowMenu.addItem(pickerItem)
    let inspectorItem = NSMenuItem(title: L("Trace Inspector…"),
                                   action: #selector(ACAppDelegate.openTraceInspectorAction(_:)),
                                   keyEquivalent: "i")
    inspectorItem.keyEquivalentModifierMask = [.command, .shift]
    inspectorItem.target = delegate
    windowMenu.addItem(inspectorItem)

    let metricsItem = NSMenuItem(title: L("Inference Metrics…"),
                                 action: #selector(ACAppDelegate.openInferenceMetricsAction(_:)),
                                 keyEquivalent: "")
    metricsItem.target = delegate
    windowMenu.addItem(metricsItem)

    let approvalsItem = NSMenuItem(title: L("Credential Approvals…"),
                                   action: #selector(ACAppDelegate.openCredentialApprovalsAction(_:)),
                                   keyEquivalent: "")
    approvalsItem.target = delegate
    windowMenu.addItem(approvalsItem)

    let supplyChainLogItem = NSMenuItem(title: L("Security Log…"),
                                        action: #selector(ACAppDelegate.openSupplyChainLogAction(_:)),
                                        keyEquivalent: "")
    supplyChainLogItem.target = delegate
    windowMenu.addItem(supplyChainLogItem)

    let inferenceLogItem = NSMenuItem(title: L("Inference Engine Log…"),
                                      action: #selector(ACAppDelegate.openInferenceLogAction(_:)),
                                      keyEquivalent: "")
    inferenceLogItem.target = delegate
    windowMenu.addItem(inferenceLogItem)
    // The bromure.io Enrollment item is added to the *app* menu (next
    // to Check for Updates…) rather than here — see
    // `ACAppDelegate.installEnrollmentMenuItem(into:)`, called from
    // applicationDidFinishLaunching once the updater item exists.

    // Hand the menu to NSApp so AppKit auto-appends entries for every
    // titled, non-excluded window. Session windows already get
    // meaningful titles (claude / codex / vim / bash / etc.) so they
    // appear here as the user opens them — Picker / Trace Inspector /
    // session windows all routable from one place.
    NSApp.windowsMenu = windowMenu
    return main
}

/// A running VM session, owned by `ACAppDelegate.runningSessions` and keyed
/// by profile id. Decouples VM lifetime from any window: a session keeps
/// running while no window is attached (the persistent-agent / "tmux server"
/// model). The attached window, when present, lives in `profileWindows[id]`.
@MainActor
final class RunningSession {
    let profileID: Profile.ID
    /// Live profile copy; kept in sync when the user saves the editor.
    var profile: Profile
    /// The VM. Strong owner — this is what keeps the VZVirtualMachine alive
    /// independent of any window.
    var sandbox: UbuntuSandboxVM
    /// When the VM booted — surfaced as uptime in `vm ls`.
    let startedAt: Date
    /// Last tab snapshot, captured on detach so a reattaching window can
    /// rebuild its bar against the kittys still running inside the guest.
    var lastTabsSnapshot: SessionDisk.TabsState?
    /// Last IP reported by the guest, mirrored here so a reattaching (or
    /// headless) session can render it without a window.
    var lastIP: String?
    /// The guest's tmux window list (tabs), mirrored from the roster so
    /// `vm ls` / the API / SSH can show tabs (incl. worktree metadata) even
    /// while the session is detached.
    var tabs: [GuestTab] = []
    /// Fusion engaged state, mirrored from the engine so a reattaching
    /// window restores the toolbar toggle correctly.
    var fusionEngaged: Bool = false
    /// Listening sockets from the guest's ports loop, mirrored here so the
    /// `/vms` record (CLI/TUI) can show them even while detached.
    var listeningPorts: [ListeningPort] = []
    /// True once an explicit stop is in flight, so the VM-stopped callback
    /// doesn't double-run teardown.
    var stopping: Bool = false
    /// Set when the guest signalled a reboot (its `reboot-intent` marker). Makes
    /// the VM-stopped callback relaunch a fresh VM instead of tearing the
    /// session down — the detached-session (window-less) counterpart of the
    /// pane's `rebootRequested`.
    var rebootRequested: Bool = false
    /// VZ restarts a guest-initiated `reboot` *in place* (no guestDidStop), so
    /// the way to know the reboot finished is the roster dipping EMPTY (tmux
    /// died going down / not yet up on the second boot) and then coming back.
    /// This records the dip; the non-empty roster after it clears both flags.
    var sawRebootDip: Bool = false
    /// Set once this session has snapshotted its disk (on first boot-ready), so
    /// the repeated tab-roster callbacks only checkpoint once per boot.
    var didCheckpoint: Bool = false
    /// Set when this boot migrated the home into the ext4 image. The boot's
    /// dual-attach (virtiofs + image) VZ config won't be rebuilt next launch,
    /// so a suspend snapshot could never restore — close-time suspend is
    /// coerced to a clean shutdown instead.
    var homeJustMigrated: Bool = false

    init(profileID: Profile.ID, profile: Profile, sandbox: UbuntuSandboxVM) {
        self.profileID = profileID
        self.profile = profile
        self.sandbox = sandbox
        self.startedAt = Date()
    }
}

/// App delegate for `bromure-ac run`. Hosts the profile picker, the
/// create-profile wizard, and (once a profile launches) the
/// VZVirtualMachineView for that session.
@MainActor
final class ACAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let imageManager: UbuntuImageManager
    let store = ProfileStore()
    var profiles: [Profile] = [] {
        didSet {
            // Single funnel: every assignment to `profiles` (load,
            // save, delete, restore) flows through here, so the
            // private-profile set on the cloud emitter and any open
            // session window's streaming indicator stay in lockstep
            // with the latest store state.
            refreshStreamingState()
        }
    }

    /// Snapshot of Terminal.app's default profile captured at app launch.
    /// Cached so changes the user makes to Terminal.app while AC is
    /// running don't surprise them mid-session.
    let terminalDefaults: TerminalAppDefaults = TerminalAppDefaults.load()

    /// Internal so the AppleScript bridge can read window IDs.
    var mainWindow: NSWindow?
    var editorWindow: NSWindow?
    private var sshWindow: NSWindow?
    private var editorEditingProfile: Profile?  // nil = creating

    /// One *attached* window per profile. Each window holds N tabs, all
    /// rendering the same VM. Note this is only the windows currently on
    /// screen — a running VM with no window lives in `runningSessions`.
    ///
    /// Holds only *popped-out* single-VM windows now; panes shown in the
    /// shared `unifiedWindow` are tracked by `panes` instead. Most lookups go
    /// through `pane(for:)`, which spans both hosts.
    private var profileWindows: [Profile.ID: TabbedSessionWindow] = [:]

    /// The shared multi-VM window (unpeel-style: a source-list of every running
    /// VM with its tabs nested, and one framebuffer stage). Created lazily on
    /// the first non-detached launch. Popped-out VMs leave it for their own
    /// `TabbedSessionWindow`.
    var unifiedWindow: UnifiedSessionWindow?

    /// Every `SessionPane` currently displayed somewhere — in `unifiedWindow`
    /// or a popped-out `profileWindows` entry. This is the dispatch target for
    /// guest events (tab list, IP, shortcuts, tint), so it works regardless of
    /// which window draws the pane. nil for a detached/headless session.
    private var panes: [Profile.ID: SessionPane] = [:]

    /// Per-VM auto-clear timers for the `thinking` animation (re-armed on each
    /// model conversation request, fires a few seconds after the last one).
    private var thinkingClearTasks: [Profile.ID: Task<Void, Never>] = [:]

    /// The pane currently showing `id`'s VM, in whichever window hosts it.
    func pane(for id: Profile.ID) -> SessionPane? { panes[id] }

    /// Register a pane as the live UI surface for its profile. Called by every
    /// host (the unified window and popped-out windows) when it starts drawing
    /// a pane.
    func registerPane(_ pane: SessionPane) {
        panes[pane.profile.id] = pane
    }

    /// Drop a pane from the dispatch registry — but only if it's still the
    /// registered one (a re-host may have already replaced it).
    func unregisterPane(_ id: Profile.ID, ifMatches pane: SessionPane? = nil) {
        if let pane, panes[id] !== pane { return }
        guard let departing = panes.removeValue(forKey: id) else { return }
        // Every path through here discards the pane's UI for good (detach,
        // VM stopped, popped-out window closed, failed start) — retire its
        // native terminal surfaces NOW, while we still can. A surface view
        // that deallocates without retire() leaks its libghostty surface,
        // whose renderer thread keeps running against the freed NSView: the
        // "deallocated without retire()" breadcrumb, and a wedge-on-quit
        // when those zombie renderers race AppKit's window teardown.
        // Idempotent — panes that already retired (close action, reboot)
        // no-op here.
        departing.retireNativeTerminals()
    }

    /// True when the profile has a visible UI surface (a hosted pane), whether
    /// in the unified window or a popped-out one. Replaces the old
    /// `profileWindows[id] != nil` "is it on screen" check.
    func isAttached(_ id: Profile.ID) -> Bool { panes[id] != nil }

    /// The window currently drawing `id`'s pane (unified or popped-out), if any.
    func hostWindow(for id: Profile.ID) -> NSWindow? {
        panes[id]?.host?.paneHostWindow
    }

    /// Lazily build the shared unified (multi-VM) window.
    func ensureUnifiedWindow() -> UnifiedSessionWindow {
        if let w = unifiedWindow { return w }
        let w = UnifiedSessionWindow(acDelegate: self)
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        unifiedWindow = w
        return w
    }

    /// Bring the profile's host window forward and select its pane.
    func revealSession(_ id: Profile.ID) {
        guard let pane = panes[id], let host = pane.host?.paneHostWindow else { return }
        (host as? UnifiedSessionWindow)?.select(profileID: id)
        NSApp.setActivationPolicy(.regular)
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Detach a profile's pane to headless — the VM keeps running, the UI goes
    /// away. Snapshots the tab bar so a later reattach rebuilds it. This is the
    /// "close the window but keep the agent" path of the persistent-agent model.
    func detachSession(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        if runningSessions[id] != nil {
            runningSessions[id]?.lastTabsSnapshot = pane.snapshotTabs()
        }
        pane.sandbox = nil
        if let unified = pane.host as? UnifiedSessionWindow {
            unified.removePane(id)
        } else if let win = profileWindows[id] {
            profileWindows.removeValue(forKey: id)
            win.orderOut(nil)
        }
        unregisterPane(id, ifMatches: pane)
        refreshSidebar()
        updateStatusMenu()
        updateActivationPolicy()
    }

    /// Close a VM from the sidebar's × / last-tab close: resolve the profile's
    /// close action (prompting for `.ask`) and either detach (background) or
    /// stop the VM (suspend / shutdown).
    func closeVMFromSidebar(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        let pref = pane.profile.closeAction
        let action: Profile.CloseAction
        if pref == .ask {
            guard let chosen = promptCloseAction(forName: pane.profile.name) else { return }
            action = chosen
        } else {
            action = pref
        }
        switch action {
        case .background:
            detachSession(id)
        case .suspend, .shutdown:
            requestStopSession(id, action: action)
        case .ask:
            break
        }
    }

    /// Debug: render the unified window's content to a PNG (the app drawing
    /// itself — no Screen Recording permission needed) and dump subview frames.
    /// Lets the layout be verified headlessly.
    func debugRenderUnifiedWindow(to path: String) -> [String: Any] {
        debugRenderWindow(unifiedWindow, to: path)
    }

    func debugRenderWindow(_ win: NSWindow?, to path: String) -> [String: Any] {
        guard let win, let contentView = win.contentView else {
            return ["error": "no such window"]
        }
        // Render the whole window frame view (incl. titlebar + toolbar), not just
        // the content area, so the toolbar controls are captured too.
        let content = contentView.superview ?? contentView
        func frameDict(_ v: NSView) -> [String: Any] {
            ["x": Int(v.frame.minX), "y": Int(v.frame.minY),
             "w": Int(v.frame.width), "h": Int(v.frame.height)]
        }
        var dump: [String: Any] = [
            "windowVisible": win.isVisible,
            "windowFrame": ["w": Int(win.frame.width), "h": Int(win.frame.height)],
            "content": frameDict(content),
            "subviews": content.subviews.map { sv -> [String: Any] in
                var d = frameDict(sv)
                d["class"] = String(describing: type(of: sv))
                return d
            },
        ]
        let bounds = content.bounds
        if bounds.width > 0, bounds.height > 0,
           let rep = content.bitmapImageRepForCachingDisplay(in: bounds) {
            content.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                dump["png"] = path
                dump["pngBytes"] = data.count
            }
        }
        return dump
    }

    /// AppleScript bridge: sessions currently on screen (hosted pane whose
    /// window is visible), spanning the unified window + any pop-outs.
    func scriptVisibleSessions() -> [(profileID: UUID, name: String, windowID: Int, visible: Bool)] {
        runningSessions.values.compactMap { s in
            guard let host = hostWindow(for: s.profileID), host.isVisible else { return nil }
            return (s.profileID, s.profile.name, host.windowNumber, true)
        }
    }

    /// AppleScript bridge: close the on-screen session for a profile. Returns
    /// false when nothing is shown for it.
    @discardableResult
    func scriptCloseSession(_ id: Profile.ID) -> Bool {
        guard isAttached(id) else { return false }
        closeVMFromSidebar(id)
        return true
    }

    /// File browser opened from the unified window's header (per selected VM).
    func openFileBrowserForUnified(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        openFileBrowser(profile: pane.profile)
    }

    /// Boot (or focus) the profile with this id — wired to the dropdown.
    func startProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        launch(profile)
    }

    /// Picker "Stop": power the VM down, honoring `.shutdown` but mapping the
    /// keep-running actions (`.background`/`.ask`) to `.suspend` so Stop always
    /// actually stops.
    func stopProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let action: Profile.CloseAction = profile.closeAction == .shutdown ? .shutdown : .suspend
        requestStopSession(id, action: action)
    }

    /// Menu "Shutdown": always power the VM off, regardless of the close-action
    /// default (which is what made the old "Stop" ambiguous). Confirmed first —
    /// it stops running processes (unlike Suspend, which is recoverable).
    func shutdownProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }),
              confirmDisruptiveLifecycle(verb: "Shut Down", profile: profile,
                body: "Powers off the VM and stops everything running inside it. The system disk is kept; in-progress work in running processes is lost.")
        else { return }
        requestStopSession(id, action: .shutdown)
    }

    /// Menu "Suspend": always save RAM state to disk, regardless of the default.
    /// No confirmation — it's recoverable (resume picks up where you left off).
    func suspendProfile(_ id: Profile.ID) {
        requestStopSession(id, action: .suspend)
    }

    /// Menu "Reboot": power off (clearing saved state) then boot fresh. Confirmed.
    func restartProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }),
              confirmDisruptiveLifecycle(verb: "Reboot", profile: profile,
                body: "Powers the VM off and boots it fresh. Everything running inside it is stopped.")
        else { return }
        Task { @MainActor in
            if runningSessions[id] != nil {
                await stopSession(id, action: .shutdown)
            }
            launch(profile)
        }
    }

    /// Modal confirmation for a disruptive lifecycle action (Shut Down / Reboot)
    /// that stops the guest. Returns true if the user confirmed.
    private func confirmDisruptiveLifecycle(verb: String, profile: Profile, body: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(verb) “\(profile.name)”?"
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Picker "Connect/Show": surface a running VM — attaches a window if it's
    /// detached, or brings the existing one to the front.
    func connectProfile(_ id: Profile.ID) {
        guard let session = runningSessions[id] else { return }
        attachWindow(to: session)
    }

    /// Disk + uptime for the workspace VM dashboard. Disk sizes come from the
    /// profile's disk.img (allocated on-disk vs the image's full capacity);
    /// `startedAt` from the running session (nil when off).
    /// The saved profile for an id — works whether or not the VM is running, so
    /// the dashboard can render an off/suspended workspace's config.
    func profile(for id: Profile.ID) -> Profile? { profiles.first { $0.id == id } }

    func vmDashboardData(for id: Profile.ID) -> (diskAllocated: Int64, diskCapacity: Int64, startedAt: Date?) {
        var alloc: Int64 = 0, cap: Int64 = 0
        if let profile = profiles.first(where: { $0.id == id }),
           let rv = try? store.diskURL(for: profile)
               .resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            alloc = Int64(rv.totalFileAllocatedSize ?? 0)
            cap = Int64(rv.fileSize ?? 0)
        }
        return (alloc, cap, runningSessions[id]?.startedAt)
    }

    // MARK: - Unified window source list

    /// Rebuild the unified window's profile list (all profiles + run state).
    /// Replaces the old picker render — called wherever the profile set or a
    /// session's state changes. No-op until the unified window exists.
    func refreshSidebar() {
        guard let w = unifiedWindow else { return }
        w.listModel.profileRows = profiles.map { p in
            SessionListModel.ProfileRow(
                id: p.id,
                name: p.name,
                accentHex: p.color.hexInUI,
                state: runState(for: p),
                compromised: SessionDisk.isCompromised(profile: p, store: store))
        }
    }

    /// Coarse run state for a profile, for the source-list badge: a live VM is
    /// running/booting; otherwise a saved snapshot on disk means suspended,
    /// else it's off.
    private func runState(for profile: Profile) -> SessionListModel.RunState {
        if let session = runningSessions[profile.id] {
            switch session.sandbox.state {
            case .running:            return .running
            case .starting, .created: return .booting
            case .stopped, .error:    break   // fall through to the disk check
            }
        }
        let disk = SessionDisk(profile: profile, store: store,
                               baseDiskURL: imageManager.baseDiskURL)
        return disk.hasSavedState ? .suspended : .off
    }

    // Id-based wrappers so the sidebar's ⋯ menu can drive the Profile-typed
    // handlers without holding the Profile itself.
    func sidebarEditProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { openEditorWindow(editing: p) }
    }
    func sidebarDuplicateProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { duplicateProfile(p) }
    }
    func sidebarResetProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { resetProfile(p) }
    }
    func sidebarDeleteProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { deleteProfile(p) }
    }

    /// The MITM proxy saw a model *conversation* request for this VM. The proxy
    /// can't attribute traffic to a specific tab, so this is the per-VM fallback
    /// for the agents WITHOUT per-tab hooks (Codex/Grok): flip their tabs to
    /// .working and re-arm a timer to drop them back to .done. Claude tabs are
    /// left to their own per-window hooks (accurate per tab), so a Claude call
    /// never flips a sibling Codex tab.
    func noteAgentActivity(_ id: Profile.ID) {
        setNonClaudeAgentTabs(id, .working)
        thinkingClearTasks[id]?.cancel()
        thinkingClearTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.setNonClaudeAgentTabs(id, .done)   // only tabs still .working
            self?.thinkingClearTasks[id] = nil
        }
    }

    /// Apply `status` to every NON-Claude agent tab of a VM (the proxy fallback).
    /// A .done never stomps a tab that's mid-.working elsewhere would — but here
    /// .done only lands on tabs still marked .working (idle transition).
    private func setNonClaudeAgentTabs(_ id: Profile.ID, _ status: AgentStatus) {
        guard let pane = pane(for: id) else { return }
        for tab in pane.model.tabs {
            guard let kind = BromureIcons.agentKind(forLabel: tab.shownLabel),
                  kind != "claude" else { continue }
            if status == .done && tab.agentStatus != .working { continue }
            tab.agentStatus = status
        }
    }

    /// Per-tab status from a Claude hook (keyed by the tmux window index the
    /// hook reported). Authoritative for that tab — no timer, since the Stop
    /// hook delivers the terminal state explicitly.
    func setTabAgentStatus(_ id: Profile.ID, index: Int, _ status: AgentStatus) {
        guard let tab = pane(for: id)?.model.tabs.first(where: { $0.index == index }) else { return }
        tab.agentStatus = status
        // A finished Claude tab may be an automation run — the engine saves
        // its transcript and closes the tab if so.
        if status == .done {
            scheduledAutomationEngine.agentFinished(
                profileID: id, worktreeBranch: tab.worktreeBranch)
        }
    }

    /// Pop a VM out of the unified window into its own standalone window. The
    /// pane keeps the same VM (no teardown); it just changes host. Implemented
    /// in the pop-out phase.
    func popOutVM(_ id: Profile.ID) {
        guard let pane = panes[id], pane.host is UnifiedSessionWindow else { return }
        // Move the pane's view out of the unified window first (keeps the VM +
        // dispatch registration; just unmounts the container view).
        unifiedWindow?.removePane(id)
        let win = TabbedSessionWindow(adopting: pane, acDelegate: self)
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false
        profileWindows[id] = win
        registerPane(pane)   // host changed; keep dispatch pointed at this pane
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }

    /// Re-dock a popped-out VM back into the unified window.
    func redockVM(_ id: Profile.ID) {
        guard let win = profileWindows[id] else { return }
        let pane = win.pane
        profileWindows.removeValue(forKey: id)
        win.releasePaneForRedock()
        win.close()
        let unified = ensureUnifiedWindow()
        unified.addPane(pane)
        NSApp.setActivationPolicy(.regular)
        unified.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }

    /// VM sessions that are *running*, keyed by profile id — the canonical
    /// owner of each `UbuntuSandboxVM`. Distinct from `profileWindows`
    /// (only the *attached* windows): a session can run with no window
    /// attached (detached / headless). The persistent-agent model — where
    /// VMs survive the GUI being closed — hangs off this split.
    var runningSessions: [Profile.ID: RunningSession] = [:]

    /// Scheduled automations (sidebar "Automations"): recurring, unattended
    /// agent runs. The store persists next to the profiles dir; the engine
    /// ticks on the main run loop and fires due automations through the same
    /// outbox path the CLI/SSH surface uses.
    let scheduledAutomationStore = ScheduledAutomationStore()
    private(set) lazy var scheduledAutomationEngine =
        ScheduledAutomationEngine(store: scheduledAutomationStore, delegate: self)

    /// Profiles created with `vm run --rm`: deleted (profile + disk) when their
    /// VM stops, mirroring `docker run --rm`.
    private var ephemeralProfiles: Set<Profile.ID> = []

    /// The running VM for a profile, or nil if it isn't running. The control
    /// plane (and any window-less caller) resolves a profile's VM through here.
    func sandbox(for id: Profile.ID) -> UbuntuSandboxVM? {
        runningSessions[id]?.sandbox
    }

    /// Register (or update) the running session for a profile. The registry
    /// is the strong owner that keeps the VM alive independent of any window.
    @discardableResult
    func registerSession(_ sandbox: UbuntuSandboxVM, profile: Profile) -> RunningSession {
        if let existing = runningSessions[profile.id] {
            existing.sandbox = sandbox
            existing.profile = profile
            return existing
        }
        let session = RunningSession(profileID: profile.id, profile: profile, sandbox: sandbox)
        runningSessions[profile.id] = session
        updateStatusMenu()
        // Boot completes asynchronously after the launch path's initial render,
        // so refresh the picker now that the VM is actually running (Start →
        // Stop/Restart/Connect).
        refreshSidebar()
        return session
    }

    /// Drop the registry's strong reference to a profile's VM. The VM
    /// deallocates once any in-flight stop/suspend task also releases it
    /// (its `deinit` then detaches the vmnet switch port).
    func unregisterSession(_ id: Profile.ID) {
        runningSessions.removeValue(forKey: id)
        updateStatusMenu()
    }

    /// NSEvent monitor that intercepts ⌘T / ⌘W / ⌘1-9 at the
    /// application level — before the responder chain, before the
    /// VZ view's keyDown forwards them to the guest. Returning nil
    /// from the handler is what consumes the event; see the closure
    /// in applicationDidFinishLaunching for why we don't `?? event`.
    private var keyMonitor: Any?

    /// Progress model for the in-app `init` flow (first-time setup or
    /// version-bump rebuild).
    private let initProgress = InitProgressModel()

    /// Retained handle to the in-flight base-image build Task. Used to
    /// cancel cleanly when the user confirms a close mid-install —
    /// otherwise the Task keeps pushing model updates after the window
    /// is gone and the autorelease pool over-releases on the next tick.
    private var installTask: Task<Void, Never>?
    private var ssoRefreshTasks: [UUID: Task<Void, Never>] = [:]

    /// Strong references to the dispatch sources catching abnormal-
    /// exit signals. Without retaining these the sources deallocate
    /// and we silently drop back to the default disposition (= die).
    private var cleanupSignalSources: [DispatchSourceSignal] = []

    /// Optional HTTP automation server. Started in applicationDidFinishLaunching
    /// when `automation.enabled` (UserDefaults) is true. Defaults to OFF —
    /// the user enables it explicitly via Bromure → Preferences →
    /// Automation, or via `defaults write io.bromure.agentic-coding
    /// automation.enabled -bool true`. Tests/ac-e2e.mjs sets this before
    /// launching the app.
    private var automationServer: ACAutomationServer?
    /// Always-on owner-only Unix control socket for the `bromure-ac` CLI.
    private var controlServer: ACAutomationServer?

    /// Menu-bar item. The only UI surface once every window closes and the
    /// app demotes to `.accessory` — lists running VMs and offers Quit so a
    /// fully-detached agent stays reachable.
    private var statusItem: NSStatusItem?

    /// Process-lifetime MITM engine. One instance per app run, holds
    /// the CA + per-profile token swap maps + ssh-agent keystore. Lazy
    /// because CA generation hits disk on first access.
    lazy var mitmEngine: MitmEngine? = {
        do {
            let e = try MitmEngine()
            // The proxy's conversation-request signal drives the sidebar's
            // animated "thinking" dots.
            e.traceStore.onConversationActivity = { [weak self] pid in
                self?.noteAgentActivity(pid)
            }
            return e
        }
        catch {
            FileHandle.standardError.write(Data(
                "[mitm] engine init failed: \(error) — sessions will run without proxy\n".utf8))
            return nil
        }
    }()

    /// SPM-resource-bundle path to the in-VM bridge script. Resolved
    /// once and copied into each session's meta share.
    lazy var bridgeScriptURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-vm-bridge",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the AWS `credential_process` helper.
    /// Shipped to /mnt/bromure-meta and referenced from the per-profile
    /// ~/.aws/config so the SDK pulls JSON creds from the host on demand.
    lazy var awsCredsHelperURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-aws-creds",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the Claude subscription-token agent.
    /// Dropped in the meta share, launched from xinitrc, talks vsock
    /// to host port 8446 (`SubscriptionTokenBridge`).
    lazy var claudeTokenAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/claude-token-agent",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the Codex / ChatGPT
    /// subscription-token agent. Vsock port 8447, reads/writes
    /// ~/.codex/auth.json.
    lazy var codexTokenAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/codex-token-agent",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the debug shell agent (vsock 5800).
    /// Dropped in the meta share and launched from xinitrc when the host
    /// runs with BROMURE_DEBUG_CLAUDE set — keeps the surface invisible
    /// in regular user sessions while powering the AutomationServer's
    /// /sessions/{id}/exec endpoint for tests.
    /// Internal (not private): the registration flow stages it too.
    lazy var shellAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/shell-agent",
                             withExtension: "py")
    }()

    /// The consolidated guest daemon (phase 3): creates the tmux session,
    /// runs the roster/command loops and every absorbed vsock service.
    /// Runs from the meta share under systemd; re-staging a changed copy
    /// hot-upgrades it (self-hash watcher → exit(0) → Restart=always).
    /// Internal (not private): the registration flow stages it too — without
    /// agentd the scratch VM has no tmux session, no roster, and no vsock
    /// shell channel for the native terminal to attach through.
    lazy var agentdURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-agentd",
                             withExtension: "py")
    }()

    /// Loopback-callback relay (vsock 5010). Shipped in the meta share and
    /// started by bromure-agentd; lets OAuth logins inside the VM receive
    /// their 127.0.0.1 redirect callback from the host browser.
    lazy var loopbackRelayAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/loopback-relay-agent",
                             withExtension: "py")
    }()

    /// Live host→guest loopback forwarders, one per detected OAuth login.
    /// They auto-expire (5 min); we also prune stopped ones on each new login.
    var loopbackForwarders: [LoopbackCallbackForwarder] = []
    /// In-flight "Register with Claude" throwaway session, if any. Held so the
    /// window-close handler can route to its teardown instead of the normal
    /// session cleanup, and to guard against launching two at once.
    var claudeRegistration: ClaudeRegistrationState?

    /// If `url` is an OAuth authorize URL whose `redirect_uri` is a loopback
    /// callback (`http://127.0.0.1:<port>` or `localhost`), return that port —
    /// the signal to bridge the host's loopback into the guest. Otherwise nil.
    /// Resolve a profile's Guardrails policy into the runtime config the MITM
    /// enforces — the kube mode plus the concrete kube API hostnames pulled
    /// from the profile's kubeconfigs.
    /// Build the per-session Fusion config from a profile, or nil if the
    /// profile isn't fusion-configurable (<2 usable providers). Legs = the
    /// selected set intersected with usable providers (falling back to all
    /// usable if the selection is too small); judge falls back to the first
    /// usable provider + engine default model.
    /// Push the profile's routing mode + hybrid policy knobs into the MITM
    /// engine at session launch (vLLM.md §4). The model label (catalog id
    /// or repo) is what the `served-by` trace marker shows.
    func applyRouting(_ engine: MitmEngine, for profile: Profile) {
        // `effectiveModelRouting`, not the raw flag: a pure-local route with no
        // `.local` agent (e.g. a subscription Claude with a leftover model
        // selected) must NOT reroute the agent's real cloud traffic into the
        // on-host engine.
        engine.setRouting(profile.effectiveModelRouting,
                          modelLabel: profile.activeModelID ?? "default",
                          hybrid: HybridConfig(profile: profile),
                          localCloudHosts: profile.localProviderCloudHosts,
                          for: profile.id)
    }

    /// Start (or switch) the on-host vllm-mlx engine for a session that
    /// needs local inference — any tool in `.local` mode, or Local/Hybrid
    /// routing. Runs in the background so it warms while the VM boots; the
    /// guest reaches it once ready via the vsock-8446 bridge. No-op when the
    /// profile needs no local model. (Single-engine phase: one model.)
    @MainActor func startLocalEngineIfNeeded(for profile: Profile) {
        let ids = profile.distinctLocalModelIDs
        guard !ids.isEmpty else { return }
        // Resolve each selected model to a registry entry (name = repo, so
        // existing model env/config keeps working). estMemGB = its weight
        // footprint for the engine's LRU budget.
        let models: [InferenceModel] = ids.map { id in
            let m = CatalogStore.shared.resolve(id)
            let repo = m?.repo ?? id
            let est = Int((m?.downloadGB ?? 8).rounded(.up))
            return InferenceModel(name: repo, repo: repo, estMemGB: est,
                                  toolParser: m?.toolParser ?? "auto",
                                  reasoningParser: m?.reasoningParser)
        }
        // Budget for parallel models: most of unified memory, leaving room
        // for the OS + the VMs. vllm-mlx evicts idle models LRU under this.
        let budget = max(8, HostMemory.unifiedMemoryGB() - 16)
        let pid = profile.id
        let label = models.first.map { CatalogStore.shared.resolve($0.repo)?.name ?? $0.repo } ?? ""
        // Map the `bromure-local` sentinel → this workspace's active model so the
        // guest agents resolve to it without a restart. Set synchronously (before
        // the engine warms) so a request that races the load still routes right.
        if let activeID = profile.activeModelID,
           let activeRepo = CatalogStore.shared.resolve(activeID)?.repo {
            InferenceRepairProxy.shared.setActiveModel(pid, repo: activeRepo)
        }
        pane(for: pid)?.model.engineStatus = .starting("Starting local engine…")
        Task.detached(priority: .userInitiated) {
            do {
                // Register this workspace's models; the engine serves the UNION
                // of all open workspaces. If an engine is already up for another
                // workspace, this adds our model to it (hot reconfigure) instead
                // of restarting and dropping the others.
                try await InferenceService.shared.setWorkspaceModels(
                    pid, models, memoryBudgetGB: budget)
                await MainActor.run { self.pane(for: pid)?.model.engineStatus = .ready(label) }
                InferenceLog.shared.record(
                    "[inference] engine serving \(models.map(\.repo).joined(separator: ", "))")
            } catch {
                await MainActor.run { self.pane(for: pid)?.model.engineStatus = .failed("\(error)") }
                InferenceLog.shared.record(
                    "[inference] engine start failed: \(error) — see the Inference Engine Log above for the reason")
            }
        }
    }

    func makeFusionConfig(for profile: Profile) -> Fusion.Config? {
        guard profile.fusionConfigurable else { return nil }
        let usable = profile.fusionUsableProviders   // cloud providers with creds
        var legs = Profile.Tool.allCases.filter {
            profile.fusionLegs.contains($0) && usable.contains($0)
        }
        // The local Fusion leg (a model served by the on-host engine).
        let localLegModel: String? = {
            guard let id = profile.fusionLocalLeg, !id.isEmpty else { return nil }
            return CatalogStore.shared.resolve(id)?.repo ?? id
        }()
        // Need ≥2 drafts to fuse (cloud legs + the local leg). If the user
        // under-specified, default to fusing every usable cloud provider.
        if legs.count + (localLegModel != nil ? 1 : 0) < 2 { legs = usable }

        var authModes: [Profile.Tool: Profile.AuthMode] = [:]
        for spec in profile.allToolSpecs { authModes[spec.tool] = spec.authMode }

        // Judge: the local engine, or a chosen cloud provider.
        let judgeLocal = profile.fusionJudgeLocal
        let judgeProvider = (profile.fusionJudgeProvider.flatMap { usable.contains($0) ? $0 : nil })
            ?? usable.first ?? .claude
        let judgeModel: String
        if judgeLocal {
            let id = profile.fusionJudgeModel ?? profile.fusionLocalLeg ?? ""
            judgeModel = CatalogStore.shared.resolve(id)?.repo ?? id
        } else {
            judgeModel = profile.fusionJudgeModel ?? Fusion.defaultJudgeModel
        }

        return Fusion.Config(legs: legs, judgeProvider: judgeProvider,
                             judgeModel: judgeModel, authModes: authModes,
                             legModels: [:], localLegModel: localLegModel, judgeLocal: judgeLocal)
    }

    static func makeGuardrailsConfig(for profile: Profile) -> GuardrailsConfig {
        let kubeHosts = Set(profile.kubeconfigs.compactMap {
            URL(string: $0.serverURL)?.host?.lowercased()
        })
        // Docker registry hosts the profile has creds for. "docker.io" is a
        // user-facing alias for the real Hub endpoints, so expand it.
        var dockerHosts = Set<String>()
        for reg in profile.dockerRegistries {
            let h = reg.host.lowercased()
            if h == "docker.io" || h == "index.docker.io" || h == "registry-1.docker.io" {
                dockerHosts.formUnion(["docker.io", "index.docker.io",
                                       "registry-1.docker.io", "auth.docker.io"])
            } else {
                dockerHosts.insert(h)
            }
        }
        // HTTPS-database guardrails: each configured endpoint contributes its
        // engine + (user-specified) host + per-endpoint mode.
        let databases = profile.httpDatabases.compactMap { db -> GuardrailsConfig.DBGuardrail? in
            let host = db.host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, db.guardrail != .off else { return nil }
            return GuardrailsConfig.DBGuardrail(engine: db.engine, host: host, mode: db.guardrail)
        }
        let g = profile.guardrails
        return GuardrailsConfig(kubernetes: g.kubernetes, kubeHosts: kubeHosts,
                                aws: g.aws,
                                digitalOcean: g.digitalOcean,
                                docker: g.docker, dockerHosts: dockerHosts,
                                github: g.github, gitlab: g.gitlab, bitbucket: g.bitbucket,
                                databases: databases)
    }

    static func loopbackCallbackPort(from url: URL) -> UInt16? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirect = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let rc = URLComponents(string: redirect),
              let host = rc.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              let port = rc.port, port > 0, port <= 65_535 else {
            return nil
        }
        return UInt16(port)
    }

    /// Per-profile shell bridges (vsock 5800), created for every session —
    /// including the registration scratch VM, whose native terminal attaches
    /// through it. Consumed by the AutomationServer's `onGetShellConnection`
    /// callback, `bromure-ac exec`, and `guestExec` (the file-explorer pane).
    var shellBridges: [Profile.ID: ShellBridge] = [:]

    /// Errors from `guestExec`.
    enum GuestExecError: LocalizedError {
        case vmNotRunning
        case connectionFailed
        case commandFailed(exitCode: Int, stderr: String)
        var errorDescription: String? {
            switch self {
            case .vmNotRunning: "The VM isn't running"
            case .connectionFailed: "Couldn't reach the VM's shell agent"
            case .commandFailed(let code, let stderr):
                stderr.isEmpty ? "Command failed (exit \(code))"
                               : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Run a shell command in `profileID`'s guest over the vsock shell channel
    /// and return stdout. Async flavor of the AutomationServer exec route:
    /// same framed protocol and same stale-pool retry, but the blocking socket
    /// IO happens off the main actor, and a non-zero exit throws with stderr.
    /// vsock-only on purpose — keeps working with no virtiofs share mounted
    /// (the future remote-access case), which is why the file explorer uses it.
    func guestExec(profileID: Profile.ID, command: String, timeout: Int = 30) async throws -> String {
        // Wait up to ~3s for a pooled connection (covers boot races) without
        // blocking the main actor.
        var connection: VZVirtioSocketConnection?
        for _ in 0..<30 {
            guard let bridge = shellBridges[profileID] else { throw GuestExecError.vmNotRunning }
            if let c = bridge.dequeueConnection() { connection = c; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // A dequeued connection can be dead without the pool knowing (stale
        // sockets from a previous guest boot). A dead socket fails before the
        // command ever runs, so falling through to the next pooled connection
        // is safe; a mid-stream failure is NOT retried (it may have executed).
        for attempt in 0..<4 {
            guard let conn = connection else { throw GuestExecError.connectionFailed }
            let fd = conn.fileDescriptor
            let outcome = await Task.detached(priority: .userInitiated) {
                ACAutomationServer.executeShellCommand(fd: fd, command: command, timeout: timeout)
            }.value
            withExtendedLifetime(conn) {}   // fd must outlive the exchange
            switch outcome {
            case .success(let result):
                guard result.exitCode == 0 else {
                    throw GuestExecError.commandFailed(exitCode: result.exitCode,
                                                       stderr: result.stderr)
                }
                return result.stdout
            case .deadConnection:
                connection = attempt < 3 ? shellBridges[profileID]?.dequeueConnection() : nil
            case .protocolFailure:
                throw GuestExecError.connectionFailed
            }
        }
        throw GuestExecError.connectionFailed
    }

    /// Run one native file op ({"file": {...}}) in `profileID`'s guest over
    /// the vsock shell channel — the file browser's data plane. Same pooled
    /// connection + stale-retry dance as `guestExec`, but payloads travel as
    /// base64 inside the JSON (no shell, so no 128 KB argv-string cap).
    /// Throws `commandFailed` with the guest's error string when the op
    /// itself failed; returns the raw response dict otherwise.
    func guestFileOp(profileID: Profile.ID, op: [String: Any],
                     timeout: Int = 30) async throws -> [String: Any] {
        var connection: VZVirtioSocketConnection?
        for _ in 0..<30 {
            guard let bridge = shellBridges[profileID] else { throw GuestExecError.vmNotRunning }
            if let c = bridge.dequeueConnection() { connection = c; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for attempt in 0..<4 {
            guard let conn = connection else { throw GuestExecError.connectionFailed }
            let fd = conn.fileDescriptor
            let request: [String: Any] = ["file": op, "timeout": timeout]
            let outcome = await Task.detached(priority: .userInitiated) {
                ACAutomationServer.exchangeJSON(fd: fd, request: request)
            }.value
            withExtendedLifetime(conn) {}   // fd must outlive the exchange
            switch outcome {
            case .success(let obj):
                if let err = obj["error"] as? String {
                    throw GuestExecError.commandFailed(
                        exitCode: obj["exit_code"] as? Int ?? 1, stderr: err)
                }
                return obj
            case .deadConnection:
                connection = attempt < 3 ? shellBridges[profileID]?.dequeueConnection() : nil
            case .protocolFailure:
                throw GuestExecError.connectionFailed
            }
        }
        throw GuestExecError.connectionFailed
    }

    /// Sparkle auto-updater. Retained strongly — if this deallocates,
    /// scheduled update checks stop firing. Initialised in
    /// applicationDidFinishLaunching. Silently no-ops on dev builds where
    /// SUPublicEDKey isn't populated.
    private var updaterController: SPUStandardUpdaterController?


    /// When true the app launches as a background agent: no picker window, just
    /// the control socket + status item + MITM engine. Used by the CLI's
    /// autostart (`bromure-ac run --headless`).
    let headless: Bool

    init(imageManager: UbuntuImageManager, headless: Bool = false) {
        self.imageManager = imageManager
        self.headless = headless
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        profiles = store.loadAll()
        // Menu-bar item: the persistent surface for reattaching / stopping VMs
        // once all windows close and the app demotes to a background agent.
        setupStatusItem()
        // Always-on Unix control socket for the `bromure-ac` CLI (exec / vm …).
        startControlSocket()

        // Persist the in-process DHCP server's leases so a profile's VM — which
        // already has a stable per-profile MAC (MACBindings) — keeps the same IP
        // across agent restarts, as often as the address stays free.
        let acSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
        VMNetSwitch.shared.enablePersistentLeases(
            at: acSupport.appendingPathComponent("dhcp-leases.sqlite"))

        // Offer to install the `bromure-cli` command-line tool (admin prompt).
        // Deferred so the main window appears first; no-op for the headless agent.
        DispatchQueue.main.async { [weak self] in self?.offerCLISymlinkIfNeeded() }

        // Refresh the MLX model catalog from the hosted manifest in the
        // background (vLLM.md §5.1). Non-fatal — falls back to the bundled
        // catalog.json on any network failure, so this never blocks launch.
        // No-op when the `catalog.refreshDisabled` default is set (testing).
        Task.detached(priority: .background) { await CatalogStore.shared.refresh() }

        // Surface any model download a previous crash/kill left half-finished as
        // a resumable entry in the Local Models picker (Bug#2). GUI only.
        if !headless {
            Task { @MainActor in ModelDownloadManager.shared.detectInterrupted() }
        }

        // Reap any vllm-mlx engine orphaned by a previous hard kill before we
        // start our own (it can hold tens of GB of unified memory).
        Task.detached(priority: .background) { InferenceService.reapOrphans() }

        // Keep the login LaunchAgent in sync, then (headless login agent only)
        // boot any profiles flagged "Start at login".
        reconcileBootLaunchAgent()
        DispatchQueue.main.async { [weak self] in self?.bootFlaggedProfilesAtStartup() }

        // Scheduled automations: start the tick loop in every mode (GUI and
        // headless login agent alike) — an automation due while only the
        // background agent is running should still fire. The first tick also
        // routes fires missed while the app was quit through each
        // automation's missed-run policy.
        scheduledAutomationEngine.start()

        // Default SSH key: every new profile inherits this keypair via
        // the user's preferences template. Generate it on first launch
        // (idempotent — `ensureExists` no-ops when the files are
        // already on disk), then make sure the template carries the
        // matching public key so a freshly forked profile shows it in
        // the editor without ticking the "Generate" toggle.
        do {
            try DefaultSSHKey.ensureExists()
            let pub = try DefaultSSHKey.publicKeyText()
            var template = store.loadTemplate()
            if template.sshPublicKey != pub {
                template.sshPublicKey = pub
                try? store.saveTemplate(template)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[ssh] default key bootstrap failed: \(error)\n".utf8))
        }

        // Sparkle: kick off scheduled update checks against the
        // release-agentic-coding appcast (separate channel from the
        // browser product). Started before the menu so the "Check for
        // Updates…" item has a live target.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Re-install the main menu now that updaterController is alive
        // so the menu item built in `makeMainMenu` (called via the Run
        // command, before this delegate ran) gets a fresh copy with the
        // updater wired in.
        if let menu = NSApp.mainMenu, let appMenu = menu.item(at: 0)?.submenu {
            installCheckForUpdatesMenuItem(into: appMenu)
            // Slot the bromure.io enrollment item right under Check for
            // Updates… so admins find both deployment-touching items in
            // the same place. Idempotent and safe even when the updater
            // isn't initialised (dev builds): it falls back to inserting
            // just after About.
            installEnrollmentMenuItem(into: appMenu)
        }

        // Start the bromure.io heartbeat right away if this Mac is
        // enrolled. The first ping fires inside the background task
        // (no extra latency on the launch path), and the periodic
        // schedule keeps `last_seen_at` fresh on the admin UI. No-op
        // when not enrolled.
        BACHeartbeat.shared.start()
        // Per-install egress-IP heartbeat — mirrors the Bromure Web
        // Chromium extension, ticks every 60s against
        // analytics.bromure.io/register-ip so install_ips reflects
        // the Mac's current public IP. Also no-ops when not enrolled.
        BACIPRegister.shared.start()
        // Same lifecycle for the cloud event uploader: stand it up
        // once, the emitter itself short-circuits when there's no
        // install identity. Credential hooks + the LLM extractor can
        // call into it from the moment the proxy starts intercepting.
        if BACEnrollmentStore.load() != nil {
            BACEventEmitter.shared.ensureUploader()
        }
        BACEnrollment.onStateChange = { [weak self] in
            // Restart so a fresh enrollment kicks off heartbeats
            // immediately, and an unenroll stops them.
            BACHeartbeat.shared.stop()
            BACIPRegister.shared.stop()
            if BACEnrollmentStore.load() != nil {
                BACHeartbeat.shared.start()
                BACIPRegister.shared.start()
                BACEventEmitter.shared.ensureUploader()
            } else {
                // Drop any buffered events so the next enrollment
                // starts with a clean slate (different install id,
                // different bearer, possibly different workspace).
                BACEventEmitter.shared.reset()
            }
            self?.refreshEnrollmentMenuTitle()
            // Streaming flag flips on enroll/unenroll; refresh
            // every session window's toolbar indicator.
            self?.refreshStreamingState()
        }

        // Wire signal handlers BEFORE the MITM engine spawns its
        // ssh-agent — otherwise an unlucky signal between spawn and
        // handler install would orphan the child. SIGKILL and jetsam
        // are uncatchable; PrivateSSHAgent.reapOrphans() at the next
        // launch handles those.
        installCleanupSignalHandlers()

        // Force-init the MITM engine so the CA is ready before any
        // session opens (the lazy var would defer this to first launch,
        // adding a perceptible pause on the first session and racing
        // the VM boot path).
        _ = mitmEngine
        if let engine = mitmEngine {
            FileHandle.standardError.write(Data(
                "[mitm] engine ready; CA loaded from \(engine.ca.certificate.subject)\n".utf8))
            // Compromise handler — fired by the swapper's AC-backed
            // outbound scan whenever a fake token leaves the VM bound
            // for a host outside the scope it was minted for. Hops to
            // MainActor to pause the VM and present the alert.
            engine.swapper.setCompromiseHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleCompromise(event)
                }
            }
            // Warm the trace ring from disk so `bromure-ac trace` shows recent
            // history right after the agent starts, not just live traffic.
            engine.traceStore.reload()
        }

        // Headless agent (CLI autostart): no picker window — the control socket
        // + status item are the only surfaces. Everything else (engine, signal
        // handlers, automation, control socket) still runs.
        if !headless {
        // Pick the right initial home: with a base image, the unified window
        // (the source list of every profile — the standalone picker is gone);
        // before the base image exists, the setup window in `mainWindow`.
        if imageManager.hasBaseImage {
            showUnifiedWindowAsHome()
            if profiles.isEmpty { openEditorWindow(editing: nil) }
            // Image-maintenance checks (non-blocking; the user keeps
            // working with the existing base throughout). Refresh the
            // image catalog, then in priority order:
            //   1. Full-image update — the app shipped a newer
            //      imageVersion, or img-catalog.json moved to a new
            //      image version → offer to download the new image.
            //   2. New postinstall steps published since this image was
            //      installed → ask consent, then amend base.img.
            Task { @MainActor in
                self.imageManager.migrateLegacyImageStateIfNeeded()
                let remote = await ImageCatalogStore.shared.refresh()
                let installedMajor = self.imageManager.installedImageVersion
                    .map(UbuntuImageManager.majorVersion(of:))
                let catalogMajor = (remote?.image?.version)
                    .map(UbuntuImageManager.majorVersion(of:))
                // Only a strictly NEWER published version counts — a
                // stale CDN catalog (publish pipeline lagging an app
                // release) must not offer a downgrade. Non-numeric
                // majors fall back to plain inequality.
                let catalogIsNewer: Bool = {
                    guard let cat = catalogMajor, let inst = installedMajor else { return false }
                    if let c = Int(cat), let i = Int(inst) { return c > i }
                    return cat != inst
                }()
                if self.imageManager.baseImageNeedsUpdate || catalogIsNewer {
                    // A full update re-applies every catalog step, so
                    // don't also nag about new steps underneath it.
                    self.promptBaseImageUpdate(
                        catalogVersion: catalogIsNewer ? catalogMajor : nil)
                    return
                }
                let catalog = remote ?? ImageCatalogStore.shared.effective()
                let applied = self.imageManager.loadImageState()?.appliedStepUUIDs ?? []
                let pending = catalog.pendingSteps(appliedUUIDs: applied)
                if !pending.isEmpty {
                    self.promptNewPostinstallSteps(pending)
                }
            }
        } else {
            ensureInstallWindow()
            renderSetup()
            NSApp.activate(ignoringOtherApps: true)
        }
        }   // if !headless

        // ⌘T / ⌘W / ⌘1-9 / ⌘N must run BEFORE VZVirtualMachineView's
        // keyDown forwards them to the guest (where kitty's super+t /
        // super+w mappings would create a kitty-internal tab instead
        // of a host pill, and super+n would reach the agent). A local
        // monitor fires before window /
        // menu / responder-chain dispatch, so this is the earliest
        // hook we have. `interceptKey` returns nil when it has
        // handled the event — propagate that nil so AppKit drops
        // the event. A `?? event` here would silently re-emit the
        // consumed event into normal dispatch, racing the host's
        // performKeyEquivalent against the VZ view's keyDown.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.interceptKey(event)
        }

        startAutomationServerIfNeeded()
        startRemoteAccessIfNeeded()
    }

    // MARK: - Remote access (optional SSH front door)

    /// UserDefaults-backed remote config. Defaults: disabled, port 2222,
    /// bind 0.0.0.0, both auth methods on.
    func remoteAccessConfig() -> RemoteAccessServer.Config {
        let d = UserDefaults.standard
        var c = RemoteAccessServer.Config()
        let p = d.integer(forKey: "remoteAccess.port")
        if p > 0 { c.port = p }
        c.bindAddress = d.string(forKey: "remoteAccess.bindAddress") ?? "0.0.0.0"
        // `object(forKey:) == nil` → key never set → default on.
        c.passwordAuth = d.object(forKey: "remoteAccess.passwordAuth") == nil ? true : d.bool(forKey: "remoteAccess.passwordAuth")
        c.pubkeyAuth = d.object(forKey: "remoteAccess.pubkeyAuth") == nil ? true : d.bool(forKey: "remoteAccess.pubkeyAuth")
        return c
    }

    /// Start the SSH front door iff `remoteAccess.enabled` (default OFF).
    ///
    /// Never while the base image is absent or an install is in flight
    /// (download or local bake): the remote menu exists to create and
    /// launch workspaces, all of which need a settled base.img — a remote
    /// session poking at profiles mid-install would race the image swap.
    /// `startInit`/`startPostinstall` stop the server up front and call
    /// this again from their completion path.
    @MainActor func startRemoteAccessIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "remoteAccess.enabled") else { return }
        guard imageManager.hasBaseImage, installTask == nil else {
            SupplyChainLog.shared.record(
                "[remote] SSH front door deferred until the base image is installed.")
            return
        }
        do {
            try RemoteAccessServer.shared.start(remoteAccessConfig())
            SupplyChainLog.shared.record("[remote] SSH front door started.")
            updateStatusMenu()   // robot menu: reflect the now-running sshd
        } catch {
            SupplyChainLog.shared.record("[remote] start failed: \(error.localizedDescription)")
            // Surface it: remote access is enabled but the listener was refused
            // (firewall / Local Network privacy / port in use). The log alone is
            // invisible; show the decoded reason. (Headless has no GUI for this.)
            if !headless {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Remote access couldn’t start"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @MainActor func stopRemoteAccess() {
        RemoteAccessServer.shared.stop()
        updateStatusMenu()   // robot menu: reflect the stopped sshd
    }

    /// Apply a config change coming from the CLI (`remote …`) or Preferences.
    /// Persists to UserDefaults, then (re)starts or stops sshd. Returns a
    /// status dict (same shape as `remoteAccessStatus`).
    @MainActor func remoteAccessApply(_ spec: [String: Any]) -> [String: Any] {
        let d = UserDefaults.standard
        if let port = spec["port"] as? Int {
            guard port > 0, port < 65536 else { return ["error": "port must be in 1..65535"] }
            guard port >= 1024 else { return ["error": "port must be ≥ 1024 (non-root can't bind privileged ports)"] }
            d.set(port, forKey: "remoteAccess.port")
        }
        if let bind = spec["bindAddress"] as? String, !bind.isEmpty {
            d.set(bind, forKey: "remoteAccess.bindAddress")
        }
        if let pw = spec["passwordAuth"] as? Bool { d.set(pw, forKey: "remoteAccess.passwordAuth") }
        if let pk = spec["pubkeyAuth"] as? Bool { d.set(pk, forKey: "remoteAccess.pubkeyAuth") }

        if let enabled = spec["enabled"] as? Bool {
            let cfg = remoteAccessConfig()
            guard cfg.passwordAuth || cfg.pubkeyAuth else {
                return ["error": "Enable at least one of password / public-key auth."]
            }
            // No SSH while the base image is being installed (or before
            // one exists) — same invariant startRemoteAccessIfNeeded
            // enforces at launch. Refuse instead of deferring silently so
            // the CLI/Preferences caller knows nothing is listening.
            if enabled, installTask != nil || !imageManager.hasBaseImage {
                return ["error": "Base image install in progress (or no image yet) — enable remote access once it completes."]
            }
            d.set(enabled, forKey: "remoteAccess.enabled")
            if enabled {
                do { try RemoteAccessServer.shared.start(cfg) }
                catch { return ["error": error.localizedDescription] }
            } else {
                RemoteAccessServer.shared.stop()
            }
        } else if d.bool(forKey: "remoteAccess.enabled") {
            // No enable/disable in this call but we're on → apply live.
            // (Skipped mid-install — the server is paused then; the
            // post-install resume picks the new config up.)
            if installTask == nil {
                do { try RemoteAccessServer.shared.start(remoteAccessConfig()) }
                catch { return ["error": error.localizedDescription] }
            }
        }
        return remoteAccessStatus()
    }

    /// "<ip>:<port>" a remote client would use: the bound address, or — when
    /// bound to all interfaces (0.0.0.0) — this Mac's primary LAN IPv4.
    @MainActor func remoteReachableAddress() -> String {
        let cfg = remoteAccessConfig()
        let ip = cfg.bindAddress == "0.0.0.0"
            ? (HostNetwork.primaryIPv4() ?? "this Mac's IP") : cfg.bindAddress
        return "\(ip):\(cfg.port)"
    }

    @MainActor func remoteAccessStatus() -> [String: Any] {
        let d = UserDefaults.standard
        let cfg = remoteAccessConfig()
        let server = RemoteAccessServer.shared
        let user = NSUserName()
        let host = cfg.bindAddress == "0.0.0.0"
            ? (HostNetwork.primaryIPv4() ?? "<this-mac-ip>") : cfg.bindAddress
        let keys = server.listAuthorizedKeys().map { k in
            ["type": k.type, "comment": k.comment, "fingerprint": k.fingerprint] as [String: Any]
        }
        return [
            "enabled": d.bool(forKey: "remoteAccess.enabled"),
            "running": server.isRunning,
            "port": cfg.port,
            "bindAddress": cfg.bindAddress,
            "passwordAuth": cfg.passwordAuth,
            "pubkeyAuth": cfg.pubkeyAuth,
            "fingerprint": server.hostKeyFingerprint() ?? "(not generated yet)",
            "user": user,
            "connect": "ssh -p \(cfg.port) \(user)@\(host)",
            "authorizedKeys": keys,
        ]
    }

    @MainActor func remoteAccessAddKey(_ pub: String) -> [String: Any] {
        do {
            try RemoteAccessServer.shared.addAuthorizedKey(pub)
            let added = RemoteAccessServer.shared.listAuthorizedKeys().last
            return ["ok": true, "fingerprint": added?.fingerprint ?? "ok"]
        } catch { return ["error": error.localizedDescription] }
    }

    @MainActor func remoteAccessRemoveKey(_ selector: String) -> [String: Any] {
        do { try RemoteAccessServer.shared.removeAuthorizedKey(selector); return ["ok": true] }
        catch { return ["error": error.localizedDescription] }
    }

    // MARK: - Automation server

    @MainActor func startAutomationServerIfNeeded() {
        let defaults = UserDefaults.standard
        // Default OFF — opt-in to keep the loopback HTTP API hidden
        // until the user enables it (Bromure → Preferences → Automation,
        // or `defaults write io.bromure.agentic-coding automation.enabled
        // -bool true`). The e2e Jenkinsfile sets this before launching.
        guard defaults.bool(forKey: "automation.enabled") else { return }

        if automationServer != nil { stopAutomationServer() }

        let port = UInt16(defaults.integer(forKey: "automation.port"))
        let bindAddr = defaults.string(forKey: "automation.bindAddress") ?? "127.0.0.1"
        let server = ACAutomationServer(port: port > 0 ? port : 9223, bindAddress: bindAddr)
        wireAutomationCallbacks(into: server)
        server.start()
        automationServer = server
    }

    /// Always-on owner-only Unix control socket for the `bromure-ac` CLI.
    /// Independent of `automation.enabled` (which only gates the TCP API) so the
    /// CLI works out of the box. exec / vm operations are allowed here without
    /// the debug flag — the 0600 socket file is the access gate.
    @MainActor func startControlSocket() {
        if controlServer != nil { return }
        let socketURL = store.controlSocketURL
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = ACAutomationServer(unixSocketPath: socketURL.path)
        wireAutomationCallbacks(into: server)
        server.start()
        controlServer = server
    }

    @MainActor func stopAutomationServer() {
        automationServer?.stop()
        automationServer = nil
    }

    /// Wire the shared control-plane callbacks into a server instance (used by
    /// both the opt-in TCP API and the always-on Unix control socket).
    @MainActor private func wireAutomationCallbacks(into server: ACAutomationServer) {
        server.onListProfiles = { [weak self] in
            guard let self else { return [] }
            return self.profiles.map { p in
                let stateStr: String
                switch self.runState(for: p) {
                case .running:   stateStr = "running"
                case .booting:   stateStr = "booting"
                case .suspended: stateStr = "suspended"
                case .off:       stateStr = "off"
                }
                return ACAutomationProfileInfo(
                    id: p.id.uuidString,
                    shortId: Self.shortID(p.id),
                    name: p.name,
                    color: p.color.rawValue,
                    tool: p.tool.rawValue,
                    authMode: p.authMode.rawValue,
                    mcpServerCount: p.mcpServers.count,
                    state: stateStr
                )
            }
        }

        // Sessions = the registry (so detached, window-less VMs are listed too).
        server.onListSessions = { [weak self] in
            guard let self else { return [] }
            return self.runningSessions.values.map { s in
                let host = self.hostWindow(for: s.profileID)
                return ACAutomationSessionInfo(
                    profileID: s.profileID.uuidString,
                    profileName: s.profile.name,
                    windowID: host?.windowNumber ?? 0,
                    visible: host?.isVisible ?? false
                )
            }
        }

        server.onCreateSession = { [weak self] profileNameOrID in
            guard let self else { return nil }
            return await self.automationCreateSession(profileNameOrID: profileNameOrID)
        }

        server.onDestroySession = { [weak self] profileNameOrID in
            guard let self else { return false }
            return await self.automationDestroySession(profileNameOrID: profileNameOrID)
        }

        server.onWorktreeCommand = { [weak self] profileNameOrID, action, args in
            self?.automationWorktreeCommand(profileNameOrID: profileNameOrID,
                                            action: action, args: args) ?? false
        }
        server.onTabCommand = { [weak self] profileNameOrID, action, index in
            self?.automationTabCommand(profileNameOrID: profileNameOrID,
                                       action: action, index: index) ?? false
        }

        server.onGetAppState = { [weak self] in
            guard let self else { return [:] }
            return [
                "locale": (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? "system",
                "mainWindowOpen": self.mainWindow?.isVisible ?? false,
                "editorOpen": self.editorWindow?.isVisible ?? false,
                "profileCount": self.profiles.count,
                "sessionCount": self.runningSessions.count,
                "hasBaseImage": self.imageManager.hasBaseImage,
            ]
        }
        server.onUIShot = { [weak self] path, which in
            // The route already dispatches us onto main via `DispatchQueue.main.sync`,
            // so assume isolation rather than nesting another sync (which deadlocks).
            MainActor.assumeIsolated {
                guard let self else { return ["error": "no app"] }
                let window: NSWindow?
                switch which {
                case "picker": window = self.mainWindow
                case "editor": window = self.editorWindow
                default:       window = self.unifiedWindow
                }
                return self.debugRenderWindow(window, to: path)
            }
        }
        // Drive the settings editor over the control socket (doc-screenshot
        // tool) — replaces the old AppleScript bridge so the script needs no
        // scripting terminology, LaunchServices registration, or Screen
        // Recording permission.
        server.onEditorDebug = { [weak self] params in
            MainActor.assumeIsolated {
                guard let self else { return ["error": "no app"] }
                let action = params["action"] as? String ?? ""
                switch action {
                case "ensure-profile":
                    let name = (params["name"] as? String) ?? "Screenshot"
                    if let existing = self.profiles.first(where: { $0.name.lowercased() == name.lowercased() }) {
                        return ["id": existing.id.uuidString, "created": false]
                    }
                    let p = Profile(name: name, tool: .claude, authMode: .token, color: .blue)
                    do {
                        try self.store.save(p)
                        self.profiles = self.store.loadAll()
                        return ["id": p.id.uuidString, "created": true]
                    } catch { return ["error": "create failed: \(error.localizedDescription)"] }
                case "open":
                    let key = (params["profile"] as? String) ?? ""
                    let profile: Profile?
                    if let uuid = UUID(uuidString: key) { profile = self.profiles.first { $0.id == uuid } }
                    else { profile = self.profiles.first { $0.name.lowercased() == key.lowercased() } }
                    guard let profile else { return ["error": "profile not found: \(key)"] }
                    self.openEditorWindow(editing: profile)
                    return ["editorOpen": self.editorWindow?.isVisible ?? false,
                            "windowId": self.editorWindow?.windowNumber ?? 0]
                case "category":
                    let raw = (params["category"] as? String ?? "").lowercased()
                    guard !raw.isEmpty else { return ["error": "category required"] }
                    NotificationCenter.default.post(name: .bromureACSelectEditorCategory, object: raw)
                    return ["ok": true]
                case "close":
                    self.closeEditorWindow()
                    return ["ok": true]
                default:
                    return ["error": "unknown action: \(action)"]
                }
            }
        }

        server.onGetShellConnection = { [weak self] idOrName in
            guard let self else { return nil }
            guard let uuid = self.resolveRunningSessionID(idOrName) else { return nil }
            guard let bridge = self.shellBridges[uuid] else { return nil }
            guard let conn = bridge.dequeueConnection() else { return nil }
            return ACShellProxyConnection(fd: conn.fileDescriptor, conn: conn)
        }

        server.onResolveProfileID = { [weak self] idOrName in
            guard let self else { return nil }
            return MainActor.assumeIsolated { self.resolveRunningSessionID(idOrName)?.uuidString }
        }

        // (Consent for CLI/SSH-attached sessions is rendered host-side on the
        // user's terminal by the pump — see RemoteConsent + ACAutomationServer's
        // PumpConsentGate. No wiring needed here beyond the UUID resolver above.)

        // docker-style VM control plane.
        server.onListVMs = { [weak self] in self?.automationVMList() ?? [] }
        server.onStopVM = { [weak self] idOrName, action in
            guard let self else { return false }
            return await self.automationStopVM(idOrName: idOrName, action: action)
        }
        server.onAttachVM = { [weak self] idOrName in
            guard let self else { return false }
            return await self.automationAttachVM(idOrName: idOrName)
        }
        server.onCreateVM = { [weak self] spec in
            guard let self else { return nil }
            return await self.automationCreateVM(spec: spec)
        }
        server.onListCheckpoints = { [weak self] idOrName in
            self?.automationListCheckpoints(idOrName) ?? []
        }
        server.onRevertCheckpoint = { [weak self] idOrName, cp in
            await self?.automationRevertCheckpoint(idOrName: idOrName, checkpoint: cp)
                ?? ["error": "unavailable"]
        }
        server.onDescribeProfile = { [weak self] key in self?.automationProfileDescribe(key) }
        server.onExportProfile = { [weak self] key in self?.automationProfileExport(key) }
        server.onCreateProfile = { [weak self] doc in
            self?.automationUpsertProfile(idOrName: nil, doc: doc) ?? ["ok": false, "error": "unavailable"]
        }
        server.onUpdateProfile = { [weak self] key, doc in
            self?.automationUpsertProfile(idOrName: key, doc: doc) ?? ["ok": false, "error": "unavailable"]
        }
        server.onDeleteProfile = { [weak self] key in
            self?.automationDeleteProfile(key) ?? ["ok": false, "error": "unavailable"]
        }
        server.onRebootVM = { [weak self] idOrName, mode in
            await self?.automationRebootVM(idOrName: idOrName, mode: mode) ?? ["ok": false, "error": "unavailable"]
        }
        server.onListTrace = { [weak self] profileKey in self?.automationTraceList(profileKey) ?? [] }
        server.onClearTrace = { [weak self] in self?.mitmEngine?.traceStore.clear() ?? 0 }
        // Local inference now flows through the MITM (guest → https://bromure.llm
        // → MITM → engine), so the MITM records the trace + drives the thinking
        // indicator exactly like cloud — no separate local trace path (which is
        // why local bodies weren't captured before). We keep this activity hook
        // as a downstream backstop for the "thinking" indicator.
        InferenceRepairProxy.shared.onLocalActivity = { [weak self] pid in
            DispatchQueue.main.async { self?.noteAgentActivity(pid) }
        }
        server.onSetFusion = { [weak self] idOrName, engaged in
            self?.automationSetFusion(idOrName: idOrName, engaged: engaged)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetRouting = { [weak self] idOrName, mode in
            self?.automationSetRouting(idOrName: idOrName, mode: mode)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetHybrid = { [weak self] idOrName, knob, value in
            self?.automationSetHybrid(idOrName: idOrName, knob: knob, value: value)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetModel = { [weak self] idOrName, modelID in
            self?.automationSetModel(idOrName: idOrName, modelID: modelID)
                ?? ["ok": false, "error": "unavailable"]
        }

        // Remote access (optional SSH front door) — owner-only control socket.
        server.onRemoteStatus = { [weak self] in
            MainActor.assumeIsolated { self?.remoteAccessStatus() ?? [:] }
        }
        server.onRemoteApply = { [weak self] spec in
            MainActor.assumeIsolated { self?.remoteAccessApply(spec) ?? ["error": "unavailable"] }
        }
        server.onRemoteAddKey = { [weak self] key in
            MainActor.assumeIsolated { self?.remoteAccessAddKey(key) ?? ["error": "unavailable"] }
        }
        server.onRemoteRemoveKey = { [weak self] sel in
            MainActor.assumeIsolated { self?.remoteAccessRemoveKey(sel) ?? ["error": "unavailable"] }
        }
    }

    /// MITM trace records for `trace …`, optionally filtered to one profile.
    /// Record a per-VM local-inference call (shipped by the engine child's
    /// repair proxy) into the TraceStore, so local LLM calls show up in `trace`
    /// next to cloud calls, tagged with the profile that made them. Respects the
    /// profile's trace level the same way the MITM does.
    @MainActor private func automationIngestLocalTrace(_ event: [String: Any]) {
        guard let pidStr = event["profileID"] as? String, let pid = UUID(uuidString: pidStr),
              let store = mitmEngine?.traceStore,
              let profile = profiles.first(where: { $0.id == pid }),
              profile.traceLevel.recordsActivity else { return }
        let model = event["model"] as? String ?? "?"
        // Local inference is an AI request, so persist its prompt/tools +
        // response at the same trace levels the MITM captures cloud LLM bodies
        // (AI request details / Everything) — otherwise the inspector has only
        // metadata to show.
        let capture = profile.traceLevel == .aiDetails || profile.traceLevel == .all
        let reqBody = capture ? (event["requestBody"] as? Data) : nil
        let resBody = capture ? (event["responseBody"] as? Data) : nil
        let stored = (reqBody?.isEmpty == false) || (resBody?.isEmpty == false)
        let rec = TraceRecord(
            sessionID: pid, profileID: pid,
            host: "local-engine", port: InferenceService.enginePort,
            method: "POST", path: event["path"] as? String ?? "/v1/messages",
            statusCode: (event["status"] as? NSNumber)?.intValue ?? 0,
            requestBytes: (event["requestBytes"] as? NSNumber)?.intValue ?? 0,
            responseBytes: (event["responseBytes"] as? NSNumber)?.intValue ?? 0,
            latencyMs: (event["latencyMs"] as? NSNumber)?.doubleValue ?? 0,
            swaps: [], leaks: [], bodyStored: stored, isConversation: true,
            servedBy: "local-\(model)")
        store.record(rec, requestBody: reqBody, responseBody: resBody)
    }

    /// Newest first; previews only (no secret values).
    @MainActor private func automationTraceList(_ profileKey: String?) -> [[String: Any]] {
        guard let engine = mitmEngine else { return [] }
        let wantID: Profile.ID? = profileKey.flatMap { profileByNameOrID($0)?.id }
        let iso = ISO8601DateFormatter()
        return engine.traceStore.recent.compactMap { rec -> [String: Any]? in
            if let wantID, rec.profileID != wantID { return nil }
            return [
                "id": rec.id.uuidString,
                "time": iso.string(from: rec.timestamp),
                "profileId": rec.profileID.uuidString,
                "profileShort": Self.shortID(rec.profileID),
                "host": rec.host,
                "port": rec.port,
                "method": rec.method,
                "path": rec.path,
                "status": rec.statusCode,
                "requestBytes": rec.requestBytes,
                "responseBytes": rec.responseBytes,
                "latencyMs": rec.latencyMs,
                "swaps": rec.swaps.count,
                "leaks": rec.leaks.map {
                    ["header": $0.header, "preview": $0.valuePreview, "suspicion": $0.suspicion.rawValue]
                },
                "conversation": rec.isConversation,
            ]
        }
    }

    /// Toggle Fusion for a running VM's profile (`vm fusion enable|disable`).
    @MainActor private func automationSetFusion(idOrName: String, engaged: Bool) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard session.profile.fusionConfigurable else {
            return ["ok": false, "error": "Fusion needs at least two usable model credentials on this workspace."]
        }
        setFusionEngaged(engaged, for: session.profile)
        return ["ok": true, "engaged": engaged]
    }

    /// `vm routing cloud|local|hybrid` — set the per-profile backend
    /// routing and push it live to the MITM engine (vLLM.md §4.2).
    @MainActor private func automationSetRouting(idOrName: String, mode: String) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard let routing = Profile.Routing(rawValue: mode.lowercased()) else {
            return ["ok": false, "error": "Routing must be 'cloud', 'local', or 'hybrid'."]
        }
        var profile = session.profile
        profile.modelRouting = routing
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        return ["ok": true, "routing": routing.rawValue]
    }

    /// `vm hybrid budget|ttft|split <value>` — tune the hybrid policy
    /// knobs (vLLM.md §4.3.1) and push them live.
    @MainActor private func automationSetHybrid(idOrName: String, knob: String, value: Double) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        var profile = session.profile
        switch knob {
        case "budget": profile.hybridCloudTokenBudget = max(0, Int(value))
        case "ttft":   profile.hybridSoftTTFTSeconds = max(0, value)
        case "split":  profile.hybridLocalSplitPercent = max(0, min(100, Int(value)))
        default: return ["ok": false, "error": "Unknown hybrid knob: \(knob)"]
        }
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        return ["ok": true, "knob": knob, "value": value]
    }

    /// `model use <id>` — set the profile's active local model (drives the
    /// served-by marker + which weights the engine loads under local/hybrid).
    @MainActor private func automationSetModel(idOrName: String, modelID: String) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard let model = CatalogStore.shared.resolve(modelID) else {
            return ["ok": false, "error": "Unknown model '\(modelID)'. Try `model catalog`."]
        }
        var profile = session.profile
        profile.activeModelID = model.id
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        // Re-point the sentinel + make the engine serve the new model. The guest
        // keeps its env (ANTHROPIC_MODEL = bromure-local), so the switch takes
        // effect on the next request with no agent restart.
        startLocalEngineIfNeeded(for: profile)
        return ["ok": true, "model": model.id, "repo": model.repo]
    }

    /// Curated, secret-free view of a profile's settings for `profiles describe`.
    @MainActor private func automationProfileDescribe(_ key: String) -> [String: Any]? {
        guard let p = profileByNameOrID(key) else { return nil }
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": p.id.uuidString,
            "shortId": Self.shortID(p.id),
            "name": p.name,
            "color": p.color.rawValue,
            "tool": p.tool.rawValue,
            "authMode": p.authMode.rawValue,
            "apiKeySet": (p.apiKey?.isEmpty == false),
            "memoryGB": p.memoryGB,
            "networkMode": p.networkMode.rawValue,
            "macAddress": MACBindings.shared.macAddress(for: p.id),
            "closeAction": p.closeAction.rawValue,
            "bootAtStartup": p.bootAtStartup,
            "folderPaths": p.folderPaths,
            "mcpServers": p.mcpServers.map { $0.name },
            "sshKeySet": (p.sshPublicKey?.isEmpty == false),
            "importedSSHKeys": p.importedSSHKeys.count,
            "running": runningSessions[p.id] != nil,
            "comments": p.comments,
            "createdAt": iso.string(from: p.createdAt),
        ]
        if let last = p.lastUsedAt { d["lastUsedAt"] = iso.string(from: last) }
        return d
    }

    /// Delete a profile (and its disk + home). Refuses while a VM is running.
    @MainActor private func automationDeleteProfile(_ key: String) -> [String: Any] {
        guard let p = profileByNameOrID(key) else {
            return ["ok": false, "error": "Workspace not found: \(key)"]
        }
        if runningSessions[p.id] != nil {
            return ["ok": false, "error": "Workspace '\(p.name)' has a running VM — `vm kill` it first."]
        }
        do {
            try store.delete(p)
            profiles = store.loadAll()
            refreshSidebar()
            return ["ok": true, "name": p.name]
        } catch {
            return ["ok": false, "error": "Couldn't delete '\(p.name)': \(error.localizedDescription)"]
        }
    }

    /// Snapshot of running VMs for `vm ls`.
    @MainActor private func automationVMList() -> [[String: Any]] {
        let now = Date()
        return runningSessions.values.map { s in
            let stateStr: String
            switch s.sandbox.state {
            case .created:  stateStr = "created"
            case .starting: stateStr = "starting"
            case .running:  stateStr = "running"
            case .stopped:  stateStr = "stopped"
            case .error:    stateStr = "error"
            }
            // 1-based for display; `index` is the tmux window index the CLI
            // passes back to `select-window`.
            let tabs: [[String: Any]] = s.tabs.map { t in
                var d: [String: Any] = [
                    "index": t.index,
                    // `title` is the display name (worktree label) when set,
                    // else the foreground program — what SSH/API should show.
                    "title": (t.display?.isEmpty == false ? t.display! : (t.label.isEmpty ? "shell" : t.label)),
                    "active": t.active,
                ]
                // Worktree metadata for SSH parity (create/merge/discard).
                if let cwd = t.cwd { d["cwd"] = cwd }
                if t.isWorktree {
                    d["isWorktree"] = true
                    if let b = t.worktreeBranch { d["worktreeBranch"] = b }
                } else if t.isGitRepo {
                    d["isGitRepo"] = true
                }
                // parentBranch/rootRepo ride on worktree tabs AND on attached
                // terminals (plain tabs opened via "Attach terminal") — the
                // latter nest under their worktree by parentBranch alone.
                if let p = t.parentBranch, !p.isEmpty { d["parentBranch"] = p }
                if let r = t.rootRepo, !r.isEmpty { d["rootRepo"] = r }
                // A "Merge → …" tab is resolvable; expose it so SSH can offer it.
                if t.display?.hasPrefix("Merge → ") == true { d["isMergeTab"] = true }
                return d
            }
            let diskURL = store.diskURL(for: s.profile)
            let diskAllocated = (try? diskURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return [
                "id": s.profileID.uuidString,
                "shortId": Self.shortID(s.profileID),
                "name": s.profile.name,
                "tool": s.profile.tool.rawValue,
                "state": stateStr,
                "attached": isAttached(s.profileID),
                "uptimeSeconds": Int(now.timeIntervalSince(s.startedAt)),
                "ip": s.lastIP ?? "",
                "mounts": s.profile.folderPaths,
                "tabs": tabs,
                "cpuCount": UbuntuSandboxVM.runtimeCPUs,
                "memoryGB": s.profile.memoryGB,
                "cpu": pane(for: s.profileID)?.model.vmCPU ?? 0,
                "memUsedKB": pane(for: s.profileID)?.model.vmMemUsedKB ?? 0,
                "memTotalKB": pane(for: s.profileID)?.model.vmMemTotalKB ?? 0,
                "load": pane(for: s.profileID)?.model.vmLoad ?? 0,
                "diskUsedKB": pane(for: s.profileID)?.model.vmDiskUsedKB ?? 0,
                "diskTotalKB": pane(for: s.profileID)?.model.vmDiskTotalKB ?? 0,
                "hasStats": (pane(for: s.profileID)?.model.vmMemTotalKB ?? 0) > 0,
                "networkMode": s.profile.networkMode.rawValue,
                "macAddress": MACBindings.shared.macAddress(for: s.profileID),
                "diskPath": diskURL.path,
                "diskAllocatedBytes": diskAllocated,
                "baseImageVersion": s.profile.baseImageVersionAtClone ?? "unknown",
                "fusionConfigurable": s.profile.fusionConfigurable,
                "fusionEngaged": mitmEngine?.fusionEngaged(for: s.profileID) ?? false,
                // Mirrored from the session (not the pane) so detached VMs report
                // them too. The TUI/dashboard filter loopback at display time.
                "listeningPorts": s.listeningPorts.map {
                    ["proto": $0.proto, "addr": $0.addr, "port": $0.port,
                     "process": $0.process] as [String: Any]
                },
            ]
        }
    }

    @MainActor private func automationStopVM(idOrName: String, action: String) async -> Bool {
        guard let id = resolveRunningSessionID(idOrName) else { return false }
        let closeAction: Profile.CloseAction
        switch action.lowercased() {
        case "suspend":            closeAction = .suspend
        default:                   closeAction = .shutdown   // shutdown / kill / stop
        }
        await stopSession(id, action: closeAction)
        return true
    }

    @MainActor private func automationAttachVM(idOrName: String) async -> Bool {
        guard let id = resolveRunningSessionID(idOrName),
              let session = runningSessions[id] else { return false }
        attachWindow(to: session)
        return true
    }

    /// Reboot a running workspace in place — window-independent, so it also
    /// works for detached remote/SSH sessions (the keychord overlay + the CLI
    /// `workspaces reboot`). `soft` gracefully halts (ACPI, filesystems flush);
    /// `hard` tears the VM down immediately. Both clear any suspended state and
    /// cold-boot a fresh VM for the same profile, re-attaching a window only if
    /// one was attached before.
    @MainActor private func automationRebootVM(idOrName: String, mode: String) async -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not running: \(idOrName)"]
        }
        let profile = session.profile
        let wasAttached = isAttached(id)
        session.sandbox.sessionDisk?.clearSavedState()   // cold-boot fresh, never resume

        if mode == "hard", let vm = session.sandbox.vm {
            await Self.forceStop(vm)
        } else {
            await stopSession(id, action: .shutdown)
        }
        // Wait for the old session to leave the registry before re-booting the
        // same profile — they share per-profile dirs (outbox, meta share), so
        // overlapping boots would race the virtiofs handles.
        for _ in 0..<200 {
            if runningSessions[id] == nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        launch(profile, detached: !wasAttached)
        var up = false
        for _ in 0..<600 {   // first boots can take a while
            if runningSessions[id] != nil { up = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return ["ok": up, "workspace": profile.name, "mode": mode == "hard" ? "hard" : "soft"]
    }

    /// Docker-style 12-char short id for a profile: the UUID's hex with dashes
    /// stripped, lowercased, truncated. Shown by `vm ls` and accepted (as a
    /// prefix) by every `<id|name>` argument.
    static func shortID(_ id: Profile.ID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// Resolve a CLI-supplied id-or-name to a *running* session's profile id.
    /// Accepts a full UUID, an exact profile name (case-insensitive), or a
    /// unique short-id *prefix* (dash-insensitive) — so the 12-char hex id from
    /// `vm ls` (or any unambiguous prefix of it) works, docker-style.
    @MainActor private func automationListCheckpoints(_ idOrName: String) -> [[String: Any]] {
        guard let profile = profileByNameOrID(idOrName) else { return [] }
        return store.listCheckpoints(for: profile).map {
            ["id": $0.id,
             "createdAt": Int($0.createdAt.timeIntervalSince1970),
             "allocatedBytes": $0.allocatedBytes]
        }
    }

    @MainActor private func automationRevertCheckpoint(idOrName: String, checkpoint: String) async -> [String: Any] {
        guard let profile = profileByNameOrID(idOrName) else {
            return ["error": "Workspace not found: \(idOrName)"]
        }
        // The disk image is replaced wholesale, so the VM must not have it open.
        if runningSessions[profile.id] != nil {
            return ["error": "Stop the workspace first (`vm kill \(profile.name)`), then revert."]
        }
        do {
            try store.revertDisk(for: profile, to: checkpoint)
            return ["status": "reverted", "checkpoint": checkpoint, "workspace": profile.name]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    @MainActor private func resolveRunningSessionID(_ key: String) -> Profile.ID? {
        if let uuid = UUID(uuidString: key), runningSessions[uuid] != nil { return uuid }
        if let byName = runningSessions.values
            .first(where: { $0.profile.name.lowercased() == key.lowercased() }) {
            return byName.profileID
        }
        let k = key.replacingOccurrences(of: "-", with: "").lowercased()
        guard !k.isEmpty else { return nil }
        let matches = runningSessions.keys.filter {
            $0.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Create (boot) a VM from a control-plane spec — the `vm run` path. Mints
    /// or resolves a profile, applies `-v` mounts, persists it, then drives the
    /// normal `launch` path (so all the engine / token / boot wiring is shared)
    /// and optionally detaches for a headless `-d` run.
    @MainActor private func automationCreateVM(spec: [String: Any]) async -> [String: Any]? {
        // 1. Resolve an existing profile, or mint one on the fly.
        var profile: Profile
        if let ref = spec["profile"] as? String, let existing = profileByNameOrID(ref) {
            profile = existing
        } else {
            let fallback = "cli-" + String(UUID().uuidString.prefix(8)).lowercased()
            let name = (spec["name"] as? String) ?? (spec["profile"] as? String) ?? fallback
            let tool = (spec["tool"] as? String).flatMap { Profile.Tool(rawValue: $0) }
            let auth = (spec["auth"] as? String).flatMap { Profile.AuthMode(rawValue: $0) }
            var p = store.newProfileFromTemplate(name: name, tool: tool, authMode: auth)
            if let key = spec["apiKey"] as? String, !key.isEmpty { p.apiKey = key }
            if let mem = spec["memoryGB"] as? Int, mem > 0 { p.memoryGB = mem }
            profile = p
        }

        // 1b. Refuse to start while a selected local model is still downloading —
        //     booting now would point the agent at an engine that can't load it
        //     yet. Surface a clear error (the /vms route turns this into 409) so
        //     `vm run` prints it instead of hanging until the boot-wait times out.
        if let dl = downloadingModel(for: profile) {
            return ["error": "“\(dl.name)” is still downloading — wait for it to finish, then start “\(profile.name)”."]
        }

        // 2. Apply `-v` mounts (host paths → ~/<basename> in the guest), capped
        //    at the base image's 8 fstab slots.
        if let mounts = spec["mounts"] as? [String], !mounts.isEmpty {
            var paths = profile.folderPaths
            for m in mounts {
                let host = (m as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: host) else {
                    FileHandle.standardError.write(Data("[vm run] mount not found, skipping: \(host)\n".utf8))
                    continue
                }
                if !paths.contains(host) { paths.append(host) }
            }
            profile.folderPaths = Array(paths.prefix(8))
        }

        // 3. Persist + refresh the in-memory list.
        do { try store.save(profile) }
        catch {
            FileHandle.standardError.write(Data("[vm run] couldn't save profile: \(error)\n".utf8))
            return nil
        }
        profiles = store.loadAll()
        let saved = profiles.first { $0.id == profile.id } ?? profile
        if spec["rm"] as? Bool == true { ephemeralProfiles.insert(saved.id) }

        // 4. Boot via the shared launch path. A headless `-d` run boots
        //    window-less from the start (no pane is ever hosted) so no window
        //    flashes up during boot. If the session is already running, `launch`
        //    detaches it instead.
        let detach = spec["detach"] as? Bool == true
        if runningSessions[saved.id] == nil {
            launch(saved, detached: detach)
        } else if detach {
            detachSession(saved.id)
        }

        // 5. Wait for the VM to register (first boot can take a while).
        var ready = false
        for _ in 0..<600 {   // up to ~60s
            if runningSessions[saved.id] != nil { ready = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { return nil }

        return [
            "id": saved.id.uuidString,
            "shortId": Self.shortID(saved.id),
            "name": saved.name,
            "tool": saved.tool.rawValue,
            "detached": detach,
        ]
    }

    @MainActor private func automationCreateSession(profileNameOrID: String) async -> ACAutomationSessionInfo? {
        guard let profile = profileByNameOrID(profileNameOrID) else { return nil }
        // If a session is already shown for this profile, just return its info.
        if isAttached(profile.id) {
            let host = hostWindow(for: profile.id)
            return ACAutomationSessionInfo(
                profileID: profile.id.uuidString,
                profileName: profile.name,
                windowID: host?.windowNumber ?? 0,
                visible: host?.isVisible ?? false
            )
        }
        launch(profile)
        // launch() is fire-and-forget; the pane appears asynchronously when the
        // VM pool warms up. Wait up to 30s for it to register so the API caller
        // gets a meaningful response.
        for _ in 0..<300 {
            if isAttached(profile.id) {
                let host = hostWindow(for: profile.id)
                return ACAutomationSessionInfo(
                    profileID: profile.id.uuidString,
                    profileName: profile.name,
                    windowID: host?.windowNumber ?? 0,
                    visible: host?.isVisible ?? false
                )
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @MainActor private func automationDestroySession(profileNameOrID: String) async -> Bool {
        guard let profile = profileByNameOrID(profileNameOrID) else { return false }
        guard isAttached(profile.id) else { return false }
        closeVMFromSidebar(profile.id)
        // Wait briefly for the close to take effect.
        for _ in 0..<50 {
            if !isAttached(profile.id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !isAttached(profile.id)
    }

    @MainActor private func profileByNameOrID(_ key: String) -> Profile? {
        if let uuid = UUID(uuidString: key) { return profiles.first { $0.id == uuid } }
        if let byName = profiles.first(where: { $0.name.lowercased() == key.lowercased() }) {
            return byName
        }
        // Docker-style short-id prefix (dash-insensitive).
        let k = key.replacingOccurrences(of: "-", with: "").lowercased()
        guard !k.isEmpty else { return nil }
        let matches = profiles.filter {
            $0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func interceptKey(_ event: NSEvent) -> NSEvent? {
        // The meaningful test is "is Command held without any other
        // user-meaningful modifier (shift / option / control)". macOS
        // sets stray bits — capsLock when the LED is on, numericPad on
        // some letter keys with non-US layouts, help / function — that
        // a strict `mods == [.command]` would reject. Filter to just
        // the four modifiers a user expects to combine with Command,
        // then check Command is the only one set.
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(userMods)
        guard mods == [.command] else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // ⌘H = standard macOS "hide app". Handle here defensively in
        // case responder-chain routing is interfered with elsewhere.
        if chars == "h" {
            NSApp.hide(nil)
            return nil
        }

        // Find the owning session window. keyWindow first, then any visible
        // session — keeps the chord working when AppKit hands us a keyDown
        // with a nil/foreign event.window.
        let sessions = NSApp.windows.compactMap { $0 as? TabbedSessionWindow }
        let win = (NSApp.keyWindow as? TabbedSessionWindow)
            ?? sessions.first(where: { $0.isVisible })

        // ⌘N opens the picker even with no session window up.
        guard let win else {
            if chars == "n" {
                openProfileManagerAction(nil)
                return nil
            }
            return event
        }

        // Host-owned chords (⌘T / ⌘W / ⌘N / ⌘D / ⌘1-9) → consume; every other
        // ⌘ chord is sent on. (There is no guest-side chord grab anymore —
        // native terminal surfaces never see host-owned chords.)
        if win.performACShortcut(chars, isRepeat: event.isARepeat) { return nil }
        return event
    }

    /// Host actions for the macOS system chords the guest bounces back while the
    /// VM holds keyboard focus — ⌘Q, ⌘H, and the ⇧⌘Q (log out) / ⌃⌘Q (lock
    /// screen) shortcuts. The VZ view forwards these to the guest
    /// (capturesSystemKeys only frees WindowServer hotkeys like ⌘Tab, not app /
    /// loginwindow key-equivalents), where they'd be swallowed; Openbox grabs
    /// them (see Profile.swift's rc.xml) and `bromure-hostkey` bounces the bare
    /// token here. Returns true when `key` was a system chord (fully handled).
    /// Per-chord timestamp feeding the leading-edge guard below.
    private var lastSystemChordAt: [String: Date] = [:]

    /// True from the moment ⌘Q starts the quit flow until the app actually
    /// exits (or the user cancels). The quit confirmation blocks the main
    /// thread in `runModal`, during which a stranded-keyUp autorepeat can queue
    /// more `q` bounces; without this, every one re-enters `NSApp.terminate`
    /// after the dialog closes and preempts the drain, so the app never quits.
    private var quitRequested = false

    @discardableResult @MainActor
    func performACSystemChord(_ key: String) -> Bool {
        switch key {
        case "q", "h", "ctrl-q", "shift-q", "shift-n", "shift-g", "shift-m": break
        default: return false
        }
        // Leading-edge autorepeat guard. Each of these chords pulls focus off
        // the VM, so the guest loses the keyUp and X can autorepeat the chord
        // for a beat before the guest's own keyup-release (see bromure-hostkey)
        // lands. Swallow those repeats so ⌘Q shows ONE quit dialog, not a stack,
        // and ⌘H/lock/log-out fire once. 600ms passes a deliberate re-press.
        let now = Date()
        if let prev = lastSystemChordAt[key], now.timeIntervalSince(prev) < 0.6 {
            return true
        }
        lastSystemChordAt[key] = now

        switch key {
        case "q":
            // ⌘Q. Do NOT call NSApp.terminate synchronously here: we're inside a
            // MainActor Task (a serial main-queue block), and terminate()'s
            // `.terminateLater` path spins a nested runloop waiting for a reply
            // that only ANOTHER MainActor job (the VM drain) can produce — which
            // can't start until this block returns. That deadlocks the main
            // thread and the app never quits. Instead drive the quit on its own
            // Task that drains via async/await (freeing the MainActor at each
            // suspension) and only then terminates. Re-entrancy guard: repeats
            // that land while the confirmation dialog is up are dropped.
            if quitRequested { return true }
            quitRequested = true
            Task { @MainActor in await self.performBouncedQuit() }
        case "h":
            NSApp.hide(nil)
        case "ctrl-q":
            lockScreen()
        case "shift-q":
            logOut()
        // Workspaces-menu chords bounced from the VM. These don't pull macOS
        // focus (no keyup synthesis needed in bromure-hostkey); they just run
        // the same actions the menu items do.
        case "shift-n":
            newWorkspaceAction(nil)
        case "shift-g":
            newWorktreeAction(nil)
        case "shift-m":
            mergeWorktreeAction(nil)
        default:
            return false
        }
        return true
    }

    /// ⌃⌘Q — lock the screen. No public API locks the session;
    /// login.framework's `SACLockScreenImmediate` is the same entry point the
    /// system shortcut drives. dlopen'd so a macOS that ever drops the symbol
    /// degrades to a logged no-op rather than a launch-time link failure.
    @MainActor
    private func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_NOW),
              let sym = dlsym(handle, "SACLockScreenImmediate") else {
            NSLog("[hostkey] lock-screen entry point unavailable")
            return
        }
        _ = unsafeBitCast(sym, to: LockFn.self)()
    }

    /// ⇧⌘Q — log out. Sends loginwindow the same Apple event the shortcut does,
    /// so the standard "quit all applications and log out?" confirmation shows
    /// (kAELogOut 'logo', not the no-prompt variant). First use may raise the
    /// Automation-permission prompt to control loginwindow.
    @MainActor
    private func logOut() {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(0x6165_7674),   // 'aevt'
            eventID: AEEventID(0x6c6f_676f),             // 'logo'
            targetDescriptor: target,
            returnID: AEReturnID(-1),                     // kAutoGenerateReturnID
            transactionID: AETransactionID(0))            // kAnyTransactionID
        do {
            try event.sendEvent(options: .noReply, timeout: 5)
        } catch {
            NSLog("[hostkey] log-out event failed: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Quit only when literally every window is gone — picker + all
        // session windows. Closing one session shouldn't take the others
        // down with it.
        false
    }

    /// ⌘Q (and Quit menu) confirmation. Skip the prompt if no VMs are
    /// running — quitting an idle app should be friction-free.
    ///
    /// With running VMs we return `.terminateLater` and drive an
    /// async drain (clean ACPI poweroff with a force-stop watchdog)
    /// before replying. AppKit holds the termination until we call
    /// `NSApp.reply(toApplicationShouldTerminate:)`. This is the
    /// documented async-shutdown pattern and it fixes the
    /// "NSActivity was ended multiple times" warning Foundation
    /// emits when VZ's framework teardown races our in-flight
    /// `vm.stop()` callbacks: drained-first means VZ ends its
    /// internal activity exactly once, in order.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Menu / window-close / system-quit path: invoked directly by AppKit
        // (not from a Task), so the `.terminateLater` nested runloop CAN service
        // the drain job. (The guest-bounced ⌘Q can't use this — see
        // performBouncedQuit — so it pre-drains and hits `.terminateNow`.)
        guard confirmQuit() else {
            quitRequested = false
            return .terminateCancel
        }
        let running = runningSessions.values.filter { $0.sandbox.vm?.state == .running }
        if running.isEmpty { return .terminateNow }

        Task { @MainActor in
            await self.drainRunningVMs()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The shared "N VMs running — quit anyway?" confirmation. Returns true to
    /// proceed (nothing running, or the user clicked Quit), false to abort.
    @MainActor
    private func confirmQuit() -> Bool {
        let running = runningSessions.values.filter { $0.sandbox.vm?.state == .running }
        if running.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Bromure Agentic Coding?", comment: "")
        let names = running.map { $0.profile.name }.joined(separator: ", ")
        alert.informativeText = String(
            format: NSLocalizedString(
                "%d VM(s) currently running (%@) will be closed according to each workspace's close action.",
                comment: ""),
            running.count, names)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quit driven from the guest-bounced ⌘Q. Runs on its own MainActor Task so
    /// it can drain the VMs with async/await — every `await` frees the main
    /// thread, so VZ's pause/stop completions actually run. Only once the VMs
    /// are down do we call terminate, which then takes the synchronous
    /// `.terminateNow` path (no `.terminateLater` nested-runloop wait, hence no
    /// deadlock against this same actor).
    @MainActor
    private func performBouncedQuit() async {
        guard confirmQuit() else {
            quitRequested = false
            return
        }
        await drainRunningVMs()
        NSApp.terminate(nil)
    }

    /// Stop every running VM in parallel on quit via `stopSession`, honoring
    /// each profile's close action (`.ask` → `.suspend`). Iterates the
    /// registry, so it drains *detached* VMs too — not just windowed ones.
    @MainActor
    private func drainRunningVMs() async {
        let ids = runningSessions.values
            .filter { $0.sandbox.vm?.state == .running }
            .map { $0.profileID }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                let action = runningSessions[id]?.profile.closeAction ?? .suspend
                group.addTask { @MainActor in await self.stopSession(id, action: action) }
            }
        }
    }

    private static func forceStop(_ vm: VZVirtualMachine) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vm.stop { _ in cont.resume() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nuke our private ssh-agent. The orphaned-process risk is
        // small (it's idle and tiny) but worth tidying up at least
        // for the clean-quit path.
        mitmEngine?.privateAgent.terminate()
        // Synchronously kill the local inference engine — a detached
        // Task wouldn't run before the process exits, orphaning vllm-mlx
        // (and its large RAM footprint).
        InferenceService.killIfRunning()
        // Tear down the optional SSH front door so we don't orphan sshd,
        // and its Cloudflare tunnel so we don't orphan cloudflared.
        RemoteAccessServer.shared.stop()
        CloudflareTunnelSupervisor.killIfRunning()
    }

    /// Catch the catchable abnormal-termination signals so we still
    /// run ssh-agent cleanup before dying. Without this, anything
    /// other than a user-initiated ⌘Q (which goes through
    /// `applicationWillTerminate`) — a SIGTERM from `kill`, a Ctrl-C
    /// in the terminal launching us, a `pkill`, an enclosing
    /// `launchctl` stop — orphans `/usr/bin/ssh-agent` because the
    /// default disposition just exits the process.
    ///
    /// SIGKILL and macOS jetsam (low-memory kill) are uncatchable;
    /// `PrivateSSHAgent.reapOrphans()` at the next launch is the
    /// safety net for those.
    private func installCleanupSignalHandlers() {
        let catchable: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for sig in catchable {
            // `signal(sig, SIG_IGN)` first so the default
            // disposition doesn't kill us in the window between this
            // function returning and the dispatch source activating
            // (or in case the source is somehow released early).
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                FileHandle.standardError.write(Data(
                    "[bromure-ac] caught signal \(sig); terminating ssh-agent + engine + exiting\n".utf8))
                self?.mitmEngine?.privateAgent.terminate()
                InferenceService.killIfRunning()
                CloudflareTunnelSupervisor.killIfRunning()
                // Exit with a non-zero code so callers can distinguish
                // signal-driven shutdown from a clean ⌘Q.
                exit(128 + sig)
            }
            src.activate()
            cleanupSignalSources.append(src)
        }
    }

    /// Vetoable close. For VM session windows we always confirm, because
    /// closing tears down the disposable VM and any unsaved guest state
    /// goes with it. The picker / inspector windows close freely.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The setup/picker window during an in-flight rebuild: the
        // install Task keeps pushing model updates to a SwiftUI view
        // that's about to be torn down — that's been observed to
        // over-release in the autorelease pool. Confirm + cancel the
        // Task; instead of closing the window, swap its contentView
        // back to the picker (or setup, if no image yet) so the user
        // lands somewhere usable rather than on a closed window.
        if sender === mainWindow, let task = installTask {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Cancel base-image rebuild?", comment: "")
            alert.informativeText = NSLocalizedString(
                "The image will be left in an incomplete state. You'll need to re-run the rebuild before launching new sessions.",
                comment: "")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Cancel rebuild", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Keep building", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            task.cancel()
            self.installTask = nil
            initProgress.stop()
            initProgress.isRunning = false
            if imageManager.hasBaseImage {
                // The previous base image is still usable — drop the installer
                // window and return to the unified home.
                self.mainWindow = nil
                showUnifiedWindowAsHome()
                return true
            }
            renderSetup()
            return false
        }

        guard let session = sender as? TabbedSessionWindow else { return true }
        // Resolve the profile's "When closing the window" preference (.ask is
        // turned into a prompt). nil = the user cancelled → keep the window open.
        guard let action = resolveCloseAction(for: session) else { return false }
        session.closeIntent = action
        return true
    }

    /// Resolve a session window's close action from its profile preference,
    /// prompting when it's `.ask`. Returns nil if the user cancelled.
    @MainActor private func resolveCloseAction(for session: TabbedSessionWindow) -> Profile.CloseAction? {
        let pref = session.profile.closeAction
        guard pref == .ask else { return pref }
        return promptCloseAction(for: session)
    }

    /// Three-way prompt for `.ask` profiles (+ Cancel). Returns the chosen
    /// action, or nil on cancel.
    @MainActor private func promptCloseAction(for session: TabbedSessionWindow) -> Profile.CloseAction? {
        promptCloseAction(forName: session.profile.name)
    }

    @MainActor private func promptCloseAction(forName name: String) -> Profile.CloseAction? {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Close “%@”?", comment: ""), name)
        alert.informativeText = NSLocalizedString(
            "Run in the background keeps the VM running so you can reattach later. Suspend saves its state to disk. Shut down powers it off.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Run in the Background", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Suspend", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Shut Down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .background
        case .alertSecondButtonReturn: return .suspend
        case .alertThirdButtonReturn:  return .shutdown
        default:                       return nil
        }
    }

    // MARK: - `bromure-cli` command-line tool

    /// Offer to symlink `/usr/local/bin/bromure-cli` → this app's binary so the
    /// user can drive Bromure from the terminal. Prompts once; "Don't Ask Again"
    /// is remembered. Skipped for the headless agent and dev (`swift run`) builds.
    @MainActor private func offerCLISymlinkIfNeeded() {
        guard !headless else { return }
        let linkPath = "/usr/local/bin/bromure-cli"
        guard !FileManager.default.fileExists(atPath: linkPath) else { return }
        guard !UserDefaults.standard.bool(forKey: "cliSymlinkDeclined") else { return }
        // Only when running from an installed .app, not a dev `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let exe = Bundle.main.executableURL?.path else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Install the “bromure-cli” command-line tool?", comment: "")
        alert.informativeText = NSLocalizedString(
            "This creates a symlink at /usr/local/bin/bromure-cli so you can drive Bromure from the terminal (vm, exec, trace, …). It needs your admin password once.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Install", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don’t Ask Again", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installCLISymlink(target: exe, at: linkPath)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "cliSymlinkDeclined")
        default:
            break   // Not Now — offer again next launch
        }
    }

    /// Create the symlink via AppleScript so macOS shows the standard admin
    /// authorization prompt (no embedded privileged helper needed).
    @MainActor private func installCLISymlink(target: String, at linkPath: String) {
        let cmd = "mkdir -p /usr/local/bin && ln -sf \\\"\(target)\\\" \(linkPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            // -128 = the user cancelled the admin prompt; anything else is a real
            // failure worth logging (but never block startup over it).
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -128 {
                FileHandle.standardError.write(Data(
                    "[cli] symlink install failed: \(error)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data(
                "[cli] installed \(linkPath) → \(target)\n".utf8))
        }
    }

    // MARK: - Boot at startup

    /// Install/remove the login LaunchAgent to match whether any profile wants
    /// startup boot. Called at launch and whenever a profile is saved.
    @MainActor func reconcileBootLaunchAgent() {
        BootLaunchAgent.reconcile(
            wantsStartupBoot: profiles.contains { $0.bootAtStartup },
            agentExecutable: Bundle.main.executableURL)
    }

    /// Boot every profile flagged `bootAtStartup`, detached (window-less). Only
    /// the headless login agent does this: the GUI doesn't auto-boot when the
    /// user opens it, and gating to the one process that the LaunchAgent starts
    /// avoids two agents racing to boot the same profile onto the same disk.
    @MainActor private func bootFlaggedProfilesAtStartup() {
        guard headless else { return }
        for profile in profiles where profile.bootAtStartup {
            guard runningSessions[profile.id] == nil else { continue }
            FileHandle.standardError.write(Data(
                "[boot] starting '\(profile.name)' at login\n".utf8))
            // `detached: true` boots window-less and leaves the app in its
            // `.accessory` (menu-bar-only) state — without it the unified window
            // pops up at login and promotes the app to a regular Dock app.
            launch(profile, detached: true)
            detachAfterBoot(profile.id)   // belt-and-suspenders; no window to close now
        }
    }

    /// Once the session for `id` registers, close its (possibly never-shown)
    /// window so the VM runs detached in the background. No-op if already
    /// detached. Used by start-in-background launches and login boots.
    @MainActor private func detachAfterBoot(_ id: Profile.ID) {
        Task { @MainActor in
            for _ in 0..<600 {   // up to ~60s for the first boot to register
                if runningSessions[id] != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let win = profileWindows[id] { win.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        // Registration throwaway window: route to its own teardown (destroys
        // the scratch VM + dir) instead of the normal per-profile session
        // cleanup, which would suspend/save state and could terminate the app.
        if let reg = claudeRegistration, win === reg.window {
            teardownClaudeRegistration(reason: .windowClosed)
            return
        }
        if win === mainWindow {
            mainWindow = nil
            updateActivationPolicy()
            return
        }
        if win === credentialApprovalsWindow {
            credentialApprovalsWindow = nil
            return
        }
        if win === supplyChainLogWindow {
            supplyChainLogWindow = nil
            return
        }
        if win === inferenceLogWindow {
            inferenceLogWindow = nil
            return
        }
        if win === traceInspectorWindow {
            traceInspectorWindow = nil
            return
        }
        if win === enrollmentWindow {
            enrollmentWindow = nil
            return
        }
        if let key = fileBrowserWindows.first(where: { $0.value === win })?.key {
            fileBrowserWindows[key] = nil
            return
        }
        if win === unifiedWindow {
            // Closing the shared window detaches every hosted VM to the
            // background (persistent-agent model): the VMs keep running and are
            // reattachable via the menu bar / `vm attach`. Per-VM stop happens
            // via the sidebar's × control, not by closing the whole window.
            let ids = panes.values
                .filter { $0.host === unifiedWindow }
                .map { $0.profile.id }
            for id in ids { detachSession(id) }
            updateActivationPolicy()
            return
        }
        if let session = win as? TabbedSessionWindow {
            // Re-dock in flight: the pane was already handed back to the unified
            // window. Don't touch the VM — just forget the popped-out window.
            if session.redocking {
                profileWindows.removeValue(forKey: session.profile.id)
                updateActivationPolicy()
                return
            }
            // Always tear down the window UI + snapshot tabs (so a reattaching
            // window rebuilds the bar against the kittys still alive in the
            // guest). Then act on the VM per the resolved close action.
            let id = session.profile.id
            if runningSessions[id] != nil {
                runningSessions[id]?.lastTabsSnapshot = session.snapshotTabs()
            }
            session.sandbox = nil
            profileWindows.removeValue(forKey: id)
            unregisterPane(id, ifMatches: session.pane)
            // `.background` (and a programmatic close, closeIntent == nil) leave
            // the VM running, detached. `.suspend` / `.shutdown` stop it via the
            // explicit stop path. `.ask` was already resolved in
            // windowShouldClose, so it never reaches here.
            switch session.closeIntent {
            case .suspend, .shutdown:
                if let action = session.closeIntent, runningSessions[id]?.stopping != true {
                    requestStopSession(id, action: action)
                }
            case .background, .ask, .none:
                break
            }
            session.closeIntent = nil
            refreshSidebar()
            updateStatusMenu()
            updateActivationPolicy()
        }
    }

    // MARK: - Screen wiring

    /// The setup/progress window (`mainWindow`). Created by the first-run
    /// path at launch; re-created on demand when an update or postinstall
    /// flow starts from the unified home, where no setup window exists.
    private func ensureInstallWindow() {
        if mainWindow != nil { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Bromure Agentic Coding"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        // See TabbedSessionWindow for the same fix: AppKit's window
        // close animator can over-release captured block ivars when
        // SwiftUI tears the contentView down concurrently (most
        // visible when the user closes this window mid-rebuild while
        // the InitProgressModel is still updating).
        window.animationBehavior = .none
        // We hold a strong reference (`self.mainWindow = window`).
        // NSWindow defaults to `isReleasedWhenClosed = true` for
        // non-controller windows, which would autorelease the window
        // on close and double-free it against our strong ref —
        // crashing in the next autorelease pool drain. Disable.
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window
    }

    private func renderSetup() {
        guard let win = mainWindow else { return }
        win.title = "Bromure Agentic Coding"
        // Same ordering trap as renderPicker: must swap content view
        // first, otherwise the InitializingView's autolayout
        // constraints + contentMinSize=560 (set in renderInitializing)
        // pin the window above the 540 we want here. Cancel-during-
        // bake therefore left the welcome screen oversized.
        win.contentView = NSHostingView(rootView: SetupView(onStart: { [weak self] in
            self?.startInit()
        }))
        win.contentMinSize = .zero
        win.setContentSize(NSSize(width: 560, height: 500))
        win.center()
    }

    private func renderInitializing(
        title: String = "Building base image",
        subtitle: String = "This is the one-time install. Don't close the window."
    ) {
        guard let win = mainWindow else { return }
        win.title = "Bromure Agentic Coding — Setup"
        // Sized to the InitializingView's intrinsic layout (header +
        // status pill + 280pt fixed console + footer + paddings). The
        // user can collapse the console disclosure to shrink further.
        let style = win.styleMask.union(.resizable)
        win.styleMask = style
        win.setContentSize(NSSize(width: 640, height: 480))
        win.contentMinSize = NSSize(width: 560, height: 240)
        win.center()
        win.contentView = NSHostingView(rootView: InitializingView(
            model: initProgress,
            title: title,
            subtitle: subtitle,
            onCancel: { [weak self] in self?.renderSetup() }
        ))
    }

    private func startInit(force: Bool = false, buildLocal: Bool = false) {
        // Note: we do NOT delete the version stamp here even when
        // force == true. The stamp gates whether existing sessions
        // can launch from the old image — wiping it would brick the
        // image the moment the user clicks "Rebuild Now". Both install
        // paths use .partial files and only swap + rewrite the stamp
        // when the new image is fully in place.
        initProgress.reset()
        ensureInstallWindow()
        renderInitializing()

        // No SSH front door while the image is being installed — a remote
        // session could otherwise launch workspaces against a base that's
        // absent or mid-swap. Resumed (when still enabled) by the defer.
        if RemoteAccessServer.shared.isRunning {
            SupplyChainLog.shared.record("[remote] SSH front door paused for base-image install.")
            stopRemoteAccess()
        }

        installTask = Task { @MainActor in
            defer {
                self.installTask = nil
                self.startRemoteAccessIfNeeded()
            }
            // High-level checkpoints: drive the status pill + weighted
            // progress bar + bookmark the console log with a leading
            // marker so they're easy to find in the firehose.
            let progressCB: (String) -> Void = { msg in
                Task { @MainActor in
                    // Suppress updates after cancellation — the hosted
                    // SwiftUI view is being torn down on the same run
                    // loop tick and we don't want the observation chain
                    // over-releasing.
                    guard self.installTask != nil else { return }
                    self.initProgress.noteHostProgress(msg)
                }
            }
            // Raw guest serial bytes — append as-is so timing and apt's
            // progress lines look the same as on stderr.
            let outputCB: (String) -> Void = { chunk in
                Task { @MainActor in
                    guard self.installTask != nil else { return }
                    self.initProgress.appendLog(chunk)
                }
            }
            do {
                if buildLocal {
                    try await self.buildBaseImageLocally(
                        force: force, progress: progressCB, output: outputCB)
                } else {
                    do {
                        try await self.imageManager.downloadBaseImage(
                            progress: progressCB, output: outputCB)
                    } catch let error where UbuntuImageManager.isDownloadSideFailure(error) {
                        // No prebuilt image reachable (offline, CDN
                        // outage, bad artifact) — the one class of
                        // failure where a local build is a genuine
                        // remedy. Never fall back silently: from the
                        // user's perspective the download may have just
                        // "finished" (checksum/expansion failures land
                        // after the transfer), and rolling straight into
                        // a 10-minute Alpine + debootstrap bake reads as
                        // the download restarting itself.
                        guard self.confirmLocalBuildFallback(for: error) else {
                            throw error
                        }
                        progressCB("Download unavailable (\(error.localizedDescription)) — building locally instead…")
                        try await self.buildBaseImageLocally(
                            force: force, progress: progressCB, output: outputCB)
                    }
                    // Anything else — the postinstall VM failing, disk
                    // space, cancellation — propagates: the local bake
                    // runs the same machinery and would fail the same
                    // way, ten minutes later.
                }
                self.initProgress.stop()
                self.initProgress.isRunning = false
                FileHandle.standardError.write(Data(
                    "[init] line count: \(self.initProgress.linesSeen)\n".utf8))
                self.profiles = self.store.loadAll()
                // Base image is ready — close the installer window and open the
                // unified home (the standalone picker is gone).
                if let w = self.mainWindow { w.close() }
                self.mainWindow = nil
                self.showUnifiedWindowAsHome()
                if self.profiles.isEmpty { self.openEditorWindow(editing: nil) }
            } catch {
                self.initProgress.stop()
                self.initProgress.isRunning = false
                self.initProgress.error = error.localizedDescription
                // The bake's NAT path can't be repaired mid-flight — we
                // need to tear it down, kickstart vmnet, and start over.
                // Same UX as the session-side network-healer prompt.
                if case UbuntuImageError.noGuestNetwork = error {
                    await self.presentBakeNetworkHealerPrompt(force: force)
                }
            }
        }
    }

    /// The prebuilt-image download failed. Offer the local bake — with
    /// the actual error front and center — instead of starting it
    /// silently.
    private func confirmLocalBuildFallback(for error: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Image download failed", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString(
                "%@\n\nBromure can build the image locally instead (~10 min, same result).",
                comment: "Base-image download failed; offer the local build"),
            error.localizedDescription)
        alert.addButton(withTitle: NSLocalizedString("Build Locally", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Local build with the img-catalog postinstall steps applied on top —
    /// the fallback when the prebuilt-image download isn't available, and
    /// the explicit "Rebuild Locally" menu path. A new installation runs
    /// every step without an extra prompt: the setup screen the user
    /// clicked through is the consent for the initial set.
    private func buildBaseImageLocally(
        force: Bool,
        progress: @escaping (String) -> Void,
        output: @escaping (String) -> Void
    ) async throws {
        var catalog = ImageCatalogStore.shared.remote()
        if catalog == nil { catalog = await ImageCatalogStore.shared.refresh() }
        let steps = (catalog ?? ImageCatalogStore.shared.effective()).sortedSteps
        try await imageManager.createBaseImage(
            progress: progress,
            output: output,
            force: force,
            postinstallSteps: steps
        )
    }

    /// Run user-accepted postinstall steps against the existing base
    /// image, reusing the install progress window. The image is amended
    /// on an APFS clone and swapped atomically, so sessions launched
    /// meanwhile keep a bootable base.
    private func startPostinstall(_ steps: [PostinstallStep]) {
        initProgress.reset()
        ensureInstallWindow()
        renderInitializing(
            title: "Installing recommended packages",
            subtitle: "The base image is being amended. Existing workspaces keep working."
        )
        NSApp.activate(ignoringOtherApps: true)

        // Same SSH pause as startInit — base.img is being amended + swapped.
        if RemoteAccessServer.shared.isRunning {
            SupplyChainLog.shared.record("[remote] SSH front door paused for base-image install.")
            stopRemoteAccess()
        }

        installTask = Task { @MainActor in
            defer {
                self.installTask = nil
                self.startRemoteAccessIfNeeded()
            }
            do {
                try await self.imageManager.applyPostinstallSteps(
                    steps,
                    progress: { msg in
                        Task { @MainActor in
                            guard self.installTask != nil else { return }
                            self.initProgress.noteHostProgress(msg)
                        }
                    },
                    output: { chunk in
                        Task { @MainActor in
                            guard self.installTask != nil else { return }
                            self.initProgress.appendLog(chunk)
                        }
                    }
                )
                self.initProgress.stop()
                self.initProgress.isRunning = false
                if let w = self.mainWindow { w.close() }
                self.mainWindow = nil
            } catch {
                self.initProgress.stop()
                self.initProgress.isRunning = false
                self.initProgress.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func presentBakeNetworkHealerPrompt(force: Bool) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Network Issue During Base-Image Build", comment: "")
        alert.informativeText = NSLocalizedString(
            "The installer VM didn't get a network address from macOS's shared networking (vmnet). The base-image build needs internet access to download packages.",
            comment: ""
        ) + "\n\n" + NSLocalizedString(
            "Bromure can restart the macOS networking daemons and try the build again. You'll be asked for your password.",
            comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Repair and Retry", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let ok = await NetworkHealer.shared.repair(.both)
            guard ok else {
                let failed = NSAlert()
                failed.messageText = NSLocalizedString(
                    "Network Repair Cancelled", comment: "")
                failed.informativeText = NSLocalizedString(
                    "The repair was cancelled or failed. Try again from the menu.",
                    comment: "")
                failed.alertStyle = .warning
                failed.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                failed.runModal()
                return
            }
            startInit(force: force)
        default:
            return
        }
    }

    /// Insert (or refresh) the "Check for Updates…" item directly
    /// after "About …". Idempotent — drops any prior copy first so
    /// repeat calls don't stack duplicates. No-op if the updater
    /// hasn't been initialised (dev builds without SUPublicEDKey).
    fileprivate func installCheckForUpdatesMenuItem(into appMenu: NSMenu) {
        guard let updater = updaterController else { return }
        appMenu.items
            .filter { ($0.representedObject as? String) == "bromure.checkForUpdates" }
            .forEach { appMenu.removeItem($0) }
        let item = NSMenuItem(
            title: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        item.target = updater
        item.representedObject = "bromure.checkForUpdates"
        // Slot the item right after "About …". The two slots before it
        // are: 0 = About, 1 = separator (added in makeMainMenu).
        let insertIdx = min(2, appMenu.items.count)
        appMenu.insertItem(item, at: insertIdx)
        appMenu.insertItem(.separator(), at: insertIdx + 1)
    }

    /// Insert (or refresh) the "Enroll in bromure.io…" / "bromure.io
    /// Enrollment…" item directly under "Check for Updates…". When the
    /// updater hasn't been initialised (dev build), fall back to
    /// inserting just after About — the two layouts converge once
    /// `installCheckForUpdatesMenuItem` runs and pushes everyone down.
    /// Idempotent so re-running doesn't stack duplicates.
    fileprivate func installEnrollmentMenuItem(into appMenu: NSMenu) {
        appMenu.items
            .filter { ($0.representedObject as? String) == "bromure.enrollment" }
            .forEach { appMenu.removeItem($0) }
        let title = BACEnrollmentStore.load() == nil
            ? NSLocalizedString("Enroll in bromure.io…", comment: "")
            : NSLocalizedString("bromure.io Enrollment…", comment: "")
        let item = NSMenuItem(
            title: title,
            action: #selector(ACAppDelegate.openEnrollmentAction(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = "bromure.enrollment"
        let updaterIdx = appMenu.items.firstIndex {
            ($0.representedObject as? String) == "bromure.checkForUpdates"
        }
        // Right after Check for Updates… when present; otherwise the
        // slot just after "About + separator". `min` keeps us in
        // bounds on the still-being-built menu.
        let insertIdx: Int
        if let updaterIdx { insertIdx = updaterIdx + 1 }
        else { insertIdx = min(2, appMenu.items.count) }
        appMenu.insertItem(item, at: insertIdx)
    }

    /// Wired to the "Rebuild Base Image…" menu item. Confirms, then
    /// runs `init --force` from inside the GUI — same flow as the
    /// first-time setup, but proactive.
    private var traceInspectorWindow: NSWindow?
    private var inferenceMetricsWindow: NSWindow?
    private var credentialApprovalsWindow: NSWindow?
    private var enrollmentWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var remoteAccessWindow: NSWindow?
    private var supplyChainLogWindow: NSWindow?
    private var inferenceLogWindow: NSWindow?
    /// File-browser panels, one per profile (keyed by profile id) so each
    /// session window gets its own, reused on subsequent clicks.
    private var fileBrowserWindows: [UUID: NSWindow] = [:]

    /// Wired to the "Trace Inspector…" menu item (⇧⌘I).
    /// Opens the inspector with no profile pre-filter.
    @objc func openInferenceMetricsAction(_ sender: Any?) {
        if let win = inferenceMetricsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Inference Metrics", comment: "")
        win.center()
        win.contentView = NSHostingView(rootView: InferenceMetricsView())
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inferenceMetricsWindow = win
    }

    @objc func openTraceInspectorAction(_ sender: Any?) {
        openTraceInspector(for: nil)
    }

    /// Window menu → "Credential Approvals…". Lists every live consent
    /// grant (5 min / 1 hr / rest of session) with per-row Revoke and a
    /// "Revoke all" reset.
    @objc func openCredentialApprovalsAction(_ sender: Any?) {
        guard let broker = mitmEngine?.consent else { return }
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })

        if let win = credentialApprovalsWindow {
            win.contentView = NSHostingView(rootView: CredentialApprovalsView(
                broker: broker, profileNames: names,
                onClose: { [weak self] in self?.credentialApprovalsWindow = nil }))
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Credential Approvals", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: CredentialApprovalsView(
            broker: broker, profileNames: names,
            onClose: { [weak self] in self?.credentialApprovalsWindow = nil }))
        win.makeKeyAndOrderFront(nil)
        credentialApprovalsWindow = win
    }

    /// Window menu → "Supply Chain Log…". A live `tail -f` of every
    /// supply-chain event the MITM proxy emits (socket.dev checks,
    /// OSV checks, age-gate / install-script / 451 actions). One
    /// window app-wide; reopening brings it forward.
    @objc func openSupplyChainLogAction(_ sender: Any?) {
        if let win = supplyChainLogWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Security Log", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SupplyChainLogView(
            onClose: { [weak self] in self?.supplyChainLogWindow = nil }))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        supplyChainLogWindow = win
    }

    /// Window menu → "Inference Engine Log…". A live tail of the on-device MLX
    /// engine's output (model load, "serving", OOM/crash, load errors) — so
    /// diagnosing a local-model problem doesn't mean digging through Console.
    /// One window app-wide; reopening brings it forward.
    @objc func openInferenceLogAction(_ sender: Any?) {
        if let win = inferenceLogWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Inference Engine Log", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: LogConsoleView.inferenceEngine())
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inferenceLogWindow = win
    }

    /// Window menu → "Enroll in bromure.io…" / "bromure.io Enrollment".
    /// The same menu item swaps between two views depending on state:
    /// the entry sheet when not enrolled, the status panel when
    /// enrolled. Title is refreshed by `refreshEnrollmentMenuTitle()`
    /// whenever state changes.
    @objc func openEnrollmentAction(_ sender: Any?) {
        if let win = enrollmentWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("bromure.io Enrollment", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = makeEnrollmentContentView(in: win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enrollmentWindow = win
    }

    private func makeEnrollmentContentView(in window: NSWindow) -> NSView {
        if BACEnrollmentStore.load() == nil {
            return NSHostingView(rootView: BACEnrollmentSheet { [weak self, weak window] _ in
                window?.close()
                self?.enrollmentWindow = nil
                self?.refreshEnrollmentMenuTitle()
            })
        }
        return NSHostingView(rootView: BACEnrollmentStatusView { [weak self, weak window] in
            // After unenroll, swap the same window's content to the
            // entry sheet rather than closing — the user almost
            // certainly wanted to re-enroll against a different code
            // or workspace.
            guard let window else { return }
            window.contentView = self?.makeEnrollmentContentView(in: window)
            self?.refreshEnrollmentMenuTitle()
        })
    }

    /// Recompute (a) the private-profile set the cloud emitter
    /// gates on, and (b) the streaming flag every open session
    /// window's toolbar paints. Cheap — runs after profile load,
    /// after a profile save / delete, and after enrollment state
    /// changes. Single source of truth: `profiles` (the loaded
    /// store) + `BACEnrollmentStore.load()`.
    func refreshStreamingState() {
        let privateIDs = Set(profiles.filter { $0.privateMode }.map { $0.id })
        BACEventEmitter.shared.setPrivateProfiles(privateIDs)
        let enrolled = BACEnrollmentStore.load() != nil
        for (profileID, pane) in panes {
            pane.model.streamingActive = enrolled && !privateIDs.contains(profileID)
        }
    }

    /// Update the menu item label so it reflects the current state
    /// without the user having to open the window. Called from the
    /// state-change callback set up in `applicationDidFinishLaunching`.
    func refreshEnrollmentMenuTitle() {
        guard let main = NSApp.mainMenu, let windowMenu = NSApp.windowsMenu else { return }
        for item in windowMenu.items + (main.items.flatMap { $0.submenu?.items ?? [] }) {
            guard item.action == #selector(openEnrollmentAction(_:)) else { continue }
            item.title = BACEnrollmentStore.load() == nil
                ? NSLocalizedString("Enroll in bromure.io…", comment: "")
                : NSLocalizedString("bromure.io Enrollment…", comment: "")
        }
    }

    // MARK: - Workspaces menu

    /// What the Workspaces menu (and its bounced ⇧⌘N/⇧⌘G/⇧⌘M chords) act on:
    /// the unified window's selected workspace, its pane, and the active tab
    /// index. nil when nothing is selected/running.
    private func currentWorkspaceContext() -> (id: Profile.ID, pane: SessionPane, index: Int)? {
        guard let id = unifiedWindow?.selectedID, let pane = panes[id] else { return nil }
        return (id, pane, pane.model.activeIndex)
    }

    @objc func newWorkspaceAction(_ sender: Any?) { openEditorWindow(editing: nil) }

    @objc func newTabAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() { spawnNewTab(in: ctx.pane) }
    }

    @objc func addTerminalToGridAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() { addActiveTerminalToGrid(in: ctx.pane) }
    }

    @objc func deleteWorkspaceAction(_ sender: Any?) {
        if let id = unifiedWindow?.selectedID, let p = profiles.first(where: { $0.id == id }) {
            deleteProfile(p)
        }
    }

    @objc func newWorktreeAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() {
            unifiedWindow?.handleTabAction(profileID: ctx.id, index: ctx.index, action: .newWorktree)
        }
    }
    @objc func mergeWorktreeAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() {
            unifiedWindow?.handleTabAction(profileID: ctx.id, index: ctx.index, action: .merge)
        }
    }
    @objc func discardWorktreeAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() {
            unifiedWindow?.handleTabAction(profileID: ctx.id, index: ctx.index, action: .removeWorktree)
        }
    }
    @objc func attachTerminalAction(_ sender: Any?) {
        if let ctx = currentWorkspaceContext() {
            unifiedWindow?.handleTabAction(profileID: ctx.id, index: ctx.index, action: .attachTerminal)
        }
    }

    /// Grey out Workspaces items that don't apply to the current selection/tab.
    /// Only affects items targeting this delegate; everything else stays enabled.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newTabAction(_:)), #selector(deleteWorkspaceAction(_:)):
            return unifiedWindow?.selectedID != nil
        case #selector(addTerminalToGridAction(_:)):
            guard let ctx = currentWorkspaceContext(),
                  ctx.pane.model.tabs.indices.contains(ctx.index) else { return false }
            return ctx.pane.model.tabs[ctx.index].containerID == nil
        case #selector(newWorktreeAction(_:)):
            guard let ctx = currentWorkspaceContext(),
                  ctx.pane.model.tabs.indices.contains(ctx.index) else { return false }
            let t = ctx.pane.model.tabs[ctx.index]
            return t.isGitRepo || t.isWorktree   // a worktree tab can nest another
        case #selector(mergeWorktreeAction(_:)), #selector(discardWorktreeAction(_:)),
             #selector(attachTerminalAction(_:)):
            guard let ctx = currentWorkspaceContext(),
                  ctx.pane.model.tabs.indices.contains(ctx.index) else { return false }
            return ctx.pane.model.tabs[ctx.index].isWorktree
        default:
            return true
        }
    }

    /// Window menu → "Profile Manager". With a base image this is the unified
    /// window (the home — the standalone picker is gone); before the base
    /// image exists it's the setup window, recreated if the user closed it.
    @objc func openProfileManagerAction(_ sender: Any?) {
        // Promote back to a regular (Dock-visible) app — we may be coming from
        // the status item while running as a background agent.
        NSApp.setActivationPolicy(.regular)
        if imageManager.hasBaseImage {
            showUnifiedWindowAsHome()
            return
        }
        // No base image yet — show (or recreate) the setup window.
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Bromure Agentic Coding"
        win.delegate = self
        win.titlebarAppearsTransparent = false
        win.animationBehavior = .none
        win.center()
        win.isReleasedWhenClosed = false
        self.mainWindow = win
        renderSetup()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or focus) the unified window as the app's home, populated with the
    /// full profile list. Replaces the old standalone picker.
    func showUnifiedWindowAsHome() {
        NSApp.setActivationPolicy(.regular)
        let w = ensureUnifiedWindow()
        refreshSidebar()
        // Pick a sensible initial selection so the stage isn't blank: a running
        // attached pane keeps its own; otherwise show the first profile's card.
        if w.selectedID == nil, let first = w.listModel.profileRows.first {
            w.selectRow(first.id)
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or focus) the Trace Inspector window. Pass a profile to
    /// pre-fill the profile filter — used by the session window's
    /// toolbar button so clicking it on a profile's window scopes the
    /// inspector to that profile. Pass nil for the "all profiles" view.
    func openTraceInspector(for profile: Profile?) {
        if let win = traceInspectorWindow {
            // Existing window — re-host with the new filter so the
            // user always lands on the profile they clicked from.
            if let store = mitmEngine?.traceStore {
                win.contentView = NSHostingView(rootView: TraceInspectorView(
                    store: store, profiles: profiles,
                    initialProfileFilter: profile?.id))
            }
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let store = mitmEngine?.traceStore else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = NSLocalizedString("Trace Inspector", comment: "")
        win.center()
        win.contentView = NSHostingView(rootView: TraceInspectorView(
            store: store,
            profiles: profiles,
            initialProfileFilter: profile?.id
        ))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        traceInspectorWindow = win
    }

    /// Open (or re-focus) a Finder-like browser over this profile's VM
    /// filesystem. The guest's /home/ubuntu and any shared folders are
    /// host directories mounted via virtiofs, so the panel just reads
    /// and writes them directly — dragging a file out copies it to the
    /// Mac, dropping one in drops it into the VM.
    /// Title-bar lightning toggle → push the engaged/disengaged state
    /// into the MITM engine so the proxy hot path picks it up live.
    func setFusionEngaged(_ engaged: Bool, for profile: Profile) {
        mitmEngine?.setFusionEngaged(engaged, for: profile.id)
        runningSessions[profile.id]?.fusionEngaged = engaged
        // Keep the attached window's title-bar toggle in sync (e.g. when the
        // change came from the CLI rather than the toggle itself).
        pane(for: profile.id)?.model.fusionEngaged = engaged
    }

    func openFileBrowser(for window: TabbedSessionWindow) {
        openFileBrowser(profile: window.profile)
    }

    func openFileBrowser(profile: Profile) {
        if let win = fileBrowserWindows[profile.id] {
            win.makeKeyAndOrderFront(nil)
            return
        }

        // Home browses the guest's REAL /home/ubuntu over the vsock file
        // service — required for ext4-model homes (they live inside
        // home.img, invisible to macOS) and used for legacy virtiofs
        // workspaces too so there's one code path that always shows what
        // the guest sees.
        var locations: [FileBrowserLocation] = [
            FileBrowserLocation(
                name: NSLocalizedString("Home", comment: ""),
                backing: .guest,
                guestPath: "/home/ubuntu",
                symbol: "house")
        ]
        // Shared folders are symlinked to ~/<basename> inside the guest
        // on first boot — they're real host dirs, so browse them directly
        // (drag-out hands Finder the actual file; Reveal works).
        for path in profile.folderPaths.prefix(8) {
            let base = (path as NSString).lastPathComponent
            locations.append(FileBrowserLocation(
                name: base,
                backing: .host(URL(fileURLWithPath: path)),
                guestPath: "/home/ubuntu/\(base)",
                symbol: "folder"))
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(
            format: NSLocalizedString("Files — %@", comment: "file browser title"),
            profile.name)
        win.center()
        win.animationBehavior = .none
        let profileID = profile.id
        win.contentView = NSHostingView(rootView: FileBrowserView(
            model: FileBrowserModel(
                locations: locations,
                cacheKey: profileID.uuidString,
                guestOp: { [weak self] op in
                    guard let self else {
                        throw GuestExecError.vmNotRunning
                    }
                    return try await self.guestFileOp(profileID: profileID, op: op)
                })))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        fileBrowserWindows[profile.id] = win
    }

    @objc func openPreferencesAction(_ sender: Any?) {
        if let win = preferencesWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Bromure — Preferences",
                                       comment: "Preferences window title")
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        let template = store.loadTemplate()
        win.contentView = NSHostingView(rootView: ProfileEditorView(
            profile: template,
            terminalDefaults: terminalDefaults,
            storageContext: nil,
            onSave: { [weak self] updated, _ in
                guard let self else { return }
                do {
                    try self.store.saveTemplate(updated)
                } catch {
                    self.showError(error,
                                    message: "Couldn't save preferences.")
                    return
                }
                self.preferencesWindow?.close()
                self.preferencesWindow = nil
            },
            onCancel: { [weak self] in
                self?.preferencesWindow?.close()
                self?.preferencesWindow = nil
            },
            claudeAccountSavedAt: { [weak self] in self?.mitmEngine?.claudeSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterClaude: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .claude, scope: .alwaysShared)
            },
            onForgetClaude: { [weak self] in
                try? self?.mitmEngine?.claudeSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            codexAccountSavedAt: { [weak self] in self?.mitmEngine?.codexSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterCodex: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .codex, scope: .alwaysShared)
            },
            onForgetCodex: { [weak self] in
                try? self?.mitmEngine?.codexSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            grokAccountSavedAt: { [weak self] in self?.mitmEngine?.grokSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterGrok: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .grok, scope: .alwaysShared)
            },
            onForgetGrok: { [weak self] in
                try? self?.mitmEngine?.grokSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            onFetchFusionModels: { provider, authMode, apiKey, completion in
                Task {
                    let m = await Fusion.listModels(provider: provider, authMode: authMode,
                                                    apiKey: apiKey, profileID: nil)
                    await MainActor.run { completion(m) }
                }
            }
        ))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = win
    }

    @objc func openRemoteAccessAction(_ sender: Any?) {
        if let win = remoteAccessWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Remote Access", comment: "Remote access window title")
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: RemoteAccessSettingsView(
            status: { [weak self] in MainActor.assumeIsolated { self?.remoteAccessStatus() ?? [:] } },
            apply: { [weak self] spec in MainActor.assumeIsolated { self?.remoteAccessApply(spec) ?? ["error": "unavailable"] } },
            addKey: { [weak self] key in MainActor.assumeIsolated { self?.remoteAccessAddKey(key) ?? ["error": "unavailable"] } },
            removeKey: { [weak self] sel in MainActor.assumeIsolated { self?.remoteAccessRemoveKey(sel) ?? ["error": "unavailable"] } }
        ))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        remoteAccessWindow = win
    }

    @objc func rebuildBaseImageAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Update the base image?"
        alert.informativeText = "Downloads the latest prebuilt image (or re-runs the full local installer, ~5–10 min) and re-applies the recommended packages. Existing workspaces' disks aren't touched — on next launch each one's drift prompt will offer to reset to the new base."
        alert.addButton(withTitle: "Download Prebuilt")
        alert.addButton(withTitle: "Rebuild Locally")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startInit(force: true)
        case .alertSecondButtonReturn:
            startInit(force: true, buildLocal: true)
        default:
            break
        }
    }

    /// Non-blocking nag shown on each launch when the on-disk base image
    /// is older than what's available — either the app ships a newer
    /// `imageVersion`, or img-catalog.json published a newer image
    /// (`catalogVersion`). "Later" dismisses for this launch only — we'll
    /// ask again next time the app starts so the user keeps the option
    /// without being blocked from running stale images.
    private func promptBaseImageUpdate(catalogVersion: String? = nil) {
        let alert = NSAlert()
        let installed = imageManager.installedImageVersion ?? "?"
        let target = catalogVersion ?? UbuntuImageManager.imageVersion
        alert.messageText = NSLocalizedString("Base image update available", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString(
                "Your base image is at version %@ but version %@ is available. The current image still works — updating downloads the new prebuilt image (a few GB; local rebuild as fallback) and re-applies the recommended packages.",
                comment: ""),
            installed, target)
        alert.addButton(withTitle: NSLocalizedString("Update Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            startInit(force: true)
        }
    }

    /// Consent gate for postinstall steps published in img-catalog.json
    /// after this image was installed. They run as root inside the base
    /// image, so nothing executes until the user explicitly accepts.
    /// "Later" asks again next launch.
    private func promptNewPostinstallSteps(_ steps: [PostinstallStep]) {
        let alert = NSAlert()
        let list = steps.map { "• \($0.description)" }.joined(separator: "\n")
        alert.messageText = NSLocalizedString("New recommended packages", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString(
                "New packages are recommended to be installed:\n\n%@\n\nBromure installs them into the base image (a few minutes, in the background VM). Existing workspaces keep running; each one's drift prompt will offer a reset to pick them up.",
                comment: ""),
            list)
        alert.addButton(withTitle: NSLocalizedString("Install", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            startPostinstall(steps)
        }
    }


    /// Deep-copy a profile (new UUID, new MAC) using `ProfileStore.duplicate`.
    /// Includes the system disk + home dir via APFS clonefile, the encrypted
    /// secrets blob, host-only ssh material, and every credential — but
    /// skips the suspended VM state (a snapshot tied to the source's MAC
    /// can't safely resume on the duplicate).
    /// Pick a default name for a brand-new profile that doesn't
    /// collide with any existing profile name. Walks "Default profile",
    /// "Default profile 2", "Default profile 3", … and returns the
    /// first one not currently taken (case-insensitive comparison so
    /// users typing "default profile" don't get an unexpected dupe).
    private func nextDefaultProfileName() -> String {
        let base = NSLocalizedString("Default workspace",
                                      comment: "Placeholder name for a new profile")
        let existing = Set(profiles.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private func duplicateProfile(_ source: Profile) {
        let copyName = source.name + " " + NSLocalizedString("copy", comment: "")
        do {
            _ = try store.duplicate(source, named: copyName)
        } catch {
            showError(error, message: "Couldn't duplicate “\(source.name)”.")
            return
        }
        profiles = store.loadAll()
        refreshSidebar()
    }

    /// editing == nil → create. editing != nil → modify in place.
    func openEditorWindow(editing: Profile?) {
        // Reuse the open editor ONLY when it's already editing this same
        // profile; for a different profile (or a new-profile draft) tear the
        // old one down and rebuild. The previous guard re-surfaced whatever
        // editor was open regardless of `editing`, so once any profile's
        // Settings had been opened, every later "Settings" click re-showed
        // that same window — and since the editor isn't nil'd on a red-button
        // close, it stuck to the first profile edited this session.
        if let existing = editorWindow {
            if editorEditingProfile?.id == editing?.id {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            closeEditorWindow()
        }
        editorEditingProfile = editing

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = editing == nil ? "New workspace" : "Edit workspace"
        win.center()
        // For new profiles, hand the editor a draft pre-populated from
        // the user's preferences template (Bromure → Preferences…)
        // and a numbered placeholder name so the user can save
        // immediately without typing one. Existing profiles keep
        // their own values.
        let initialDraft: Profile? = editing
            ?? store.newProfileFromTemplate(name: nextDefaultProfileName())
        win.contentView = NSHostingView(rootView: ProfileEditorView(
            profile: initialDraft,
            isNew: editing == nil,
            terminalDefaults: terminalDefaults,
            storageContext: makeStorageContext(for: editing),
            onSave: { profile, generateSSH in
                self.handleEditorSave(profile: profile, generateSSH: generateSSH, editing: editing)
            },
            onCancel: { self.closeEditorWindow() },
            onImportSSHKey: { [weak self] url, passphrase, label in
                // Import requires a saved profile (we need an id for
                // the on-disk path + keychain account). For new
                // profiles, save once first.
                guard let self else {
                    throw NSError(domain: "BromureAC", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "App not available"])
                }
                let target = editing ?? self.store.newProfileFromTemplate(name: "")
                if editing == nil {
                    try self.store.save(target)
                }
                return try self.importSSHKey(at: url, passphrase: passphrase,
                                              label: label, for: target)
            },
            onRemoveSSHKey: { [weak self] key in
                guard let self, let editing else { return }
                self.removeImportedSSHKey(key, for: editing)
            },
            claudeAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.claudeSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.claudeSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterClaude: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .claude, scope: .askPerSession(p.id)) }
            },
            onForgetClaude: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.claudeSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            codexAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.codexSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.codexSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterCodex: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .codex, scope: .askPerSession(p.id)) }
            },
            onForgetCodex: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.codexSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            grokAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.grokSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.grokSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterGrok: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .grok, scope: .askPerSession(p.id)) }
            },
            onForgetGrok: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.grokSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            onFetchFusionModels: { provider, authMode, apiKey, completion in
                let pid = (editing ?? initialDraft)?.id
                Task {
                    let m = await Fusion.listModels(provider: provider, authMode: authMode,
                                                    apiKey: apiKey, profileID: pid)
                    await MainActor.run { completion(m) }
                }
            }
        ))
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        editorWindow = win
    }

    /// Snapshot of where this profile's data lives + how to nuke it.
    /// Re-read each time the editor opens so sizes / version reflect the
    /// latest state. Closures route to the existing reset handlers,
    /// which own their own confirmation alerts.
    private func makeStorageContext(for editing: Profile?) -> ProfileStorageContext {
        let baseURL = imageManager.baseDiskURL
        let buildDate = (try? FileManager.default.attributesOfItem(
            atPath: imageManager.versionStampURL.path)[.modificationDate]) as? Date
        guard let editing else {
            return ProfileStorageContext(
                baseImageURL: baseURL,
                baseImageVersion: readCurrentBaseVersion(),
                baseImageBuildDate: buildDate,
                profileDiskURL: nil,
                profileHomeURL: nil,
                profileHomeImageURL: nil,
                isRunning: false,
                onResetDisk: {},
                onResetHome: {},
                onUpgradeHome: nil
            )
        }
        let homeImage = store.homeImageURL(for: editing)
        let hasHomeImage = editing.homeModel == .ext4
            && FileManager.default.fileExists(atPath: homeImage.path)
        return ProfileStorageContext(
            baseImageURL: baseURL,
            baseImageVersion: readCurrentBaseVersion(),
            baseImageBuildDate: buildDate,
            profileDiskURL: store.diskURL(for: editing),
            profileHomeURL: editing.homeModel == .virtiofs
                ? store.homeDirectory(for: editing) : nil,
            profileHomeImageURL: hasHomeImage ? homeImage : nil,
            isRunning: isAttached(editing.id),
            onResetDisk: { [weak self] in self?.resetProfile(editing) },
            onResetHome: { [weak self] in self?.resetHomeProfile(editing) },
            onUpgradeHome: editing.homeModel == .virtiofs
                ? { [weak self] in self?.armHomeStorageUpgrade(editing) }
                : nil
        )
    }

    func closeEditorWindow() {
        editorWindow?.close()
        editorWindow = nil
        editorEditingProfile = nil
    }

    private func openSSHWindow(for profile: Profile) {
        guard let pub = profile.sshPublicKey else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "SSH public key"
        win.center()
        win.contentView = NSHostingView(rootView: SSHKeyView(
            profileName: profile.name,
            publicKey: pub,
            onDone: { self.sshWindow?.close(); self.sshWindow = nil }
        ))
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        sshWindow = win
    }

    // MARK: - Profile actions

    /// Editor "Upgrade storage…": re-arm the home-storage upgrade offer for
    /// a legacy (virtiofs-home) workspace that previously declined it. The
    /// actual migration still runs through the launch-time dialog + migrate
    /// boot, so the user gets the same explainer and progress UI.
    @MainActor
    private func armHomeStorageUpgrade(_ profile: Profile) {
        var p = profiles.first(where: { $0.id == profile.id }) ?? profile
        guard p.homeModel == .virtiofs else { return }
        p.homeUpgradeDeclined = false
        try? store.save(p)
        profiles = store.loadAll()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Home storage upgrade armed", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString(
                "The next time “%@” launches, Bromure will offer to move its home folder onto a private ext4 disk image (with a one-time copy and a kept backup).",
                comment: ""),
            p.name)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    private func handleEditorSave(profile: Profile, generateSSH: Bool, editing: Profile?) {
        var profile = profile

        // Shared-folder edits are incompatible with a suspended VM:
        // virtiofs shares become slot-tagged VZDirectoryShares in the VM
        // config (share-1, share-2, …), and xinitrc — which materializes
        // the symlinks under ~ from /mnt/bromure-meta/shares.txt — only
        // runs on cold boot, not on resume. So changing folderPaths while
        // a saved state exists either crashes the restore or silently
        // ignores the new config. Warn the user and invalidate.
        if let original = editing, original.folderPaths != profile.folderPaths {
            let stateURL = store.profileDirectory(for: profile)
                .appendingPathComponent("vm.state")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let alert = NSAlert()
                alert.messageText = String(
                    format: NSLocalizedString("Discard suspended VM for “%@”?", comment: ""),
                    profile.name)
                alert.informativeText = NSLocalizedString(
                    "The shared folders changed since this workspace was suspended. The snapshot was saved against the old share set, so it can't be safely resumed with the new one.\n\nSaving will discard the suspended state. The next launch will cold-boot. Files in the per-workspace home directory and on the shared folders themselves are unaffected.",
                    comment: "")
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("Discard & save", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try? FileManager.default.removeItem(at: stateURL)
                // tabs.json pairs with the snapshot — without the matching
                // VM, the saved tab UUIDs point at kittys that won't exist
                // on the next cold boot.
                let tabsURL = store.profileDirectory(for: profile)
                    .appendingPathComponent("tabs.json")
                try? FileManager.default.removeItem(at: tabsURL)
            }
        }

        // Editing keeps the original id (already preserved by ProfileEditorView).
        // The shared save/reconcile core is factored into `persistEditedProfile`
        // so the headless control-socket path (create/edit over the CLI + TUI)
        // reuses the exact same persistence and app-state refresh.
        do {
            try persistEditedProfile(&profile, editing: editing, generateSSH: generateSSH)
        } catch {
            showError(error, message: editing == nil
                      ? "Couldn't create the workspace."
                      : "Couldn't save the workspace.")
            return
        }
        closeEditorWindow()
        // Show the SSH key viewer right after a brand-new generation so the
        // user can paste it into GitHub before forgetting.
        if generateSSH, profile.sshPublicKey != nil { openSSHWindow(for: profile) }

        // If the user edited a profile that already has a session
        // window open, push the host-side cosmetic bits through live
        // (window title, opacity, accent) and prompt to restart for
        // anything that's baked into the booted VM or its host home
        // dir. Without this, settings appear to "not stick" until the
        // user closes and reopens the session.
        if editing != nil, let win = pane(for: profile.id) {
            let runningProfile = win.profile
            win.applyLiveProfileUpdates(profile)
            // Push env vars, credentials (wire-swap map + guest-side
            // credential files), and guardrail policy into the running
            // MITM engine + live shares — no reboot for these. Only things
            // genuinely baked into the booted VM (memory, mounts, the
            // auto-launched tool, sshd/kube/SSO wiring) fall through to the
            // restart prompt below.
            applyLiveSessionRefresh(from: runningProfile, to: profile,
                                    terminalDefaults: terminalDefaults, window: win)
            let restartItems = restartRequiringChanges(from: runningProfile, to: profile)
            if !restartItems.isEmpty {
                promptRestartForChanges(items: restartItems, window: win)
            }
        }
    }

    /// Shared save + app-state reconciliation for a created/edited profile.
    /// Deliberately AppKit-free (no NSAlert, no window ops) so the headless
    /// control-socket path can call it too — the GUI-only bits (folder-discard
    /// alert, SSH-key viewer, live-session restart prompt) stay in the callers.
    /// Mutates `profile` (may set `sshPublicKey`) and refreshes `profiles` +
    /// the sidebar. Throws on disk/keychain failure.
    @MainActor
    func persistEditedProfile(_ profile: inout Profile, editing: Profile?,
                              generateSSH: Bool) throws {
        // Belt-and-braces: trim every secret before persisting. Pasted tokens
        // routinely come with trailing whitespace; embedding either in an HTTP
        // header value at swap time would corrupt the request and trigger a
        // "401 Invalid API key" upstream.
        let trim = { (s: String?) in s?.trimmingCharacters(in: .whitespacesAndNewlines) }
        profile.apiKey = trim(profile.apiKey)
        profile.additionalTools = profile.additionalTools.map { var s = $0; s.apiKey = trim(s.apiKey); return s }
        profile.gitHTTPSCredentials = profile.gitHTTPSCredentials.map {
            var c = $0; c.token = c.token.trimmingCharacters(in: .whitespacesAndNewlines); return c
        }
        profile.manualTokens = profile.manualTokens.map {
            var t = $0; t.realValue = t.realValue.trimmingCharacters(in: .whitespacesAndNewlines); return t
        }

        try store.save(profile)
        try store.prepareHomeDirectory(for: profile, terminalDefaults: terminalDefaults)
        let agentDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent", isDirectory: true)
        if generateSSH {
            // Agent dir is host-only — never mounted into the VM. The private
            // seed lives here; the public key gets a courtesy copy into the
            // VM's ~/.ssh for reference.
            let pub = try makeSSHKey(in: agentDir)
            profile.sshPublicKey = pub
            try store.save(profile)
        } else if editing == nil,
                  profile.sshPublicKey != nil,
                  !FileManager.default.fileExists(atPath:
                    agentDir.appendingPathComponent("id_ed25519.raw").path) {
            // New profile that inherited the default public key from the
            // preferences template — copy the matching private seed in so the
            // in-process ssh-agent has something to load.
            try DefaultSSHKey.copy(to: agentDir)
        }
        profiles = store.loadAll()
        refreshSidebar()
        reconcileBootLaunchAgent()   // a saved bootAtStartup change may flip the plist
        // The privateMode toggle and enrollment-gated streaming flag both flow
        // off `profiles`; resync the running session toolbars now so a flip from
        // public → private (or back) doesn't wait for the next launch.
        refreshStreamingState()
    }

    // MARK: - Headless profile create / edit / export (control socket)

    /// Create (`idOrName == nil`) or update a workspace from a JSON document
    /// sent over the owner-only control socket — the headless counterpart of
    /// the SwiftUI editor's Save. Returns a describe-style dict on success, or
    /// `{ok:false, error}` (the caller maps that to a 4xx/5xx). Reuses the GUI
    /// persistence via `persistEditedProfile`.
    @MainActor
    func automationUpsertProfile(idOrName: String?, doc rawDoc: [String: Any]) -> [String: Any] {
        // Drop transport-only markers before decoding. `generateSSH` is a
        // control flag (not a Profile field): when set, the host mints a fresh
        // ed25519 key in the profile's agent dir — host-side, exactly like the
        // GUI's "Generate SSH key". The private seed never enters the VM.
        var doc = rawDoc
        doc.removeValue(forKey: "_secretsRedacted")
        let generateSSH = (rawDoc["generateSSH"] as? Bool) == true
        doc.removeValue(forKey: "generateSSH")

        let profile: Profile
        let editing: Profile?

        if let idOrName {
            // ---- Update: full-document replace of a workspace's non-secret
            // fields, preserving stored secrets the caller didn't re-supply.
            guard let existing = profileByNameOrID(idOrName) else {
                return ["ok": false, "error": "Workspace not found: \(idOrName)"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: doc),
                  var incoming = try? JSONDecoder.iso8601().decode(Profile.self, from: data) else {
                return ["ok": false, "error": "Invalid profile document"]
            }
            // Server-owned identity — never trust the client's copies.
            incoming.id = existing.id
            incoming.createdAt = existing.createdAt
            incoming.lastUsedAt = existing.lastUsedAt

            // Shared-folder edits are incompatible with a suspended VM (same
            // reasoning as the GUI's discard alert). Headless can't prompt, so
            // refuse rather than silently discard the snapshot.
            if existing.folderPaths != incoming.folderPaths {
                let stateURL = store.profileDirectory(for: existing)
                    .appendingPathComponent("vm.state")
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    return ["ok": false, "error":
                        "Shared folders changed but this workspace has a suspended VM. "
                        + "Stop it first (`vm kill \(existing.name)`), then edit folders."]
                }
            }

            // Secret preservation: a document round-tripped through describe/
            // export comes back with blank secrets. Harvest the existing set +
            // whatever the caller actually typed, overlay the latter on the
            // former, and re-apply — so untouched secrets survive.
            var existingCopy = existing
            let existingSecrets = ProfileSecrets.extract(stripping: &existingCopy)
            var incomingCopy = incoming
            let incomingSecrets = ProfileSecrets.extract(stripping: &incomingCopy)
            var merged = existingSecrets
            merged.overlay(with: incomingSecrets)
            merged.apply(to: &incoming)

            profile = incoming
            editing = existing
        } else {
            // ---- Create: seed from the preferences template (so a new
            // workspace inherits the user's defaults + default OAuth tokens),
            // then overlay the caller's fields at the document level so
            // unspecified keys keep their template value.
            let name = (doc["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return ["ok": false, "error": "A workspace name is required."] }
            let minted = store.newProfileFromTemplate(name: name)
            guard let mData = try? JSONEncoder.iso8601().encode(minted),
                  var base = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] else {
                return ["ok": false, "error": "Internal error seeding the workspace."]
            }
            for (k, v) in doc { base[k] = v }
            guard let data = try? JSONSerialization.data(withJSONObject: base),
                  var created = try? JSONDecoder.iso8601().decode(Profile.self, from: data) else {
                return ["ok": false, "error": "Invalid profile document"]
            }
            // Force server-owned identity regardless of what the doc carried.
            created.id = minted.id
            created.createdAt = minted.createdAt
            created.lastUsedAt = nil
            profile = created
            editing = nil
        }

        var toSave = profile
        do {
            try persistEditedProfile(&toSave, editing: editing, generateSSH: generateSSH)
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        // Push host-side cosmetic + live-swap updates into a running session,
        // matching the GUI (minus the restart prompt, which needs a window).
        if editing != nil, let win = pane(for: toSave.id) {
            let runningProfile = win.profile
            win.applyLiveProfileUpdates(toSave)
            applyLiveSessionRefresh(from: runningProfile, to: toSave,
                                    terminalDefaults: terminalDefaults, window: win)
        }

        var result = automationProfileDescribe(toSave.id.uuidString) ?? ["id": toSave.id.uuidString]
        result["ok"] = true
        // Surface the freshly-minted public key so the caller can show it for
        // pasting into GitHub etc. (public, not a secret).
        if generateSSH, let pub = toSave.sshPublicKey, !pub.isEmpty { result["sshPublicKey"] = pub }
        return result
    }

    /// Full-fidelity profile export for the `kubectl edit`-style round-trip
    /// (CLI `workspaces edit`, the TUI raw-JSON hatch). Emits the entire
    /// `Profile` Codable shape with every secret blanked — so an editor can
    /// change any non-secret field and PUT it back, and `automationUpsertProfile`
    /// preserves the untouched secrets. `describe` stays the compact summary.
    @MainActor
    func automationProfileExport(_ key: String) -> [String: Any]? {
        guard let p = profileByNameOrID(key) else { return nil }
        var stripped = p
        _ = ProfileSecrets.extract(stripping: &stripped)   // blank all secrets
        guard let data = try? JSONEncoder.iso8601().encode(stripped),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // Flag so callers/humans know the secret fields were redacted (blank =
        // keep the stored value on save; type a value to change it).
        dict["_secretsRedacted"] = true
        return dict
    }

    /// Per-field categories that change behaviour inside the booted
    /// VM (and therefore need a restart to take effect). Used to
    /// coalesce diffs into a small, user-facing list of bullet points.
    private enum RestartChange: CaseIterable {
        case memory
        case networking
        case sharedFolders
        case primaryTool
        case additionalTools
        case sshPublicKey
        case httpsGitCredentials
        case manualTokens
        case importedSSHKeys
        case environmentVariables
        case traceLevel
        case kubernetes
        case digitalOcean
        case awsCredentials
        case containerRegistries
        case keyboardSettings
        case terminalAppearance
        case gitIdentity
    }

    private func restartLabel(for change: RestartChange) -> String {
        switch change {
        case .memory:
            return NSLocalizedString("VM memory", comment: "")
        case .networking:
            return NSLocalizedString("Network mode", comment: "")
        case .sharedFolders:
            return NSLocalizedString("Shared folders", comment: "")
        case .primaryTool:
            return NSLocalizedString("Primary tool / auth mode", comment: "")
        case .additionalTools:
            return NSLocalizedString("Additional tools", comment: "")
        case .sshPublicKey:
            return NSLocalizedString("SSH public key", comment: "")
        case .httpsGitCredentials:
            return NSLocalizedString("HTTPS git credentials", comment: "")
        case .manualTokens:
            return NSLocalizedString("Manual token rules", comment: "")
        case .importedSSHKeys:
            return NSLocalizedString("Imported SSH keys", comment: "")
        case .environmentVariables:
            return NSLocalizedString("Environment variables", comment: "")
        case .traceLevel:
            return NSLocalizedString("Trace level", comment: "")
        case .kubernetes:
            return NSLocalizedString("Kubernetes contexts", comment: "")
        case .digitalOcean:
            return NSLocalizedString("DigitalOcean token", comment: "")
        case .awsCredentials:
            return NSLocalizedString("AWS credentials", comment: "")
        case .containerRegistries:
            return NSLocalizedString("Container registry credentials", comment: "")
        case .keyboardSettings:
            return NSLocalizedString("Cursor / keyboard settings", comment: "")
        case .terminalAppearance:
            return NSLocalizedString("Terminal font and colors", comment: "")
        case .gitIdentity:
            return NSLocalizedString("Git author identity", comment: "")
        }
    }

    /// Diff two profiles and return the user-facing categories that
    /// require a VM restart. Cosmetic / host-side fields (name,
    /// color, comments, windowOpacity, closeAction, privateMode,
    /// timestamps, default-token caches, subscription swap state,
    /// `baseImageVersionAtClone`) are intentionally omitted — the
    /// caller has already applied them live or they're consulted at
    /// host-side decision points where re-reading the saved profile
    /// is enough.
    private func restartRequiringChanges(from old: Profile, to new: Profile) -> [String] {
        var changes: [RestartChange] = []
        if old.memoryGB != new.memoryGB { changes.append(.memory) }
        if old.networkMode != new.networkMode
            || old.bridgedInterfaceID != new.bridgedInterfaceID {
            changes.append(.networking)
        }
        if old.folderPaths != new.folderPaths { changes.append(.sharedFolders) }
        // Note: a plain API-key change is NOT here — it's applied live
        // (api_key.env + swap map). Only switching the tool itself or its
        // auth mode needs a restart, since that re-runs the agent
        // auto-launch and the token/subscription wiring.
        if old.tool != new.tool || old.authMode != new.authMode {
            changes.append(.primaryTool)
        }
        if old.additionalTools != new.additionalTools { changes.append(.additionalTools) }
        if old.sshPublicKey != new.sshPublicKey { changes.append(.sshPublicKey) }
        if old.importedSSHKeys != new.importedSSHKeys { changes.append(.importedSSHKeys) }
        // Applied live by applyLiveSessionRefresh — no restart needed:
        //   env vars, guardrails (incl. per-endpoint HTTPS-database modes),
        //   the primary API key, manual tokens, HTTPS git credentials,
        //   DigitalOcean PAT, container-registry creds, git identity, and the
        //   trace level (the proxy re-reads the per-session level live).
        // All of these are header/env/file credentials that re-read live
        // off the meta + home virtiofs shares and the swap map.
        // Kube + AWS keep their prompt: the engine-side client-identity /
        // cluster-CA / exec-poller and AWS-SSO refresh-loop wiring is only
        // set up on cold boot, even though their config files refresh live.
        if old.kubeconfigs != new.kubeconfigs { changes.append(.kubernetes) }
        if old.awsCredentials != new.awsCredentials { changes.append(.awsCredentials) }
        // Credential "ask before use" gates are applied LIVE — no reboot. The
        // api-key / DigitalOcean consent rides on the token swap map's
        // consentCredentialID (rebuilt by applyLiveSessionRefresh), and the
        // ssh-key gate is re-pushed to the ssh-agent there too. (Manual-token /
        // docker-registry / imported-SSH-key gates already ride their own
        // credential diffs.)
        // Terminal appearance (font, colors, cursor shape/blink) is applied
        // LIVE now that ghostty renders host-side — applyLiveProfileUpdates →
        // TerminalSessionController.applyProfile → ghostty_surface_update_config
        // re-themes every open surface on save. Window opacity is applied live
        // too (the pane container's layer). The keyboard-layout / key-repeat
        // fields are dead (no guest X keymap post-framebuffer). None of these
        // need a restart anymore.
        // Git identity (~/.gitconfig) is rewritten live into the home share.
        return changes.map { restartLabel(for: $0) }
    }

    /// True if an edit touches anything the live refresh re-emits: env
    /// vars, guardrail policy, or any credential (which moves the token
    /// swap map and/or the api_key.env / proxy.env content). Cosmetic
    /// edits (name, color, opacity) return false so the guest doesn't
    /// print a spurious "environment refreshed" line.
    private func sessionRefreshAffectingChange(from old: Profile, to new: Profile) -> Bool {
        old.environmentVariables != new.environmentVariables
            || old.guardrails != new.guardrails
            || old.supplyChain != new.supplyChain
            || old.promptInjection != new.promptInjection
            || old.httpDatabases != new.httpDatabases
            || old.tool != new.tool
            || old.authMode != new.authMode
            || old.apiKey != new.apiKey
            || old.additionalTools != new.additionalTools
            || old.manualTokens != new.manualTokens
            || old.gitHTTPSCredentials != new.gitHTTPSCredentials
            || old.digitalOceanToken != new.digitalOceanToken
            || old.dockerRegistries != new.dockerRegistries
            || old.awsCredentials != new.awsCredentials
            || old.kubeconfigs != new.kubeconfigs
            || old.mcpServers != new.mcpServers
            || old.gitUserName != new.gitUserName
            || old.gitUserEmail != new.gitUserEmail
            // Approval-gate toggles flip a credential's consentCredentialID in the
            // token map, so the live refresh must re-emit it.
            || old.apiKeyRequiresApproval != new.apiKeyRequiresApproval
            || old.digitalOceanTokenRequiresApproval != new.digitalOceanTokenRequiresApproval
    }

    /// Apply env-var / credential / guardrail edits to a running session
    /// in place — no reboot. Three live surfaces are refreshed:
    ///
    ///   1. **Guardrail policy** — read live per request, so an
    ///      off→read-only flip lands on the next proxied call.
    ///   2. **The token swap map** — re-minted fakes are a pure function
    ///      of (real value, install salt), so unchanged credentials keep
    ///      the exact fake the running agent already holds; changed/added
    ///      ones get fresh entries.
    ///   3. **Guest-side files** — `proxy.env` / `api_key.env` / MCP
    ///      configs in the meta share *and* the credential files in the
    ///      `bromure-home` virtiofs share (`~/.git-credentials`, docker /
    ///      gh / glab / doctl / aws / kube configs, `~/.gitconfig`). Both
    ///      shares are live-mounted, and the in-VM tools re-read them per
    ///      command, so a `git push` / `docker pull` uses the new value
    ///      immediately. `env.generation` is bumped so open shells
    ///      re-source the env on their next prompt.
    ///
    /// Remaining caveat: the already-running *foreground agent* keeps its
    /// launch-time process environment (Unix env is frozen at exec) until
    /// it restarts, and the engine-side wiring for a handful of credential
    /// types — the kube client-identity / cluster-CA / exec-poller setup,
    /// the AWS-SSO refresh loop, and the ssh-agent key load — is only done
    /// on cold boot. Those categories keep their restart prompt; env vars
    /// and the common file/header credentials do not.
    private func applyLiveSessionRefresh(from old: Profile, to new: Profile,
                                         terminalDefaults: TerminalAppDefaults,
                                         window win: SessionPane) {
        // Fusion config can change without tripping the session-refresh guard
        // below (e.g. editing legs/judge), so reconcile it first and
        // unconditionally. Engagement is the user's per-session choice via the
        // title-bar toggle — we don't auto-engage; we only force-off when the
        // profile is no longer configurable.
        _ = old
        let nowConfigurable = new.fusionConfigurable
        win.model.fusionConfigurable = nowConfigurable
        mitmEngine?.setFusionConfig(makeFusionConfig(for: new), for: new.id)
        if !nowConfigurable {
            win.model.fusionEngaged = false
            mitmEngine?.setFusionEngaged(false, for: new.id)
        }

        // Trace level is consulted live by the proxy on every request, so update
        // the running session's level in place (keeping its session id so the
        // trace grouping isn't fragmented). Done unconditionally — a trace-level
        // change on its own doesn't trip the credential/env guard below.
        if old.traceLevel != new.traceLevel, let engine = mitmEngine {
            let sid = engine.sessionTrace(for: new.id)?.sessionID ?? UUID()
            engine.setSessionTrace(.init(sessionID: sid, level: new.traceLevel), for: new.id)
        }

        // Local model / routing: agents are pinned to the `bromure-local`
        // sentinel, so switching the active model (or routing mode) is a
        // host-side remap — re-point the sentinel + engine and update routing,
        // with no reboot and no agent restart. Done unconditionally (before the
        // guard) since neither field trips the credential/env diff below.
        if old.activeModelID != new.activeModelID || old.modelRouting != new.modelRouting {
            if let engine = mitmEngine { applyRouting(engine, for: new) }
            startLocalEngineIfNeeded(for: new)
        }

        // The SSH-key "ask before use" gate is host-side (the ssh-agent), not the
        // token swap map, so re-push the default agent key with the new flag in
        // place — no reboot. Done before the guard since this field alone doesn't
        // trip the credential/env diff. (Adding/removing imported keys still
        // cold-boots for the seed load, via the importedSSHKeys restart diff.)
        if old.sshKeyRequiresApproval != new.sshKeyRequiresApproval, let engine = mitmEngine {
            engine.sshAgent.setKeys(loadAgentKeys(for: new), for: new.id)
        }

        guard sessionRefreshAffectingChange(from: old, to: new) else { return }

        // Guardrail config is consulted live on every proxied request —
        // update it unconditionally so a mode change lands even when no
        // credential moved.
        mitmEngine?.setGuardrailsConfig(Self.makeGuardrailsConfig(for: new), for: new.id)
        // Supply-chain policy follows the same live-update rule.
        mitmEngine?.setSupplyChainPolicy(new.supplyChain, for: new.id)
        // Prompt-injection detection policy — same live-update rule. Enabling
        // a detector kicks a background model download if it's not installed.
        mitmEngine?.setPromptInjectionPolicy(new.promptInjection, for: new.id)
        if new.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
        if new.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }

        var profile = new
        populateMCPBearerTokens(in: &profile)
        let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let plan = self.sessionTokenPlan(for: profile, salt: salt)

        var kubeYAML: String?
        if let engine = mitmEngine {
            // Full map = profile plan + kubeconfig bearer/exec swaps, the
            // same composition the launch path builds.
            var fresh = plan.tokenMap()
            let kubeMat = KubeconfigMaterializer().materialize(
                profile: profile, bromureCAPEM: engine.ca.certificatePEM)
            kubeYAML = kubeMat.yaml
            for swap in kubeMat.bearerSwaps {
                fresh.entries.append(TokenMap.Entry(
                    fake: swap.fakeToken, real: swap.realToken, host: swap.host,
                    consentCredentialID: swap.consentCredentialID,
                    consentDisplayName: swap.consentDisplayName))
            }
            // Merge rather than replace. A *changed* credential mints a new
            // fake, but the still-running agent's process env holds the
            // OLD one; preserving the old entries (whose fakes aren't
            // reissued) lets in-flight work finish on the old value instead
            // of erroring, while new shells pick up the new fake. Same
            // additive pattern the subscription / OAuth coordinators use.
            let freshFakes = Set(fresh.entries.map(\.fake))
            let preserved = engine.swapper.entries(for: profile.id)
                .filter { !freshFakes.contains($0.fake) }
            engine.swapper.setMap(TokenMap(entries: fresh.entries + preserved),
                                  for: profile.id)
        }

        // Rewrite the guest-side credential files with fakes. virtiofs
        // homes are written directly (this also overwrites any real-token
        // copy the plan-less editor-save `prepareHomeDirectory` just wrote
        // there, closing that window for a running session). ext4 homes
        // can't be written from the host — restage the home-seed and bump
        // seed.generation so the in-VM agent re-applies it.
        if profile.homeModel == .virtiofs {
            try? store.prepareHomeDirectory(for: profile,
                                            terminalDefaults: terminalDefaults,
                                            tokenPlan: plan,
                                            kubeconfigYAML: kubeYAML)
        }

        // Rewrite api_key.env / proxy.env / MCP configs into the stable
        // meta-share dir and bump env.generation for the guest's
        // PROMPT_COMMAND hook.
        do {
            try win.sandbox?.sessionDisk?.refreshMetadataShare(
                profile: profile, tokenPlan: plan)
        } catch {
            NSLog("[bromure-ac] live env refresh failed: \(error)")
        }

        if profile.homeModel == .ext4,
           let session = win.sandbox?.sessionDisk,
           let seedDir = session.homeSeedDirectory {
            do {
                try store.writeHomeSeedFiles(for: profile, into: seedDir,
                                             terminalDefaults: terminalDefaults,
                                             tokenPlan: plan,
                                             kubeconfigYAML: kubeYAML)
                let files = seedDir.appendingPathComponent("files", isDirectory: true)
                seedCodexAuthFile(for: profile, homeRoot: files)
                seedGrokAuthFile(for: profile, homeRoot: files)
                try store.finalizeHomeSeed(for: profile, seedDir: seedDir)
                session.bumpSeedGeneration()
            } catch {
                NSLog("[bromure-ac] live home-seed refresh failed: \(error)")
            }
        }
    }

    /// Sheet a non-modal alert against the running session window,
    /// listing the changed settings the VM hasn't picked up and
    /// offering a reboot (which routes through `requestReboot`'s
    /// usual soft / hard / cancel chooser). "Later" leaves the VM
    /// alone — the next time it cold-boots it'll inherit the new
    /// values from the saved profile JSON.
    @MainActor
    private func promptRestartForChanges(items: [String], window: SessionPane) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Restart “%@” to apply these changes?", comment: ""),
            window.profile.name)
        let bullets = items.map { "• " + $0 }.joined(separator: "\n")
        alert.informativeText = String(
            format: NSLocalizedString(
                "These settings are baked into the VM at boot, so the running session won't pick them up until it restarts:\n\n%@",
                comment: ""),
            bullets)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Restart Now…", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard let host = window.host?.paneHostWindow else {
            // No window to anchor a sheet (headless) — fall back to a modal.
            if alert.runModal() == .alertFirstButtonReturn { requestReboot(for: window) }
            return
        }
        alert.beginSheetModal(for: host) { [weak self, weak window] response in
            guard response == .alertFirstButtonReturn,
                  let self, let window else { return }
            self.requestReboot(for: window)
        }
    }

    /// Send one `vm.disk_reset` event to the workspace backend so admins
    /// can correlate "this install was reset" with the supply-chain
    /// timeline that precedes / follows it. `BACEventEmitter` already
    /// no-ops when the Mac isn't enrolled or the profile is in private
    /// mode, so this is safe to call unconditionally.
    private func emitDiskResetEvent(profile: Profile, reason: String) {
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

    private func resetProfile(_ profile: Profile) {
        if runningSessions[profile.id] != nil {
            showRunningRefusal(profile: profile, what: "system disk")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset “\(profile.name)” system disk to base?"
        alert.informativeText = """
        Wipes the per-profile read-write copy of the OS:
        • Anything you `sudo apt install`ed inside the VM
        • Modifications to /etc, /var, /usr, /opt
        • System-wide config edits

        Your home folder is untouched — projects, dotfiles, .ssh keys, \
        npm-global, .cargo, and shell history all survive.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset to base")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.resetDisk(for: profile)
            emitDiskResetEvent(profile: profile, reason: "user_requested")
        } catch {
            showError(error, message: "Couldn't reset the disk.")
        }
    }

    /// Wipe the per-profile home directory. Inverse blast-radius from
    /// `resetProfile`: system layer survives, but everything personal
    /// the user accumulated under /home/ubuntu is gone.
    private func resetHomeProfile(_ profile: Profile) {
        if runningSessions[profile.id] != nil {
            showRunningRefusal(profile: profile, what: "home folder")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Erase the home folder for “\(profile.name)”?"
        alert.informativeText = """
        Wipes everything under /home/ubuntu inside the VM:
        • Project clones and files anywhere in your home dir
        • Shell history and .bashrc.local customizations
        • npm-global, ~/.cargo, language-server caches
        • SSH keypair (regenerate from the Credentials pane)

        Bromure-managed files (.bashrc, kitty config, .gitconfig, \
        .git-credentials, gh / glab CLI configs) are rebuilt from your \
        profile settings on next launch. The system disk is untouched.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase Home")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.resetHome(for: profile)
            // The private SSH key lived only in profiles/<id>/home/.ssh.
            // It's gone now — clear the public key too so the editor's
            // Credentials pane doesn't keep claiming we have a keypair
            // on file. The user can regenerate from the same place.
            if profile.sshPublicKey != nil {
                var p = profile
                p.sshPublicKey = nil
                try? store.save(p)
                profiles = store.loadAll()
                refreshSidebar()
            }
        } catch {
            showError(error, message: "Couldn't erase the home folder.")
        }
    }

    private func showRunningRefusal(profile: Profile, what: String) {
        let alert = NSAlert()
        alert.messageText = "Close “\(profile.name)” first."
        alert.informativeText = "The \(what) is in use by the running VM. Resetting it now would corrupt the live session — close the session window and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func deleteProfile(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Delete workspace “\(profile.name)”?"
        alert.informativeText = "Removes its disk, settings, and SSH key. The mounted host folder is untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.delete(profile)
            profiles = store.loadAll()
            refreshSidebar()
        } catch {
            showError(error, message: "Couldn't delete the workspace.")
        }
    }

    /// If any local model this profile would load is still downloading, returns
    /// its display name + repo so callers can refuse to boot. nil once every
    /// selected model is fully present. The single source of truth for the
    /// "don't boot mid-download" guard (GUI `launch` + CLI `vm run`).
    @MainActor func downloadingModel(for profile: Profile) -> (name: String, repo: String)? {
        for modelID in profile.distinctLocalModelIDs {
            let resolved = CatalogStore.shared.resolve(modelID)
            let repo = resolved?.repo ?? modelID
            if ModelDownloadManager.shared.isDownloading(repo: repo) {
                return (resolved?.name ?? repo, repo)
            }
        }
        return nil
    }

    /// Boot (or reveal) a profile's session. When `detached` is true the VM
    /// boots window-less — no pane is hosted, the session runs headless from the
    /// start (the `vm run -d` / login-boot / remote-menu path), reattachable
    /// later.
    func launch(_ profile: Profile, detached: Bool = false) {
        // Already shown → just focus + select it (unless we were asked to detach,
        // in which case drop the window and leave the VM running headless).
        if isAttached(profile.id) {
            if detached { detachSession(profile.id) } else { revealSession(profile.id) }
            return
        }
        // Running but detached (window was closed, VM kept alive). Asked to
        // detach → it already is, nothing to do. Otherwise reattach a fresh
        // window onto the live VM, with its tabs intact.
        if let session = runningSessions[profile.id] {
            if !detached { attachWindow(to: session) }
            return
        }

        // Refuse to boot while any local model this profile needs is still
        // downloading — the agent would come up pointed at an engine that
        // can't load yet, producing a wall of connection errors.
        if let dl = downloadingModel(for: profile) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Model still downloading", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString(
                    "“%@” is still downloading. Wait for it to finish, then launch “%@”.",
                    comment: ""),
                dl.name, profile.name)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }

        // Compromised profiles refuse to boot until the user confirms
        // a wipe of the disk + home (the parts the malware could have
        // modified). Tokens, ssh material, and the rest of profile.json
        // are kept — the user wants to keep the profile around. Shared
        // folders are NOT touched (they live outside Bromure's storage
        // and may legitimately hold the user's source); the alert
        // surfaces this so the user knows where to look next.
        if SessionDisk.isCompromised(profile: profile, store: store) {
            if !confirmWipeAndProceed(profile: profile) {
                return
            }
            // Fall through — disk + home are gone, flag is cleared,
            // launch path now treats this like any first launch.
        }

        // Drift check: if the base image has been rebuilt since this
        // profile's disk was cloned, prompt to reset.
        let currentBaseVersion = readCurrentBaseVersion()
        let diskExists = FileManager.default.fileExists(atPath: store.diskURL(for: profile).path)
        if diskExists,
           let recorded = profile.baseImageVersionAtClone,
           let current = currentBaseVersion,
           recorded != current {
            let alert = NSAlert()
            alert.messageText = "Base image updated since this workspace was created."
            alert.informativeText = "This workspace is on base v\(recorded); the current base is v\(current). Reset the workspace disk to pick up the new base? (Resetting wipes anything you've installed inside the VM. Your project folder is untouched.)"
            alert.addButton(withTitle: "Reset and launch")
            alert.addButton(withTitle: "Launch as-is")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try? store.resetDisk(for: profile)
                emitDiskResetEvent(profile: profile, reason: "base_image_drift")
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        try? store.touch(profile)

        var profile = profile

        // Home-storage upgrade offer (virtiofs → ext4 image). Asked once:
        // "Not Now" persists via homeUpgradeDeclined and the workspace
        // editor's "Upgrade Home Storage" button re-arms it. Accepting
        // makes THIS boot a migrate boot — the guest agent copies the old
        // home into a fresh image before the session starts, with progress
        // on the boot overlay.
        var migrateHomeThisBoot = false
        // Headless (CLI/remote) launches never modal-prompt; the workspace
        // keeps its current storage and the offer waits for a GUI launch.
        if profile.homeModel == .virtiofs && !profile.homeUpgradeDeclined && !headless {
            if promptHomeStorageUpgrade(profile: profile) {
                migrateHomeThisBoot = true
                // The dual-attach migrate config can't restore a snapshot
                // saved against the old config — boot fresh (the dialog
                // said so).
                SessionDisk(profile: profile, store: store,
                            baseDiskURL: imageManager.baseDiskURL).clearSavedState()
            } else {
                profile.homeUpgradeDeclined = true
                try? store.save(profile)
                self.profiles = store.loadAll()
            }
        }

        // Build the per-session token plan up front: real values stay
        // here (and on the host's MITM engine); fakes flow into the VM
        // via prepareHomeDirectory and the meta share. The plan is
        // deterministic in (real value, install salt) so Claude Code
        // doesn't see the fake rotate session-to-session.
        populateMCPBearerTokens(in: &profile)
        let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let plan = self.sessionTokenPlan(for: profile, salt: salt)
        // (prepareHomeDirectory call moved below — needs the
        // materialized kubeconfig YAML produced by the engine block.)

        // Push the plan + ssh keys to the engine before VM start, so
        // the listeners we register after boot have something to swap.
        var kubeYAMLForVM: String?
        if let engine = mitmEngine {
            // Materialize the synthetic kubeconfig + extract bearer
            // swaps + client identities + exec contexts.
            let kubeMat = KubeconfigMaterializer().materialize(
                profile: profile, bromureCAPEM: engine.ca.certificatePEM)
            kubeYAMLForVM = kubeMat.yaml

            // Token map = the profile-derived plan + the kubeconfig
            // bearer/exec swap entries.
            var tokenMap = plan.tokenMap()
            for swap in kubeMat.bearerSwaps {
                tokenMap.entries.append(TokenMap.Entry(
                    fake: swap.fakeToken, real: swap.realToken, host: swap.host,
                    consentCredentialID: swap.consentCredentialID,
                    consentDisplayName: swap.consentDisplayName))
            }
            engine.swapper.setMap(tokenMap, for: profile.id)

            // Per-host client identities for upstream mTLS (kubectl
            // → API server).
            for ident in kubeMat.clientIdentities {
                engine.clientIdentities.setIdentity(
                    ident.identity, host: ident.host, profileID: profile.id,
                    consentCredentialID: ident.consentCredentialID,
                    consentDisplayName: ident.consentDisplayName)
            }
            // Per-host CA overrides so the proxy can verify private
            // API-server certs that don't chain to macOS roots.
            for entry in kubeMat.clusterCAs {
                engine.clusterCAs.setCA(
                    pem: entry.caPEM, host: entry.host, profileID: profile.id)
            }
            // Exec-credential poller: refreshes the swap map on a
            // schedule for each context. Cancelled in unregister.
            if !kubeMat.execContexts.isEmpty {
                engine.execPoller.start(kubeMat.execContexts,
                                        profileID: profile.id,
                                        swapper: engine.swapper)
            }
        }
        // Drop the synthetic kubeconfig + every other managed dotfile
        // where the guest picks them up. virtiofs (and migrate) boots
        // write the live host-side home directly — a migrate boot then
        // copies that home into the image. Pure-ext4 boots can't be
        // written from here; they get a home-seed staged into the meta
        // share after sandbox.prepare() below (which builds the share).
        if profile.homeModel == .virtiofs {
            try? store.prepareHomeDirectory(for: profile,
                                            terminalDefaults: terminalDefaults,
                                            tokenPlan: plan,
                                            kubeconfigYAML: kubeYAMLForVM)
            // Codex subscription: seed a bogus ~/.codex/auth.json before boot
            // so the guest runs without logging in (host owns the real token).
            seedCodexAuthFile(for: profile)
            seedGrokAuthFile(for: profile)
        }
        if let engine = mitmEngine {
            // Tell the trace store what level + session id to record
            // under for traffic from this profile.
            engine.setSessionTrace(
                MitmEngine.SessionTrace(sessionID: UUID(), level: profile.traceLevel),
                for: profile.id)
            // Profile name lookup for the consent dialog ("Profile X
            // wants to use credential Y").
            let broker = engine.consent
            let pidCopy = profile.id
            let nameCopy = profile.name
            Task.detached { await broker.setProfileName(nameCopy, for: pidCopy) }
            // Same plumbing for the guardrails prompt — "Allow write
            // on <scope> from profile <name>?"
            let gBroker = engine.guardrailsBroker
            Task.detached { await gBroker.setProfileName(nameCopy, for: pidCopy) }
            // And for the supply-chain prompts.
            let scBroker = engine.supplyChainBroker
            Task.detached { await scBroker.setProfileName(nameCopy, for: pidCopy) }
            let agentKeys = loadAgentKeys(for: profile)
            engine.sshAgent.setKeys(agentKeys, for: profile.id)
            // AWS creds: pushed to the host-side server. The guest's
            // ~/.aws/config points at a credential_process helper that
            // gets the real AKID + a fake secret; the host AWSResigner
            // re-signs each AWS request with the real material so the
            // secret never lives in the VM at all. setCredentials clears
            // the slot when the profile has no usable AWS creds.
            if profile.awsCredentials.authMode == .ssoProfile
                || profile.authMode == .bedrock {
                let profileID = profile.id
                let ssoProfileName = profile.awsCredentials.ssoProfileName
                let awsCreds = profile.awsCredentials
                FileHandle.standardError.write(Data(
                    "[sso] resolving credentials for SSO profile '\(ssoProfileName)'\n".utf8))
                Task { [weak engine, weak self] in
                    guard let engine else { return }
                    do {
                        let resolved = try await AWSSSOResolver.resolve(
                            profileName: ssoProfileName,
                            progress: { msg in
                                FileHandle.standardError.write(Data("[sso] \(msg)\n".utf8))
                            }
                        )
                        var creds = awsCreds
                        creds.accessKeyID = resolved.accessKeyID
                        creds.secretAccessKey = resolved.secretAccessKey
                        creds.sessionToken = resolved.sessionToken
                        if creds.region.isEmpty { creds.region = resolved.region }
                        engine.awsCreds.setCredentials(creds, for: profileID)

                        self?.ssoRefreshTasks[profileID] = AWSSSOResolver.startRefreshLoop(
                            profileName: ssoProfileName,
                            initialExpiration: resolved.expiration,
                            onRefresh: { [weak engine] newCreds in
                                var updated = awsCreds
                                updated.accessKeyID = newCreds.accessKeyID
                                updated.secretAccessKey = newCreds.secretAccessKey
                                updated.sessionToken = newCreds.sessionToken
                                engine?.awsCreds.setCredentials(updated, for: profileID)
                                FileHandle.standardError.write(Data(
                                    "[sso] refreshed credentials for '\(ssoProfileName)'\n".utf8))
                            },
                            onError: { error in
                                FileHandle.standardError.write(Data(
                                    "[sso] refresh failed: \(error.localizedDescription)\n".utf8))
                            }
                        )
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[sso] credential resolution failed: \(error.localizedDescription)\n".utf8))
                        engine.awsCreds.setCredentials(awsCreds, for: profileID)
                    }
                }
            } else {
                engine.awsCreds.setCredentials(profile.awsCredentials, for: profile.id)
            }
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': loaded \(agentKeys.count) agent key(s)\n".utf8))
            // Mirror the per-profile key into our private bromure
            // ssh-agent so the in-VM ssh client can sign with it
            // through the vsock-bridged agent socket.
            for key in agentKeys {
                addKeyToHostAgent(seed: key.seed,
                                  publicKey: key.publicKey,
                                  comment: "bromure-ac:\(profile.name)")
            }
            // Plus any pre-existing keys the user imported via the
            // editor — passphrase-protected ones use the macOS Keychain
            // for the password, fed through SSH_ASKPASS.
            loadImportedSSHKeys(for: profile)
            // Register approval metadata for imported keys whose flag
            // is on. The agent forwards SIGN_REQUESTs for these to the
            // host's bromure ssh-agent (we don't hold the seed in
            // process), so the broker is consulted just before that
            // forward. Keys without `publicKeyText` (no .pub on import)
            // can't be matched by blob and will sign without a prompt.
            var approvals: [Data: SSHAgentServer.ImportedApproval] = [:]
            for k in profile.importedSSHKeys where k.requireApproval {
                guard let blob = sshPublicKeyBlob(fromOpenSSHText: k.publicKeyText)
                else { continue }
                approvals[blob] = SSHAgentServer.ImportedApproval(
                    label: k.label,
                    consentCredentialID: ConsentCredentialID.sshKey(k.id.uuidString))
            }
            engine.sshAgent.setImportedKeyApprovals(approvals, for: profile.id)
        } else {
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': MITM ENGINE IS NIL — nothing will be wired\n".utf8))
        }

        // Create the pane that draws this VM. It's hosted in the shared unified
        // window (the unpeel-style source-list of every running VM) unless this
        // is a detached login-boot — then it boots window-less and the session
        // lives on detached. Promote to a regular app first in case we're
        // launching from a headless/background agent.
        let win = SessionPane(profile: profile, acDelegate: self)
        if detached {
            // Boots window-less: the pane binds the VZ view through boot, then
            // drops once the VM registers, leaving the session running detached.
            // Reattach via the menu-bar item or `vm attach`.
        } else {
            let unified = ensureUnifiedWindow()
            unified.addPane(win)
            NSApp.setActivationPolicy(.regular)
            unified.makeKeyAndOrderFront(nil)
        }
        // Newly-registered window — sync its streaming indicator
        // with the current enrollment + privateMode state.
        refreshStreamingState()
        refreshSidebar()

        // Pre-load saved tabs alongside the saved RAM snapshot. If
        // both exist, the resumed VM already has matching kittys
        // running (each one was started with `--class bromure-<UUID>`)
        // — we rebuild the host's tab bar against those instead of
        // spawning a brand-new kitty on top.
        let probeDisk = SessionDisk(
            profile: profile,
            store: store,
            baseDiskURL: imageManager.baseDiskURL
        )
        let savedTabs: SessionDisk.TabsState? =
            probeDisk.hasSavedState ? probeDisk.loadTabs() : nil

        if let saved = savedTabs, !saved.tabs.isEmpty {
            win.rehydrateTabs(from: saved)
        } else {
            // Fresh boot: show one placeholder pill while VZ + tmux come up.
            // The agent auto-creates tmux window 0; the roster reconciles this
            // placeholder to the real window list within a tick.
            win.model.tabs = [TabsModel.Tab(label: "shell")]
        }

        Task { @MainActor in
            let sessionDisk = SessionDisk(
                profile: profile,
                store: store,
                baseDiskURL: imageManager.baseDiskURL
            )
            sessionDisk.tokenPlan = plan
            sessionDisk.migrateHomeThisBoot = migrateHomeThisBoot
            if let engine = mitmEngine, let scriptURL = bridgeScriptURL {
                sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                    caCertificatePEM: engine.ca.certificatePEM,
                    bridgeScriptURL: scriptURL,
                    awsCredsHelperURL: awsCredsHelperURL,
                    claudeTokenAgentURL: claudeTokenAgentURL,
                    codexTokenAgentURL: codexTokenAgentURL,
                    // Always ship the shell agent now — `exec` is a first-class
                    // CLI verb, gated by the owner-only control socket.
                    shellAgentURL: shellAgentURL,
                    loopbackRelayAgentURL: loopbackRelayAgentURL,
                    agentdURL: agentdURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
            do {
                try sandbox.prepare()
                // ext4 home (and migrate boots, so post-migration seed
                // refreshes have a full baseline): stage the managed
                // dotfiles + manifest into the meta share prepare() just
                // built. The guest agent applies them before the session
                // starts.
                if profile.homeModel == .ext4 || migrateHomeThisBoot,
                   let seedDir = sessionDisk.homeSeedDirectory {
                    do {
                        try store.writeHomeSeedFiles(
                            for: profile, into: seedDir,
                            terminalDefaults: terminalDefaults,
                            tokenPlan: plan, kubeconfigYAML: kubeYAMLForVM)
                        let files = seedDir.appendingPathComponent("files", isDirectory: true)
                        seedCodexAuthFile(for: profile, homeRoot: files)
                        seedGrokAuthFile(for: profile, homeRoot: files)
                        try store.finalizeHomeSeed(for: profile, seedDir: seedDir)
                        // Bump even on a fresh boot (harmless — the agent
                        // baselines after its startup apply): on a RESTORE
                        // boot this is what tells the resumed agent that the
                        // seed changed while the workspace was suspended.
                        sessionDisk.bumpSeedGeneration()
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[ac] home-seed staging failed: \(error)\n".utf8))
                    }
                }
                // Migration progress → the pane's boot overlay; completion
                // stamps the profile so the next boot is image-only.
                if migrateHomeThisBoot {
                    self.wireHomeMigration(sandbox: sandbox, pane: win, profile: profile)
                }
                // Investigation mode: the saved snapshot was taken with
                // a NIC attached, but `prepare()` just built a config
                // with no network device — VZ would reject `restore`
                // for config drift. Boot fresh from the persisted disk
                // (the home dir + filesystem state are intact) so the
                // user can inspect on-disk artifacts offline.
                if sandbox.hasSavedState {
                    do {
                        try await sandbox.restore()
                        FileHandle.standardError.write(Data(
                            "[ac] restored '\(profile.name)' from saved state\n".utf8))
                    } catch {
                        // Restore failed — bad snapshot, configuration
                        // drift, or VZ refused. Drop the state file and
                        // do a fresh boot.
                        FileHandle.standardError.write(Data(
                            "[ac] restore failed (\(error)) — booting fresh\n".utf8))
                        sessionDisk.clearSavedState()
                        // VZ leaves the VM in an indeterminate state
                        // after a failed restore; rebuild it.
                        try sandbox.prepare()
                        try await sandbox.start()
                        // Restore failed → this is now a fresh boot. Drop the
                        // rehydrated pills; the agent creates tmux window 0 and
                        // the roster repopulates the bar.
                        win.model.tabs = [TabsModel.Tab(label: "shell")]
                        win.model.activeIndex = 0
                    }
                } else {
                    try await sandbox.start()
                }
            } catch {
                self.showError(error, message: "Couldn't start the VM for “\(profile.name)”.")
                self.unifiedWindow?.removePane(profile.id)
                self.unregisterPane(profile.id, ifMatches: win)
                return
            }
            // Register the per-VM vsock listeners on the freshly-booted
            // VM. Done after start so the socket device is live.
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
                engine.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
                engine.setSupplyChainPolicy(profile.supplyChain, for: profile.id)
                engine.setPromptInjectionPolicy(profile.promptInjection, for: profile.id)
                if profile.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
                if profile.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }
                // Fusion: show the title-bar toggle when configured, but
                // start disengaged — the user clicks the lightning bolt to
                // turn it on for the session.
                win.model.fusionConfigurable = profile.fusionConfigurable
                win.model.fusionEngaged = false
                engine.setFusionEngaged(false, for: profile.id)
                engine.setFusionConfig(self.makeFusionConfig(for: profile), for: profile.id)
                self.applyRouting(engine, for: profile)
                self.startLocalEngineIfNeeded(for: profile)
            }
            // Shell-exec bridge (vsock 5800). Always created now — powers
            // `bromure-ac exec` and the control socket's /exec route. The guest
            // ships shell-agent.py unconditionally; the surface is gated by the
            // owner-only control socket, not the debug env var.
            if let dev = sandbox.socketDevice {
                let bridge = ShellBridge(socketDevice: dev)
                self.shellBridges[profile.id] = bridge
            }
            if sessionDisk.didCloneOnLastEnsure, let current = currentBaseVersion {
                var p = profile
                p.baseImageVersionAtClone = current
                try? self.store.save(p)
                self.profiles = self.store.loadAll()
                self.refreshSidebar()
            }
            self.wireSandboxCallbacks(sandbox)
            self.registerSession(sandbox, profile: profile)
            win.sandbox = sandbox

            // No host-driven spawn/raise any more: the guest agent launches
            // the one fullscreen kitty → tmux session at X start (fresh boot),
            // and a restored snapshot already has that session with its windows
            // and last-active window intact. The roster repopulates the bar.

            // NAT-only: watch for the in-guest IP reporter to land an
            // address. If nothing arrives within the timeout, vmnet's
            // shared NAT path is likely wedged — offer to repair via
            // the same NetworkHealer the browser uses.
            if profile.networkMode == .nat {
                self.startNetworkHealerWatch(profile: profile, pane: win)
            }
        }
    }

    /// One-time home-storage upgrade offer for a legacy (virtiofs-home)
    /// workspace. Returns true when the user picked "Upgrade Now".
    @MainActor
    private func promptHomeStorageUpgrade(profile: Profile) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Upgrade “%@”’s home storage?", comment: ""),
            profile.name)
        var info = NSLocalizedString(
            "This workspace's home folder currently lives in a macOS folder shared into the VM. Bromure can move it onto a private ext4 disk image instead.\n\nWhy: suspended workspaces resume without confused tools (files keep their identity across suspend/resume), git repositories in the home are no longer exposed to shared-folder corruption, and the image automatically shrinks on your Mac as files are deleted inside the VM.\n\nThe move happens once, during the next boot — a large home can take a few minutes, with progress shown on the boot screen. Your current home folder is kept on the Mac as a backup.",
            comment: "")
        let probe = SessionDisk(profile: profile, store: store,
                                baseDiskURL: imageManager.baseDiskURL)
        if probe.hasSavedState {
            info += "\n\n" + NSLocalizedString(
                "This workspace has a suspended session; upgrading restarts it fresh.",
                comment: "")
        }
        info += "\n\n" + NSLocalizedString(
            "If you choose Not Now, you can upgrade anytime from the workspace editor.",
            comment: "")
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Upgrade Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Wire a migrate boot's guest-agent signals: progress → the pane's
    /// boot overlay, completion → stamp the profile `.ext4`, park the old
    /// host-side home as a backup, and mark the session so close-time
    /// suspend becomes a clean shutdown (the migrate boot's dual-attach
    /// config won't exist next launch, so its snapshot couldn't restore).
    @MainActor
    private func wireHomeMigration(sandbox: UbuntuSandboxVM,
                                   pane: SessionPane,
                                   profile: Profile) {
        pane.updateBootStatus(
            NSLocalizedString("UPGRADING HOME STORAGE", comment: ""), progress: nil)
        sandbox.onHomeMigrationProgress = { [weak pane] phase, done, total in
            guard phase == "copy" || phase == "verify" else { return }
            let text: String
            let fraction: Double?
            if total > 0 {
                let pct = min(100, Int((Double(done) / Double(total)) * 100))
                text = String(
                    format: NSLocalizedString("MOVING HOME — %d%% OF %@", comment: ""),
                    pct, ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                fraction = min(1.0, Double(done) / Double(total))
            } else {
                text = String(
                    format: NSLocalizedString("MOVING HOME — %@ COPIED", comment: ""),
                    ByteCountFormatter.string(fromByteCount: done, countStyle: .file))
                fraction = nil
            }
            pane?.updateBootStatus(text, progress: fraction)
        }
        sandbox.onHomeMigrated = { [weak self, weak pane] in
            guard let self else { return }
            pane?.updateBootStatus(nil, progress: nil)
            // Stamp: from now on this workspace boots from home.img and
            // never attaches the old virtiofs home again.
            if var p = self.profiles.first(where: { $0.id == profile.id }) {
                p.homeModel = .ext4
                try? self.store.save(p)
                self.profiles = self.store.loadAll()
            }
            self.runningSessions[profile.id]?.homeJustMigrated = true
            // Park the old home as a backup (inode is unchanged, so the
            // still-attached — but now fully shadowed — virtiofs share in
            // THIS session keeps working). Surfaced in the storage UI.
            let old = self.store.homeDirectory(for: profile)
            let backup = self.store.homeBackupDirectory(for: profile)
            if FileManager.default.fileExists(atPath: old.path),
               !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: old, to: backup)
            }
            FileHandle.standardError.write(Data(
                "[ac] '\(profile.name)' home migrated to ext4 image\n".utf8))
        }
    }

    /// Per-session network-health watch. Polls the window's reported
    /// IP for ~25s. If the guest hasn't gotten an address by then,
    /// presents a Repair / Continue / Cancel dialog; on Repair runs
    /// `NetworkHealer.shared.repair(.both)` and relaunches the
    /// session against a fresh VM.
    @MainActor
    private func startNetworkHealerWatch(profile: Profile,
                                         pane: SessionPane) {
        Task { @MainActor [weak self, weak pane] in
            // 25 polls × 1s = 25s window. xinitrc reports the address
            // on a 5s loop, so we expect it well within this budget on
            // a healthy install (typically 4-8s after boot).
            for _ in 0..<25 {
                try? await Task.sleep(for: .seconds(1))
                if pane == nil { return }
                if pane?.model.ipAddress?.isEmpty == false { return }
            }
            guard let self, let pane,
                  pane.host?.paneHostWindow?.isVisible == true else { return }
            // Re-check inside the @MainActor isolation in case the IP
            // landed during the last sleep tick.
            if pane.model.ipAddress?.isEmpty == false { return }
            await self.presentNetworkHealerPrompt(profile: profile, pane: pane)
        }
    }

    @MainActor
    private func presentNetworkHealerPrompt(profile: Profile,
                                            pane: SessionPane) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Network Issue", comment: "")
        alert.informativeText = NSLocalizedString(
            "The VM didn't get a network address. macOS's shared networking stack (vmnet) may be wedged.",
            comment: ""
        ) + "\n\n" + NSLocalizedString(
            "Bromure can restart the macOS networking daemons. You'll be asked for your password.",
            comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Repair Network", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue Anyway", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Tear down the wedged session before kickstarting — the
            // VM's NIC needs a fresh DHCP exchange after the daemon
            // restart, easier from a clean boot than mid-session.
            detachSession(profile.id)
            let ok = await NetworkHealer.shared.repair(.both)
            if !ok {
                let failed = NSAlert()
                failed.messageText = NSLocalizedString("Network Repair Cancelled", comment: "")
                failed.informativeText = NSLocalizedString(
                    "The repair was cancelled or failed. Try again from the menu.",
                    comment: ""
                )
                failed.alertStyle = .warning
                failed.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                failed.runModal()
                return
            }
            // Fresh launch with kickstarted vmnet.
            launch(profile)
        case .alertSecondButtonReturn:
            // Continue with the broken VM — user opted out of repair.
            return
        default:
            // Cancel: just detach the wedged session (VM keeps running).
            detachSession(profile.id)
        }
    }

    /// Add another tab (= a new tmux window). Wired from the toolbar "+"
    /// button and ⌘T. The roster tick adds the pill — tmux is authoritative.
    func spawnNewTab(in pane: SessionPane) {
        sendCommand("new-tab", in: pane)
    }

    /// Pin the workspace's active terminal into the grid and land on it —
    /// ⌘D and the Workspaces menu. Same payload as dragging the tab onto the
    /// sidebar's Grid node, but the stage switches to the grid with the cell
    /// focused. Docker attach tabs live under their container, not the tab
    /// bar, so they're not grid material.
    func addActiveTerminalToGrid(in pane: SessionPane) {
        guard let tab = pane.model.activeTab, tab.containerID == nil else { return }
        unifiedWindow?.addToGridAndReveal(profileID: pane.profile.id,
                                          windowIndex: tab.index,
                                          label: tab.shownLabel)
    }

    /// Select a tab → tmux select-window at that index (index == bar position).
    func requestSelectTab(index: Int, in pane: SessionPane) {
        sendCommand("select-tab \(index)", in: pane)
    }

    /// Close a tab → tmux kill-window at that index.
    func requestCloseTab(index: Int, in pane: SessionPane) {
        sendCommand("close-tab \(index)", in: pane)
    }

    // MARK: - Git worktrees
    //
    // All args are base64 (space-joined; base64 has no spaces) so paths and
    // pretty names with spaces/parens survive the guest's `set -- $arg` split.

    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Create a git worktree off `cwd`'s HEAD and open a tab in it running
    /// `tool`. `cwd` may itself be a worktree — the new branch descends from
    /// whatever's checked out there (recursive nesting). `prompt` (v3) is the
    /// agent's initial message; nil/empty → the sentinel "-".
    func requestCreateWorktree(cwd: String, slug: String, display: String,
                               tool: String, prompt: String?, in pane: SessionPane) {
        let p = (prompt?.isEmpty == false) ? b64(prompt!) : "-"
        sendCommand("worktree-create \(b64(cwd)) \(b64(slug)) \(b64(display)) \(b64(tool)) \(p)", in: pane)
    }

    /// Merge `sourceBranch` into `targetBranch` (an ancestor) in a visible tab
    /// checked out at the target. The guest resolves the target's checkout from
    /// `mainRoot`; `display` labels the merge tab.
    func requestMergeWorktree(sourceBranch: String, targetBranch: String,
                              mainRoot: String, display: String, tool: String,
                              in pane: SessionPane) {
        sendCommand("worktree-merge \(b64(sourceBranch)) \(b64(targetBranch)) \(b64(mainRoot)) \(b64(display)) \(b64(tool))", in: pane)
    }

    /// Open a PR-authoring tab in the worktree's checkout: the agent gets a
    /// best-practices prompt (guest-side `_PR_PROMPT`) to review the branch,
    /// push it, and `gh pr create` against `targetBranch`. Only offered when
    /// the profile carries a GitHub token — that token is what authenticates
    /// `gh` inside the VM.
    func requestWorktreePR(sourceBranch: String, targetBranch: String,
                           mainRoot: String, display: String, tool: String,
                           in pane: SessionPane) {
        sendCommand("worktree-pr \(b64(sourceBranch)) \(b64(targetBranch)) \(b64(mainRoot)) \(b64(display)) \(b64(tool))", in: pane)
    }

    /// Remove a worktree and delete its branch (post-merge cleanup).
    func requestRemoveWorktree(mainRoot: String, branch: String, in pane: SessionPane) {
        sendCommand("worktree-remove \(b64(mainRoot)) \(b64(branch))", in: pane)
    }

    /// Spawn the agent in a conflicted merge checkout to resolve it (v3).
    func requestResolveWorktree(dir: String, tool: String, in pane: SessionPane) {
        sendCommand("worktree-resolve \(b64(dir)) \(b64(tool))", in: pane)
    }

    /// Open a plain terminal tab in a worktree's checkout — no agent, just a
    /// shell cd'd there so the user can inspect/test the worktree by hand.
    /// Shown nested under the worktree (the guest tags the window with
    /// @parent_branch only). The guest resolves the dir from the branch.
    func requestAttachTerminal(mainRoot: String, branch: String, in pane: SessionPane) {
        sendCommand("worktree-terminal \(b64(mainRoot)) \(b64(branch))", in: pane)
    }

    /// Queue a worktree command for a (possibly detached) session — the SSH/CLI
    /// path. Builds the same guest command as the GUI request functions but
    /// writes straight to the session's outbox, so no window/pane is needed.
    @MainActor
    func automationWorktreeCommand(profileNameOrID: String, action: String, args: [String]) -> Bool {
        guard let p = profileByNameOrID(profileNameOrID),
              let session = runningSessions[p.id],
              let outbox = session.sandbox.sessionDisk?.outboxDirectory else { return false }
        let name: String
        let encoded: [String]
        switch action {
        case "create":
            guard args.count >= 4 else { return false }   // cwd, slug, display, tool[, prompt]
            name = "worktree-create"
            let prompt = (args.count >= 5 && !args[4].isEmpty) ? b64(args[4]) : "-"
            encoded = [b64(args[0]), b64(args[1]), b64(args[2]), b64(args[3]), prompt]
        case "run":
            // Automation fire: same layout as "create", but the guest falls
            // back to a plain agent tab when cwd isn't a git repo.
            guard args.count >= 4 else { return false }   // cwd, slug, display, tool[, prompt]
            name = "automation-run"
            let prompt = (args.count >= 5 && !args[4].isEmpty) ? b64(args[4]) : "-"
            encoded = [b64(args[0]), b64(args[1]), b64(args[2]), b64(args[3]), prompt]
        case "finish":
            guard args.count >= 1 else { return false }   // worktree branch
            name = "automation-finish"; encoded = [b64(args[0])]
        case "merge":
            guard args.count >= 5 else { return false }   // src, target, mainRoot, display, tool
            name = "worktree-merge"; encoded = args.prefix(5).map(b64)
        case "pr":
            guard args.count >= 5 else { return false }   // src, target, mainRoot, display, tool
            name = "worktree-pr"; encoded = args.prefix(5).map(b64)
        case "remove":
            guard args.count >= 2 else { return false }   // mainRoot, branch
            name = "worktree-remove"; encoded = args.prefix(2).map(b64)
        case "resolve":
            guard args.count >= 2 else { return false }   // dir, tool
            name = "worktree-resolve"; encoded = args.prefix(2).map(b64)
        case "terminal":
            guard args.count >= 2 else { return false }   // mainRoot, branch
            name = "worktree-terminal"; encoded = args.prefix(2).map(b64)
        default:
            return false
        }
        let line = ([name] + encoded).joined(separator: " ")
        let file = outbox.appendingPathComponent("cmd-\(UUID().uuidString).txt")
        try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// Tab command for a (possibly detached) running session — the SSH/CLI
    /// counterpart of the GUI's ⌘T / tab switch. Queues the guest command
    /// (new-tab / select-tab / close-tab) to the session's outbox.
    @MainActor
    func automationTabCommand(profileNameOrID: String, action: String, index: Int) -> Bool {
        guard let p = profileByNameOrID(profileNameOrID),
              let session = runningSessions[p.id],
              let outbox = session.sandbox.sessionDisk?.outboxDirectory else { return false }
        let line: String
        switch action {
        case "new":    line = "new-tab"
        case "select": line = "select-tab \(index)"
        case "close":  line = "close-tab \(index)"
        default:       return false
        }
        let file = outbox.appendingPathComponent("cmd-\(UUID().uuidString).txt")
        try? (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Scheduled automations

    /// Persist an automation from the editor and replant its next fire
    /// immediately, so the sidebar row shows "next …" without waiting for
    /// the engine's 30-second tick.
    func saveAutomation(_ automation: ScheduledAutomation) {
        scheduledAutomationStore.upsert(automation)
        scheduledAutomationEngine.tick()
    }

    func runAutomationNow(_ id: UUID) {
        guard let automation = scheduledAutomationStore.automation(id) else { return }
        scheduledAutomationEngine.runNow(automation)
    }

    func toggleAutomation(_ id: UUID) {
        guard var automation = scheduledAutomationStore.automation(id) else { return }
        automation.enabled.toggle()
        saveAutomation(automation)
    }

    /// Delete with a confirmation — automations are cheap to recreate, but a
    /// misclick on a context menu shouldn't silently drop a schedule.
    func confirmDeleteAutomation(_ id: UUID) {
        guard let automation = scheduledAutomationStore.automation(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete “%@”?", comment: "delete automation"),
            automation.name.isEmpty
                ? NSLocalizedString("Untitled automation", comment: "") : automation.name)
        alert.informativeText = NSLocalizedString(
            "The schedule and its run history are removed. Worktrees already created by past runs are kept.",
            comment: "delete automation")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        scheduledAutomationStore.remove(id)
        unifiedWindow?.clearAutomationEditor()
    }

    // MARK: Worktree dialogs

    /// A filesystem/branch-safe slug from a free-form task name.
    private func worktreeSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(40)).isEmpty ? "worktree" : String(trimmed.prefix(40))
    }

    /// "New worktree…" dialog: task name, tool, and an optional initial prompt.
    @MainActor
    func presentCreateWorktree(cwd: String, defaultTool: String, in pane: SessionPane) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("New worktree", comment: "")
        alert.informativeText = NSLocalizedString(
            "Creates a git worktree branched from this tab's current commit and opens a nested agent in it.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Create", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 68, width: 320, height: 24))
        nameField.placeholderString = NSLocalizedString("Task name (e.g. Website refactoring)", comment: "")
        let toolPopup = NSPopUpButton(frame: NSRect(x: 0, y: 36, width: 320, height: 24))
        let tools = ["claude", "codex", "grok"]
        toolPopup.addItems(withTitles: tools)
        toolPopup.selectItem(withTitle: tools.contains(defaultTool) ? defaultTool : "claude")
        let promptField = NSTextField(frame: NSRect(x: 0, y: 4, width: 320, height: 24))
        promptField.placeholderString = NSLocalizedString("Initial prompt (optional)", comment: "")
        container.addSubview(nameField)
        container.addSubview(toolPopup)
        container.addSubview(promptField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let tool = toolPopup.titleOfSelectedItem ?? defaultTool
        let display = "\(name) (\(tool))"
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        requestCreateWorktree(cwd: cwd, slug: worktreeSlug(name), display: display,
                              tool: tool, prompt: prompt.isEmpty ? nil : prompt, in: pane)
    }

    /// "Merge…" dialog: pick a destination along the ancestor chain. Defaults to
    /// the immediate parent; higher targets are flagged as skipping intermediates.
    @MainActor
    func presentMergeWorktree(tab: TabsModel.Tab, allTabs: [TabsModel.Tab], in pane: SessionPane) {
        guard let branch = tab.worktreeBranch, let mainRoot = tab.rootRepo else { return }
        // Ancestor chain: follow parentBranch through the sibling worktree tabs,
        // then terminate at the main repo (the last parentBranch that isn't a
        // worktree here). Each entry is (targetBranch, human label).
        var chain: [(branch: String, label: String)] = []
        var parentBranch = tab.parentBranch
        var guardCount = 0
        while let pb = parentBranch, !pb.isEmpty, guardCount < 8 {
            if let parent = allTabs.first(where: { $0.worktreeBranch == pb }) {
                chain.append((pb, parent.shownLabel))
                parentBranch = parent.parentBranch
            } else {
                chain.append((pb, String(format: NSLocalizedString("%@ (repo root)", comment: ""), pb)))
                break
            }
            guardCount += 1
        }
        guard !chain.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Merge “%@”", comment: ""), tab.shownLabel)
        alert.informativeText = NSLocalizedString(
            "Runs the merge in a new tab in the destination's checkout. Only committed work on this branch is merged. If it conflicts, the coding agent is started right there to resolve it automatically. The worktree isn't discarded — use “Discard worktree” once you're happy.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Merge", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        // A GitHub token means the VM's `gh` is authenticated — offer opening
        // a PR instead of merging locally. The agent drives it from a
        // best-practices prompt (guest-side _PR_PROMPT).
        let canPR = pane.profile.hasGitHubCredential
        if canPR {
            alert.informativeText += "\n\n" + NSLocalizedString(
                "Create Pull Request instead pushes the branch and has the agent open a clean GitHub PR against the selected destination.",
                comment: "")
            alert.addButton(withTitle: NSLocalizedString("Create Pull Request", comment: ""))
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for (i, dest) in chain.enumerated() {
            // The immediate parent (index 0) is the safe default; anything above
            // skips the intermediate worktrees, which then won't get these changes.
            popup.addItem(withTitle: i == 0 ? dest.label
                : String(format: NSLocalizedString("%@  ⚠︎ skips intermediates", comment: ""), dest.label))
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        let response = alert.runModal()
        let target = chain[popup.indexOfSelectedItem]
        switch response {
        case .alertFirstButtonReturn:
            requestMergeWorktree(sourceBranch: branch, targetBranch: target.branch,
                                 mainRoot: mainRoot, display: tab.shownLabel,
                                 tool: pane.profile.tool.rawValue, in: pane)
        case .alertThirdButtonReturn where canPR:
            requestWorktreePR(sourceBranch: branch, targetBranch: target.branch,
                              mainRoot: mainRoot, display: tab.shownLabel,
                              tool: pane.profile.tool.rawValue, in: pane)
        default:
            return   // Cancel
        }
    }

    /// "Discard worktree" confirmation: remove the checkout + delete the branch.
    @MainActor
    func confirmRemoveWorktree(tab: TabsModel.Tab, in pane: SessionPane) {
        guard let branch = tab.worktreeBranch, let mainRoot = tab.rootRepo else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("Discard worktree “%@”?", comment: ""), tab.shownLabel)
        alert.informativeText = String(
            format: NSLocalizedString(
                "Removes the checkout and deletes branch “%@”. Any commits on this branch that haven't been merged will be lost.",
                comment: ""), branch)
        alert.addButton(withTitle: NSLocalizedString("Discard", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        requestRemoveWorktree(mainRoot: mainRoot, branch: branch, in: pane)
        // Close the tab too — its cwd is about to vanish.
        if tab.index >= 0 { requestCloseTab(index: tab.index, in: pane) }
    }

    /// Attach to a running docker container in a new tab → the guest spawns a
    /// tmux window running `docker exec -it <id> <shell>`. The shell is
    /// user-supplied (the popover field), so sanitise it to a conservative
    /// charset and fall back to `sh` for anything empty or suspicious — the
    /// command is interpolated into a guest shell line, so this is the trust
    /// boundary. The container id comes from `docker ps`, not the user.
    /// `sh` (not `bash`) is the default: it's present in virtually every image,
    /// whereas bash often isn't (alpine/distroless), where attach would fail.
    func requestDockerAttach(containerID: String, shell: String, in pane: SessionPane) {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        let trimmed = shell.trimmingCharacters(in: .whitespaces)
        let safe = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy(allowed.contains)
            ? trimmed : "sh"
        sendCommand("docker-attach \(containerID) \(safe)", in: pane)
    }

    /// Conservative charset for ids/names interpolated into a guest shell line.
    private static let dockerIDAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.:@")

    private func sanitizedDockerID(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy(Self.dockerIDAllowed.contains) else { return nil }
        return t
    }

    func requestDockerStart(containerID: String, in pane: SessionPane) {
        guard let id = sanitizedDockerID(containerID) else { return }
        sendCommand("docker-start \(id)", in: pane)
    }
    func requestDockerStop(containerID: String, in pane: SessionPane) {
        guard let id = sanitizedDockerID(containerID) else { return }
        sendCommand("docker-stop \(id)", in: pane)
    }
    func requestDockerRemove(containerID: String, in pane: SessionPane) {
        guard let id = sanitizedDockerID(containerID) else { return }
        sendCommand("docker-remove \(id)", in: pane)
    }
    /// Open `docker logs -f <container>` in a new tmux tab nested under the
    /// container in the source-list.
    func requestDockerLogs(containerID: String, in pane: SessionPane) {
        guard let id = sanitizedDockerID(containerID) else { return }
        sendCommand("docker-logs \(id)", in: pane)
    }

    /// Install cross-arch QEMU emulation (binfmt handlers) in the workspace.
    func requestDockerBinfmtInstall(in pane: SessionPane) {
        sendCommand("docker-binfmt", in: pane)
    }

    /// Disable cross-arch emulation (unregister binfmt + drop the marker).
    func requestDockerBinfmtUninstall(in pane: SessionPane) {
        sendCommand("docker-binfmt-off", in: pane)
    }

    /// User-supplied fields for the "new container" dialog.
    struct DockerRunSpec {
        var image: String
        var name: String = ""
        var ports: [String] = []     // "8080:80"
        var env: [String] = []       // "KEY=val"
        var volumes: [String] = []   // "/host:/container"
        /// Pass the workspace's whole environment (API tokens, etc.) through.
        var inheritEnv: Bool = false
        /// Pass just the HTTP(S) proxy vars (covered by inheritEnv when set).
        var inheritProxy: Bool = false
        /// Run with a TTY (-it) in a fresh tmux tab instead of detached (-d).
        var interactive: Bool = false
    }

    /// Launch a new container. The whole `docker run -d …` command is assembled
    /// HERE with POSIX single-quoting of every user field, then run on the guest
    /// via `bash -c` — so values can't break out of their argument. Newlines are
    /// stripped (the command travels as one line in the cmd file).
    func requestDockerRun(spec: DockerRunSpec, in pane: SessionPane) {
        let image = spec.image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return }
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var cmd = spec.interactive ? "docker run -it" : "docker run -d"
        // For interactive runs we need a known container name so the guest can
        // tag the tmux tab and the sidebar can nest it under its container —
        // generate one when the user didn't supply it.
        var name = spec.name.trimmingCharacters(in: .whitespaces)
        if spec.interactive && name.isEmpty {
            name = "bromure-" + UUID().uuidString.prefix(6).lowercased()
        }
        if !name.isEmpty {
            cmd += " --name \(q(name))"
        }
        for p in spec.ports where !p.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -p \(q(p.trimmingCharacters(in: .whitespaces)))"
        }
        for e in spec.env where !e.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -e \(q(e.trimmingCharacters(in: .whitespaces)))"
        }
        for v in spec.volumes where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -v \(q(v.trimmingCharacters(in: .whitespaces)))"
        }
        cmd += " \(q(image))"
        cmd = cmd.replacingOccurrences(of: "\n", with: " ")
        // The guest builds the --env-file by sourcing ONLY the host-injected env
        // files on the metadata share (tokens from api_key.env, proxy from
        // proxy.env) — not the whole shell environment — then runs this command
        // backgrounded so it can't wedge the command loop.
        let mode = spec.inheritEnv
            ? (spec.inheritProxy ? "both" : "env")
            : (spec.inheritProxy ? "proxy" : "none")
        // <mode> <interactive 0|1> <tag> <image> <command>. <tag> is the
        // container name interactive tabs nest under ("-" otherwise); <image> is
        // the bare ref the guest pre-pulls (with progress) for detached runs.
        let tag = (spec.interactive && !name.isEmpty) ? name : "-"
        sendCommand("docker-run \(mode) \(spec.interactive ? "1" : "0") \(tag) \(image) \(cmd)", in: pane)
    }

    /// Toggle the guest's expensive dashboard polling (CPU/mem + images) by
    /// creating/removing the `.docker-watch` marker in the outbox. Called when a
    /// Docker dashboard is shown/hidden so `docker stats` only runs when visible.
    func setDockerWatch(_ on: Bool, in pane: SessionPane) {
        guard let outbox = pane.sandbox?.sessionDisk?.outboxDirectory else { return }
        let marker = outbox.appendingPathComponent(".docker-watch")
        if on {
            // The outbox is a read-write share the (untrusted) guest writes to.
            // `.docker-watch` is the only host write here with a fixed,
            // guest-predictable name, so a non-atomic write would follow a
            // symlink the guest plants in its place (e.g. → ~/.ssh/authorized_keys)
            // and truncate that host file. `.atomic` writes a temp file and
            // renames it into place, replacing any planted symlink instead of
            // following it — matching the safe pattern `sendCommand` uses below.
            try? Data().write(to: marker, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private func sendCommand(_ command: String, in pane: SessionPane) {
        guard let outbox = pane.sandbox?.sessionDisk?.outboxDirectory else { return }
        let file = outbox.appendingPathComponent("cmd-\(UUID().uuidString).txt")
        try? (command + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Confirm + execute the wipe of a compromised profile. Returns
    /// true if the user accepted and the wipe ran, false on cancel.
    /// On true, the caller proceeds with the regular launch path —
    /// the disk + home no longer exist, so it'll mint fresh ones.
    @MainActor
    private func confirmWipeAndProceed(profile: Profile) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if let symbol = NSImage(
            systemSymbolName: "exclamationmark.octagon.fill",
            accessibilityDescription: "Compromised VM warning") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            alert.icon = symbol.withSymbolConfiguration(cfg)
        }
        alert.messageText = String(
            format: NSLocalizedString("⛔ “%@” is marked as compromised", comment: ""),
            profile.name)
        var info = NSLocalizedString(
            "Bromure refused to boot this VM because the proxy detected an outbound credential leak in a previous session.",
            comment: "")
        info += "\n\n"
        info += NSLocalizedString(
            "To continue, the VM disk image and the persistent home folder must be wiped. Your tokens, ssh keys, and workspace settings are preserved.",
            comment: "")
        // Surface the shared-folder warning. Listing the paths
        // explicitly is cheap and makes "where do I look?" obvious.
        let shares = profile.folderPaths
        if !shares.isEmpty {
            info += "\n\n"
            info += NSLocalizedString(
                "WARNING: shared folders are NOT wiped. Compromised packages or files may still be present in:",
                comment: "")
            info += "\n"
            for path in shares {
                info += "  • \(path)\n"
            }
            info += NSLocalizedString(
                "Inspect those folders before launching anything that re-uses them.",
                comment: "")
        }
        alert.informativeText = info
        alert.addButton(withTitle: NSLocalizedString("Wipe and Launch", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        // Esc → Cancel. Don't let an enter-press auto-confirm a
        // destructive wipe; remove the default keyEquivalent on the
        // first button so the user has to click it explicitly.
        alert.buttons.first?.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let session = SessionDisk(
            profile: profile, store: store,
            baseDiskURL: imageManager.baseDiskURL)
        session.wipeForCompromise()
        emitDiskResetEvent(profile: profile, reason: "compromised")
        // Re-render so the badge disappears immediately. (`launch`
        // continues right after this, but the picker behind the
        // session window will reflect the change once focus returns.)
        refreshSidebar()
        return true
    }

    /// True while a compromise alert is up on screen. The swap-time
    /// detector can fire many times back-to-back (one per outbound
    /// request the VM attempts); without this flag we'd stack alerts
    /// behind each other instead of letting the user act once.
    private var compromiseAlertActive: Bool = false

    /// Handle a compromise event: pause the VM immediately so no further
    /// outbound bytes flow, then present the alert. The user picks
    /// Shutdown / Save for Investigation / Continue and we drive the
    /// VM accordingly.
    @MainActor
    func handleCompromise(_ event: CompromiseEvent) {
        if compromiseAlertActive { return }
        // The VM may be detached (no pane, VM still running). A compromise must
        // still pause it and surface the alert, so force a reattach first — that
        // binds a view to the live VM so the user sees the frozen frame.
        if !isAttached(event.profileID),
           let session = runningSessions[event.profileID] {
            attachWindow(to: session)
        }
        guard let window = pane(for: event.profileID),
              let sandbox = window.sandbox,
              let vm = sandbox.vm else { return }
        // Surface the compromised VM (select it in the unified window / bring
        // its pop-out forward) so the frozen frame is actually on screen.
        revealSession(event.profileID)

        compromiseAlertActive = true

        // Pause now — synchronous from the user's perspective. If pause
        // is unavailable (already paused or VM in error state) we just
        // proceed: the proxy already wrote a 451 back to the guest, so
        // the malicious request was blocked regardless.
        Task { @MainActor in
            defer { self.compromiseAlertActive = false }
            if vm.canPause {
                do { try await vm.pause() }
                catch {
                    FileHandle.standardError.write(Data(
                        "[ac] compromise: pause failed (\(error))\n".utf8))
                }
            }
            // Tint goes on AFTER pause so the user sees the
            // last-rendered frame freeze and bloom red, not the
            // tint flash before the framebuffer stops.
            window.setSuspendedTint(true)

            let action = self.presentCompromiseAlert(event: event,
                                                      profileName: window.profile.name)
            switch action {
            case .shutdown:
                // No export, but the disk + home are still presumed
                // contaminated. Mark compromised; the next launch will
                // refuse to boot until the user wipes.
                sandbox.sessionDisk?.markCompromised()
                sandbox.sessionDisk?.clearSavedState()
                vm.stop(completionHandler: { _ in })
                self.detachSession(event.profileID)

            case .saveForInvestigation:
                // Pick a destination folder, then bundle (1) the disk
                // image, (2) a tar.gz of the per-profile home dir,
                // (3) one tar.gz per shared folder. Whether the export
                // succeeds or not, the profile gets the compromised
                // mark — the user has already classified this VM as
                // suspicious and shouldn't be allowed to launch it
                // again without an explicit wipe.
                if let dest = self.askForInvestigationDestination(profileName: window.profile.name),
                   let session = sandbox.sessionDisk {
                    do {
                        try self.exportForInvestigation(
                            session: session,
                            destination: dest)
                        FileHandle.standardError.write(Data(
                            "[ac] investigation export complete → \(dest.path)\n".utf8))
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[ac] investigation export failed: \(error)\n".utf8))
                        self.showError(error,
                                       message: "Couldn't export the VM for investigation. The workspace will still be marked compromised.")
                    }
                }
                sandbox.sessionDisk?.markCompromised()
                sandbox.sessionDisk?.clearSavedState()
                vm.stop(completionHandler: { _ in })
                self.detachSession(event.profileID)

            case .continueAnyway:
                // User accepted the risk. Resume the VM. The proxy
                // already returned 451 for the leaking request — if
                // the VM tries again, the detector fires again and
                // the alert re-opens.
                window.setSuspendedTint(false)
                if vm.state == .paused {
                    do { try await vm.resume() }
                    catch {
                        FileHandle.standardError.write(Data(
                            "[ac] compromise: resume failed (\(error))\n".utf8))
                    }
                }
            }
        }
    }

    /// Modal NSOpenPanel asking the user where to drop the
    /// investigation bundle. Returns nil if the user cancels.
    @MainActor
    private func askForInvestigationDestination(profileName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Save Investigation Here", comment: "")
        panel.message = String(
            format: NSLocalizedString(
                "Choose a folder to receive the disk image, home archive, and shared-folder archives for “%@”.",
                comment: ""),
            profileName)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        return dir
    }

    /// Copy the disk + tar-gzip the home dir + tar-gzip each shared
    /// folder into `destination`. Throws on the first hard failure;
    /// the caller surfaces the error and proceeds to mark compromised
    /// regardless. Layout under the destination:
    ///
    ///   destination/
    ///     disk.img
    ///     home.tar.gz
    ///     shares/
    ///       <basename>.tar.gz   (one per profile.folderPaths entry)
    ///
    /// VM is paused on entry, so the disk + home are quiescent — a
    /// straight file copy / tar is consistent with no extra locking.
    private func exportForInvestigation(session: SessionDisk,
                                          destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 1. Disk image — straight copy. APFS clonefile would be ideal
        //    when source + dest are on the same volume, but we don't
        //    know the destination volume so the safe move is copyItem,
        //    which uses clonefile under the hood when applicable.
        let diskDst = destination.appendingPathComponent("disk.img")
        if fm.fileExists(atPath: diskDst.path) {
            try fm.removeItem(at: diskDst)
        }
        try fm.copyItem(at: session.diskURL, to: diskDst)

        // 2. Home dir → home.tar.gz. Skip silently if the dir doesn't
        //    exist (e.g. the user reset home recently and never relaunched).
        let homeURL = session.homeDirectory
        if fm.fileExists(atPath: homeURL.path) {
            let homeDst = destination.appendingPathComponent("home.tar.gz")
            try Self.tarGzip(source: homeURL, destination: homeDst)
        }

        // 3. Shared folders → shares/<basename>.tar.gz. Each one is the
        //    user's project dir, so the tarball preserves that. We name
        //    by the dedup'd basename `SessionDisk.SharedFolder.mountName`
        //    — same names the user sees in the welcome banner.
        let shares = session.sharedFolders
        if !shares.isEmpty {
            let sharesDir = destination.appendingPathComponent("shares")
            try fm.createDirectory(at: sharesDir, withIntermediateDirectories: true)
            for share in shares {
                guard fm.fileExists(atPath: share.url.path) else { continue }
                let archive = sharesDir.appendingPathComponent("\(share.mountName).tar.gz")
                try Self.tarGzip(source: share.url, destination: archive)
            }
        }
    }

    /// Shell out to bsdtar (always present on macOS) to produce a
    /// gzip-compressed tarball. We invoke `tar -C parent -czf out base`
    /// so the archive contains a single root entry named after the
    /// source — extracts cleanly into `<basename>/...` rather than
    /// dumping its contents in the cwd.
    private static func tarGzip(source: URL, destination: URL) throws {
        let parent = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = [
            "-C", parent.path,
            "-czf", destination.path,
            base
        ]
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "tar failed (\(task.terminationStatus))"
            throw NSError(domain: "BromureAC.Investigation", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "tar \(base): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    /// Modal alert. Big red banner + per-leak detail line. Returns
    /// the user's chosen action.
    @MainActor
    private func presentCompromiseAlert(event: CompromiseEvent,
                                         profileName: String) -> CompromiseAction {
        let alert = NSAlert()
        alert.alertStyle = .critical
        // NSAlert.critical paints a tiny yellow caution badge over the
        // app icon by default, which doesn't read as "stop everything"
        // at a glance. Replace the icon with a 64-pt red
        // exclamationmark.octagon (the macOS "danger" symbol) so the
        // alert visually screams the way the situation deserves.
        if let symbol = NSImage(
            systemSymbolName: "exclamationmark.octagon.fill",
            accessibilityDescription: "VM compromise warning") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            alert.icon = symbol.withSymbolConfiguration(cfg)
        }
        alert.messageText = NSLocalizedString(
            "This environment may have been compromised",
            comment: "Compromise alert title")
        var info = String(
            format: NSLocalizedString(
                "Bromure detected an outbound attempt to leak a session credential from “%@” to a host it was not minted for. The VM has been paused.",
                comment: ""),
            profileName) + "\n\n"
        info += NSLocalizedString(
            "Detected leaks:", comment: "") + "\n"
        for leak in event.leaks {
            info += String(
                format: NSLocalizedString(
                    "  • %1$@ (%2$@) — expected %3$@, sent to %4$@\n",
                    comment: "Compromise leak detail line: fake preview, credential name, expected host, observed host"),
                leak.fakeTokenPreview,
                leak.credentialDisplayName,
                leak.declaredHost,
                leak.observedHost)
        }
        info += "\n" + NSLocalizedString(
            "Save for Investigation lets you pick a folder where Bromure will copy the disk image and gzipped archives of the home directory and shared folders. The VM's RAM state is discarded. The VM is then shut down and the workspace is marked compromised.",
            comment: "")
        alert.informativeText = info
        // Order: dismissive default first would let an enter-press hide
        // the warning. Make Shut Down the default — it's the safest.
        alert.addButton(withTitle: NSLocalizedString("Shut down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Save for Investigation", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        // Cmd-period / Esc maps to the third button (Continue) by
        // default. Override so an accidental dismiss doesn't resume
        // the compromised VM.
        alert.buttons.last?.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .shutdown
        case .alertSecondButtonReturn: return .saveForInvestigation
        case .alertThirdButtonReturn:  return .continueAnyway
        default:                        return .shutdown
        }
    }

    enum CompromiseAction { case shutdown, saveForInvestigation, continueAnyway }

    /// Reboot dialog: soft (graceful guest halt via `poweroff` — NOT
    /// `reboot`, which restarts the VM in place without VZ ever firing
    /// guestDidStop, leaving the relaunch path dead) or hard (host-side
    /// `vm.stop()`). Both clear the saved RAM snapshot first so the
    /// post-stop relaunch is a clean fresh boot, not a restore that
    /// would put us right back where we were.
    @MainActor
    func requestReboot(for window: SessionPane) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Reboot “%@”?", comment: ""),
            window.profile.name)
        alert.informativeText = NSLocalizedString(
            "Soft reboot gracefully halts the VM (filesystems flush, services stop) and boots a fresh one in this window. Hard reboot tears down the VM immediately and starts a fresh one.",
            comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Soft reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Hard reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            window.sandbox?.sessionDisk?.clearSavedState()
            window.rebootRequested = true
            sendCommand("soft-reboot", in: window)
        case .alertSecondButtonReturn:
            window.sandbox?.sessionDisk?.clearSavedState()
            window.rebootRequested = true
            // Host-initiated stop. VZ doesn't fire `guestDidStop` for
            // this path (that callback is reserved for guest-driven
            // halts like `sudo reboot`), so the `onStopped` →
            // `relaunchVM` chain that soft reboot rides on never
            // triggers. Drive the relaunch from the completion
            // handler instead. The `rebootRequested` flag still
            // gates: if VZ does fire `didStopWithError` for some
            // edge case, the delegate path will consume the flag
            // first and we'll no-op here (or vice versa).
            window.sandbox?.vm?.stop(completionHandler: { [weak self, weak window] error in
                if let error {
                    FileHandle.standardError.write(Data(
                        "[ac] hard reboot: stop failed: \(error)\n".utf8))
                }
                Task { @MainActor in
                    guard let self, let window, window.rebootRequested else {
                        return
                    }
                    window.rebootRequested = false
                    self.relaunchVM(in: window)
                }
            })
        default:
            return
        }
    }

    /// Wire the standard set of sandbox callbacks for `win`. Used by
    /// both the initial launch and the post-reboot relaunch — the
    /// reboot path needs identical wiring on the freshly-built
    /// sandbox, and `onStopped` keying off `rebootRequested` is the
    /// hinge that turns "VM stopped" into "rebuild VM in place"
    /// instead of "close window".
    @MainActor
    /// Wire the sandbox's guest-event callbacks. Keyed off the profile id
    /// (resolved from the sandbox's own session disk) rather than a captured
    /// window, so the callbacks keep working while the session is detached
    /// (no window). UI-affecting events look up the attached window lazily and
    /// no-op when there isn't one; state (IP, roster) is mirrored into the
    /// registry so a reattaching window can render it.
    private func wireSandboxCallbacks(_ sandbox: UbuntuSandboxVM) {
        guard let pid = sandbox.sessionDisk?.profile.id else { return }
        sandbox.onStopped = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A reboot — whether requested from the app (pane.rebootRequested)
                // or initiated inside the guest (`reboot`, which sets the session
                // flag via onGuestReboot) — rebuilds a fresh VM in place. An
                // EXPLICIT stop (stopSession sets `stopping`) always wins, so a
                // user Shutdown that lands mid-reboot still tears down. Otherwise
                // it's a real stop (guest poweroff, crash): tear the session down
                // and close any attached window.
                let explicitStop = self.runningSessions[pid]?.stopping ?? false
                if !explicitStop,
                   (self.pane(for: pid)?.rebootRequested ?? false)
                    || (self.runningSessions[pid]?.rebootRequested ?? false) {
                    self.relaunchAfterGuestReboot(pid)
                } else {
                    self.handleSessionStopped(profileID: pid)
                }
            }
        }
        sandbox.onGuestReboot = { [weak self] in
            Task { @MainActor in
                guard let self, let session = self.runningSessions[pid],
                      !session.rebootRequested else { return }   // dedupe repeats
                // Flag the reboot so the empty rosters the guest publishes on its
                // way down don't trigger the close-action shutdown
                // (SessionPane.applyTabList guards on rebootRequested). Then just
                // let it happen: VZ restarts a guest `reboot` in place, so the VM
                // comes back by itself — no host stop/relaunch needed. The dip
                // tracking in onTabList clears the flags when tmux reappears; if
                // VZ *does* stop the VM instead, onStopped relaunches.
                session.rebootRequested = true
                session.sawRebootDip = false
                self.pane(for: pid)?.rebootRequested = true
                // A stale suspend image is invalid across a guest reboot.
                session.sandbox.sessionDisk?.clearSavedState()
                // The pooled shell connections belong to the boot that's going
                // away — flush them so the first exec after the reboot doesn't
                // dequeue a dead socket ("Shell command execution failed").
                self.shellBridges[pid]?.flushPool()
                FileHandle.standardError.write(Data(
                    "[ac] guest reboot detected for '\(session.profile.name)' — riding it out\n".utf8))
            }
        }
        sandbox.onURLOpen = { [weak self, weak sandbox] url in
            Task { @MainActor in
                // If this is an OAuth login URL whose redirect_uri points at a
                // guest loopback port, stand up a forwarder so the host
                // browser's callback reaches the in-VM CLI before we open it.
                if let self, let sandbox,
                   let port = Self.loopbackCallbackPort(from: url),
                   let dev = sandbox.socketDevice,
                   let fwd = LoopbackCallbackForwarder(port: port, socketDevice: dev) {
                    self.loopbackForwarders.removeAll { !$0.isRunning }
                    self.loopbackForwarders.append(fwd)
                    FileHandle.standardError.write(Data(
                        "[ac] loopback callback forwarder up on 127.0.0.1:\(port) → guest\n".utf8))
                }
                NSWorkspace.shared.open(url)
            }
        }
        sandbox.onTabList = { [weak self] tabs in
            Task { @MainActor in
                guard let self else { return }
                // Guest-initiated reboot in flight: VZ restarts the VM in place,
                // so "reboot finished" is the roster dipping empty (tmux gone on
                // the way down / not yet up early in the second boot) and then
                // coming back. Track the dip here — this callback fires for
                // detached sessions too, unlike the pane — and clear both flags
                // when tmux reappears so normal close handling resumes.
                if let session = self.runningSessions[pid], session.rebootRequested {
                    if tabs.isEmpty {
                        session.sawRebootDip = true
                    } else if session.sawRebootDip {
                        session.rebootRequested = false
                        session.sawRebootDip = false
                        self.pane(for: pid)?.rebootRequested = false
                        FileHandle.standardError.write(Data(
                            "[ac] guest reboot of '\(session.profile.name)' completed\n".utf8))
                    }
                }
                // Mirror for detached `vm ls` / API / SSH, and drive the tab bar.
                self.runningSessions[pid]?.tabs = tabs
                self.pane(for: pid)?.applyTabList(tabs)
                // Keep the grid membership in sync even when the grid isn't the
                // active stage — closing a tab in the workspace must prune its
                // cell from the sidebar's Grid list live, not only when the grid
                // is next shown. Skip empty rosters (reboot dip / shutdown):
                // off/suspended workspaces keep their cells as placeholders.
                if !tabs.isEmpty {
                    self.unifiedWindow?.gridStore.reconcile(
                        profileID: pid,
                        tabs: tabs.map { ($0.index, $0.display?.isEmpty == false ? $0.display! : $0.label) })
                }
                // First non-empty roster = the guest booted to kitty/tmux, so the
                // disk is proven bootable. Snapshot it (once per session) as a
                // rollback point — a later bad shutdown can revert here instead of
                // a full reset. clonefile is instant; run it off the main actor.
                if !tabs.isEmpty,
                   let session = self.runningSessions[pid], !session.didCheckpoint,
                   let profile = self.profiles.first(where: { $0.id == pid }) {
                    session.didCheckpoint = true
                    let store = self.store
                    Task.detached {
                        do { _ = try store.snapshotDisk(for: profile, at: Date()) }
                        catch {
                            FileHandle.standardError.write(Data(
                                "[checkpoint] snapshot \(profile.name) failed: \(error)\n".utf8))
                        }
                    }
                }
            }
        }
        sandbox.onDockerList = { [weak self] containers in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerList(containers)
            }
        }
        sandbox.onDockerStats = { [weak self] stats in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerStats(stats)
            }
        }
        sandbox.onVMStats = { [weak self] cpu, used, total, load, diskUsed, diskTotal in
            Task { @MainActor in
                self?.pane(for: pid)?.applyVMStats(cpu: cpu, memUsedKB: used, memTotalKB: total,
                                                   load: load, diskUsedKB: diskUsed, diskTotalKB: diskTotal)
            }
        }
        sandbox.onPortsList = { [weak self] ports in
            Task { @MainActor in
                guard let self else { return }
                self.runningSessions[pid]?.listeningPorts = ports
                self.pane(for: pid)?.applyListeningPorts(ports)
            }
        }
        sandbox.onDockerImages = { [weak self] images in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerImages(images)
            }
        }
        sandbox.onDockerError = { [weak self] message in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerError(message)
            }
        }
        sandbox.onWorktreeError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                SupplyChainLog.shared.record("[worktree] \(message)")
                // NON-BLOCKING. A modal runModal() here froze the main run loop
                // — and with it the automation server that POST /sessions waits
                // on — so one failed worktree wedged the whole app (and hung the
                // E2E for 600s). Present as a sheet on the session's on-screen
                // window; headless / detached runs just get the log line above.
                guard let win = self.hostWindow(for: pid) ?? self.unifiedWindow,
                      win.isVisible else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("Worktree action failed", comment: "")
                alert.informativeText = message
                alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                alert.beginSheetModal(for: win) { _ in }
            }
        }
        sandbox.onAgentStatus = { [weak self] index, signal in
            Task { @MainActor in
                guard let self, let status = AgentStatus(signal: signal) else { return }
                self.setTabAgentStatus(pid, index: index, status)
            }
        }
        sandbox.onDockerBinfmt = { [weak self] arches in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerBinfmt(arches)
            }
        }
        sandbox.onDockerArch = { [weak self] list in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerArch(list)
            }
        }
        sandbox.onDockerRunStatus = { [weak self] s in
            Task { @MainActor in
                self?.pane(for: pid)?.applyDockerRunStatus(s)
            }
        }
        sandbox.onIPUpdate = { [weak self] ip in
            Task { @MainActor in
                guard let self else { return }
                self.runningSessions[pid]?.lastIP = ip
                self.pane(for: pid)?.model.ipAddress = ip
            }
        }
    }

    // MARK: - Session lifetime (persistent-agent model)

    /// Tear down a profile's host-side session registrations — the MITM
    /// engine maps, ssh-agent keys, SSO refresh loop, and shell bridge. Moved
    /// out of `windowWillClose` (which now only *detaches*): these must outlive
    /// a mere detach and only drop when the VM actually stops.
    @MainActor
    private func cleanupSessionRegistrations(for profile: Profile) {
        for key in loadAgentKeys(for: profile) {
            removeKeyFromHostAgent(publicKey: key.publicKey)
        }
        ssoRefreshTasks[profile.id]?.cancel()
        ssoRefreshTasks.removeValue(forKey: profile.id)
        mitmEngine?.clearSessionTrace(for: profile.id)
        mitmEngine?.unregister(profileID: profile.id)
        mitmEngine?.claudeSubscriptionStore.unregisterBogusKeys(for: profile.id)
        mitmEngine?.codexSubscriptionStore.unregisterBogusKeys(for: profile.id)
        mitmEngine?.grokSubscriptionStore.unregisterBogusKeys(for: profile.id)
        shellBridges[profile.id]?.stop()
        shellBridges.removeValue(forKey: profile.id)
        // Drop this workspace's local models from the engine's union, unloading
        // any no longer wanted by an open workspace (stops the engine if none
        // remain). The engine keeps serving the others.
        Task { await InferenceService.shared.clearWorkspace(profile.id) }
        InferenceRepairProxy.shared.clearActiveModel(profile.id)
    }

    /// The VM for `profileID` stopped (guest poweroff, crash, or the tail of an
    /// explicit stop). Idempotent: runs per-session teardown once, drops the
    /// registry entry, and closes any attached window.
    @MainActor
    func handleSessionStopped(profileID: Profile.ID) {
        guard let session = runningSessions[profileID] else { return }   // already handled
        cleanupSessionRegistrations(for: session.profile)
        unregisterSession(profileID)
        if let win = profileWindows[profileID] {
            win.sandbox = nil
            profileWindows.removeValue(forKey: profileID)
            unregisterPane(profileID, ifMatches: win.pane)
            win.orderOut(nil)
        }
        // Drop the pane regardless of host (unified-window teardown removes its
        // own view in `removePane`, wired in the unified-window phase).
        unifiedWindow?.removePane(profileID)
        unregisterPane(profileID)
        // `vm run --rm`: delete the ephemeral profile + its disk now it stopped.
        if ephemeralProfiles.remove(profileID) != nil,
           let p = profiles.first(where: { $0.id == profileID }) {
            try? store.delete(p)
            profiles = store.loadAll()
        }
        refreshSidebar()
        updateStatusMenu()
        updateActivationPolicy()
    }

    /// Explicitly stop a running session's VM (honoring `action`), then tear it
    /// down. This is the *only* path that powers a VM off — window close is a
    /// detach. Invoked by `vm kill`, the ⌘Q drain, the status-item, and the
    /// guest "all shells exited" signal.
    @MainActor
    func stopSession(_ profileID: Profile.ID, action: Profile.CloseAction) async {
        guard let session = runningSessions[profileID], !session.stopping,
              let vm = session.sandbox.vm else { return }
        let sandbox = session.sandbox
        session.stopping = true
        let name = session.profile.name
        // A suspended/off VM can't serve its ports; tear down any Cloudflare
        // exposures pointing at it (the SSH front door tunnel is unaffected).
        CloudflareTunnelSupervisor.shared.unexposeAll(prefix: "ws:\(profileID.uuidString):")
        // `.ask` and `.background` both collapse to `.suspend` — a programmatic
        // stop isn't the moment for a modal, and "background" can't survive the
        // agent exiting, so suspend keeps state and the user decides next launch.
        var resolved: Profile.CloseAction = (action == .ask || action == .background) ? .suspend : action
        // A boot that just migrated its home ran with the one-time dual-attach
        // config (virtiofs + image); the next launch is image-only and could
        // never restore that snapshot. Shut down cleanly instead of writing a
        // doomed vm.state.
        if session.homeJustMigrated && resolved == .suspend { resolved = .shutdown }
        switch resolved {
        case .suspend:
            sandbox.sessionDisk?.saveTabs(currentTabsSnapshot(for: profileID))
            // Bound the suspend. vm.pause()/saveMachineStateTo can hang against a
            // wedged or CPU-pegged guest (e.g. a runaway autorepeat loop), which
            // would strand quit in `.terminateLater` forever — the dialog is
            // answered but the app never exits. Race the suspend against a
            // deadline and force-stop if it doesn't land, exactly like the
            // .shutdown watchdog below. 20s comfortably covers a legit multi-GB
            // RAM save on SSD while still guaranteeing quit terminates.
            let saved = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask { @MainActor in
                    do { try await sandbox.suspend(); return true }
                    catch { return false }
                }
                group.addTask { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if saved {
                FileHandle.standardError.write(Data("[ac] suspended '\(name)'\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[ac] suspend '\(name)' failed or timed out — forcing stop\n".utf8))
                sandbox.sessionDisk?.clearSavedState()
                await Self.forceStop(vm)
            }
        case .shutdown:
            sandbox.sessionDisk?.clearSavedState()
            do { try vm.requestStop() }
            catch {
                await Self.forceStop(vm)
                break
            }
            let deadline = Date().addingTimeInterval(15)
            while vm.state == .running && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if vm.state == .running {
                FileHandle.standardError.write(Data(
                    "[ac] '\(name)' didn't poweroff in 15s — forcing stop\n".utf8))
                await Self.forceStop(vm)
            }
        case .ask, .background:
            break   // unreachable: both collapse to .suspend above
        }
        // A clean guest poweroff fires onStopped → handleSessionStopped, but
        // suspend and a forced vm.stop() do NOT — so finish teardown here too.
        // Idempotent: a no-op if onStopped already ran.
        handleSessionStopped(profileID: profileID)
    }

    /// Fire-and-forget `stopSession` for non-async callers (the guest
    /// "all shells exited" path, status item, CLI control plane).
    @MainActor
    func requestStopSession(_ profileID: Profile.ID, action: Profile.CloseAction) {
        Task { @MainActor in await self.stopSession(profileID, action: action) }
    }

    /// Rebuild a fresh VM after a guest-initiated reboot. Idempotent: the two
    /// stop signals that can arrive (our own `vm.stop` completion and, if VZ
    /// surfaces it, `guestDidStop`) both call this, but it consumes the reboot
    /// flag so the relaunch happens exactly once.
    @MainActor
    private func relaunchAfterGuestReboot(_ profileID: Profile.ID) {
        let paneReboot = pane(for: profileID)?.rebootRequested ?? false
        let sessionReboot = runningSessions[profileID]?.rebootRequested ?? false
        guard paneReboot || sessionReboot else { return }   // already handled
        runningSessions[profileID]?.rebootRequested = false
        if let pane = pane(for: profileID) {
            pane.rebootRequested = false
            relaunchVM(in: pane)
        } else {
            // Detached (window-less, e.g. a remote/TUI session): clean teardown +
            // fresh window-less boot.
            let profile = runningSessions[profileID]?.profile
            handleSessionStopped(profileID: profileID)
            if let profile { launch(profile, detached: true) }
        }
    }

    /// Best-effort current tab snapshot for `profileID`: the attached window's
    /// live model when attached, else the last snapshot captured on detach.
    @MainActor
    private func currentTabsSnapshot(for profileID: Profile.ID) -> SessionDisk.TabsState {
        if let pane = pane(for: profileID) { return pane.snapshotTabs() }
        return runningSessions[profileID]?.lastTabsSnapshot
            ?? SessionDisk.TabsState(tabs: [], activeIndex: 0)
    }

    /// Build a window onto an already-running session and bind a fresh
    /// VZVirtualMachineView to its live VM. Used to reattach after a detach
    /// (window closed, VM kept running) and by the control plane's attach.
    @MainActor
    func attachWindow(to session: RunningSession) {
        // Already shown somewhere → focus + select it.
        if isAttached(session.profileID) {
            revealSession(session.profileID)
            return
        }
        let profile = session.profile
        let sandbox = session.sandbox
        // Build a fresh pane onto the already-running VM and host it in the
        // shared unified window.
        let pane = SessionPane(profile: profile, acDelegate: self)
        pane.sandbox = sandbox
        // Rebuild the tab bar from the session's cached tmux window list; the
        // live roster keeps it current. tmux is already running in the VM, so
        // there's nothing to spawn or raise.
        if !session.tabs.isEmpty {
            pane.model.tabs = session.tabs.map {
                TabsModel.Tab(label: $0.label, index: $0.index, containerID: $0.containerID,
                              cwd: $0.cwd, worktreeBranch: $0.worktreeBranch,
                              parentBranch: $0.parentBranch, rootRepo: $0.rootRepo,
                              display: $0.display, repoRoot: $0.repoRoot)
            }
            pane.model.activeIndex = session.tabs.firstIndex(where: { $0.active }) ?? 0
        } else {
            pane.model.tabs = [TabsModel.Tab(label: "shell")]
            pane.model.activeIndex = 0
        }
        // Restore display state from the registry.
        pane.model.ipAddress = session.lastIP
        pane.model.fusionConfigurable = profile.fusionConfigurable
        pane.model.fusionEngaged = session.fusionEngaged
        let unified = ensureUnifiedWindow()
        unified.addPane(pane)
        NSApp.setActivationPolicy(.regular)
        unified.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStreamingState()
        refreshSidebar()
        updateStatusMenu()
    }

    /// Demote to a background (no Dock icon) agent when no session window or
    /// the picker is visible — VMs keep running. Promoted back to `.regular`
    /// at the window-show sites (`attachWindow`, the picker opener).
    @MainActor
    func updateActivationPolicy() {
        let hasSessionUI = (unifiedWindow?.isVisible == true) || !profileWindows.isEmpty
        if !hasSessionUI && mainWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Status-bar item (reachable while detached / accessory)

    /// Stand up the menu-bar item. Created once in `applicationDidFinishLaunching`.
    /// It's the only UI surface once every window is closed and the app has
    /// demoted to `.accessory`, so it must list running sessions + offer Quit.
    @MainActor
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let robot = BromureIcons.image("robot") {
                let icon = robot.copy() as! NSImage
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "shippingbox",
                                       accessibilityDescription: "Bromure Agentic Coding")
                button.image?.isTemplate = true
            }
        }
        statusItem = item
        updateStatusMenu()
    }

    /// The status menu is rebuilt every time it OPENS (menuNeedsUpdate), so
    /// what it shows — the session list and the Remote Access state — is
    /// ground truth at display time, never a stale snapshot. Launch-order
    /// bug this fixes: setupStatusItem() runs before startRemoteAccessIfNeeded()
    /// boots sshd, so a menu baked at setup time showed Remote Access off.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        MainActor.assumeIsolated { updateStatusMenu() }
    }

    /// Rebuild the status-item menu from the current `runningSessions`.
    @MainActor
    func updateStatusMenu() {
        guard let statusItem else { return }
        // Reuse one menu instance (delegate-wired) so menuNeedsUpdate keeps
        // firing on every open; a fresh NSMenu each time would need re-wiring.
        let menu: NSMenu
        if let existing = statusItem.menu {
            menu = existing
            menu.removeAllItems()
        } else {
            menu = NSMenu()
            menu.delegate = self
        }
        let sessions = runningSessions.values.sorted { $0.profile.name < $1.profile.name }
        if sessions.isEmpty {
            let none = NSMenuItem(title: NSLocalizedString("No running VMs", comment: ""),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for session in sessions {
                let attached = isAttached(session.profileID)
                let title = "\(session.profile.name)\(attached ? "" : " — detached")"
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                let reattach = NSMenuItem(
                    title: attached
                        ? NSLocalizedString("    Focus window", comment: "")
                        : NSLocalizedString("    Reattach", comment: ""),
                    action: #selector(statusReattach(_:)), keyEquivalent: "")
                reattach.target = self
                reattach.representedObject = session.profileID.uuidString
                menu.addItem(reattach)

                let stop = NSMenuItem(title: NSLocalizedString("    Shut down", comment: ""),
                                      action: #selector(statusStop(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = session.profileID.uuidString
                menu.addItem(stop)
            }
        }
        menu.addItem(.separator())

        // Remote access (embedded SSH front door) — toggle + where to reach it.
        let remoteOn = RemoteAccessServer.shared.isRunning
        let remote = NSMenuItem(title: NSLocalizedString("Remote Access", comment: ""),
                                action: #selector(statusToggleRemoteAccess(_:)), keyEquivalent: "")
        remote.target = self
        remote.state = remoteOn ? .on : .off
        menu.addItem(remote)
        if remoteOn {
            let reach = NSMenuItem(
                title: String(format: NSLocalizedString("    Bromure is reachable at %@", comment: ""),
                              remoteReachableAddress()),
                action: nil, keyEquivalent: "")
            reach.isEnabled = false
            menu.addItem(reach)
        }
        menu.addItem(.separator())

        let picker = NSMenuItem(title: NSLocalizedString("Open Bromure Agentic Coding", comment: ""),
                                action: #selector(openProfileManagerAction(_:)), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        let quit = NSMenuItem(title: NSLocalizedString("Quit", comment: ""),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @MainActor @objc private func statusReattach(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let session = runningSessions[id] else { return }
        attachWindow(to: session)
    }

    @MainActor @objc private func statusStop(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        let action = runningSessions[id]?.profile.closeAction ?? .shutdown
        Task { @MainActor in await self.stopSession(id, action: action) }
    }

    /// Toggle the embedded SSH front door from the menu-bar item.
    @MainActor @objc private func statusToggleRemoteAccess(_ sender: NSMenuItem) {
        let result = remoteAccessApply(["enabled": !RemoteAccessServer.shared.isRunning])
        if let err = result["error"] as? String {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Remote Access", comment: "")
            alert.informativeText = err
            alert.runModal()
        }
        updateStatusMenu()
    }

    /// Build a fresh sandbox in `win` after the previous one stopped.
    /// Used post-reboot to replace the dead VM in place without
    /// closing/reopening the host window. Skips drift checks and the
    /// network-healer watch — both are first-launch concerns; the
    /// disk + base image version are unchanged across a reboot.
    @MainActor
    private func relaunchVM(in win: SessionPane) {
        let profile = win.profile
        // Cancel the outgoing sandbox's outbox poller explicitly. A
        // dropped Task keeps running in Swift — without this the old
        // poller would keep racing the new one on the same shared
        // directory and removing closed-* files out from under it.
        win.sandbox?.stopPolling()
        // Retire the native terminal surfaces up front: their attach-pump
        // children are already dead (VM stopped), so leaving them mounted
        // just makes the controller thrash reattach with backoff against a
        // down VM. The container's solid backing shows through cleanly until
        // the fresh roster re-mounts a surface for the active tab.
        win.retireNativeTerminals()
        // Drop the old VM from the registry (and the window borrow) so it
        // deallocates (its deinit detaches the vmnet switch port). The fresh
        // sandbox is registered below once it's built.
        unregisterSession(profile.id)
        win.sandbox = nil
        win.model.activeIndex = 0
        win.model.ipAddress = nil
        // Reusing this pane for a fresh VM: reset boot-detection so the new VM's
        // pre-tmux empty roster isn't mistaken for "all tabs closed" (which would
        // power the freshly-relaunched VM straight back off).
        win.resetBootDetection()
        // Placeholder pill while the fresh VM boots; the agent creates tmux
        // window 0 and the roster repopulates the bar.
        win.model.tabs = [TabsModel.Tab(label: "shell")]

        Task { @MainActor in
            // Brief settle before reusing the per-profile shared dirs
            // (meta-share, outbox) while the old VZ virtiofs daemon
            // releases its handles after the previous VM stopped. The
            // black-screen wedge this used to guard against — the
            // cmd-spawn-kitty file landing in a directory the new
            // agent couldn't see — is now fixed at the source:
            // prepareMetadataShare/prepareOutboxDirectory clear their
            // contents in place instead of removing+recreating the
            // directory, so the inode the daemon holds never changes.
            // This delay is kept only as cheap defense-in-depth.
            try? await Task.sleep(for: .milliseconds(500))

            var profile = profile
            self.populateMCPBearerTokens(in: &profile)

            let sessionDisk = SessionDisk(
                profile: profile,
                store: store,
                baseDiskURL: imageManager.baseDiskURL
            )
            let salt = self.mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
            let plan = self.sessionTokenPlan(for: profile, salt: salt)
            sessionDisk.tokenPlan = plan
            if profile.homeModel == .virtiofs {
                self.seedCodexAuthFile(for: profile)
                self.seedGrokAuthFile(for: profile)
            }
            if let engine = self.mitmEngine, let scriptURL = self.bridgeScriptURL {
                sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                    caCertificatePEM: engine.ca.certificatePEM,
                    bridgeScriptURL: scriptURL,
                    awsCredsHelperURL: awsCredsHelperURL,
                    claudeTokenAgentURL: claudeTokenAgentURL,
                    codexTokenAgentURL: codexTokenAgentURL,
                    shellAgentURL: self.shellAgentURL,   // always ship (see warm-boot path)
                    loopbackRelayAgentURL: loopbackRelayAgentURL,
                    agentdURL: self.agentdURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager,
                                          sessionDisk: sessionDisk)
            do {
                try sandbox.prepare()
                // ext4 home: the reboot wiped the meta share, so restage the
                // home-seed the guest agent applies before the session starts
                // (same block as the warm-boot path; no kubeconfig here — the
                // reboot path never rebuilt it, dotfiles persist in the image).
                if profile.homeModel == .ext4, let seedDir = sessionDisk.homeSeedDirectory {
                    do {
                        try store.writeHomeSeedFiles(
                            for: profile, into: seedDir,
                            terminalDefaults: self.terminalDefaults,
                            tokenPlan: plan, kubeconfigYAML: nil)
                        let files = seedDir.appendingPathComponent("files", isDirectory: true)
                        self.seedCodexAuthFile(for: profile, homeRoot: files)
                        self.seedGrokAuthFile(for: profile, homeRoot: files)
                        try store.finalizeHomeSeed(for: profile, seedDir: seedDir)
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[ac] home-seed staging (reboot) failed: \(error)\n".utf8))
                    }
                }
                try await sandbox.start()
            } catch {
                self.showError(error, message:
                    "Couldn't restart the VM for “\(profile.name)”.")
                win.host?.paneRequestsClose(win)
                return
            }
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
                engine.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
                engine.setSupplyChainPolicy(profile.supplyChain, for: profile.id)
                engine.setPromptInjectionPolicy(profile.promptInjection, for: profile.id)
                if profile.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
                if profile.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }
                // Fusion: keep the toggle visible when configured, but reset
                // to disengaged on reboot (user re-engages on demand).
                win.model.fusionConfigurable = profile.fusionConfigurable
                win.model.fusionEngaged = false
                engine.setFusionEngaged(false, for: profile.id)
                engine.setFusionConfig(self.makeFusionConfig(for: profile), for: profile.id)
                self.applyRouting(engine, for: profile)
                self.startLocalEngineIfNeeded(for: profile)
            }
            // Shell-exec bridge — see the matching block on the warm-boot path.
            if let dev = sandbox.socketDevice {
                let bridge = ShellBridge(socketDevice: dev)
                self.shellBridges[profile.id] = bridge
            }
            self.wireSandboxCallbacks(sandbox)
            self.registerSession(sandbox, profile: profile)
            win.sandbox = sandbox
            // The guest daemon creates the tmux session itself; the roster
            // fills the bar. No host-driven spawn.
        }
    }

    private func readCurrentBaseVersion() -> String? {
        try? String(contentsOf: imageManager.versionStampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    func showError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    /// Load the profile's ssh keys from its host-only agent dir.
    /// Returns an empty array if the new-format raw key hasn't been
    /// generated yet — vocally so the user knows they need to
    /// regenerate (the old OpenSSH-format files we used to write
    /// aren't loadable through this path).
    private func loadAgentKeys(for profile: Profile) -> [AgentKey] {
        let dir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent", isDirectory: true)
        let raw = dir.appendingPathComponent("id_ed25519.raw")

        guard FileManager.default.fileExists(atPath: raw.path) else {
            if profile.sshPublicKey != nil {
                FileHandle.standardError.write(Data(
                    "[mitm] profile '\(profile.name)' has an SSH public key on file but no agent/id_ed25519.raw — regenerate via Credentials → SSH key → Regenerate\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] profile '\(profile.name)' has no SSH key configured — toggle 'Generate' in Credentials if you want one\n".utf8))
            }
            return []
        }
        guard let rawData = try? Data(contentsOf: raw), rawData.count == 64 else {
            FileHandle.standardError.write(Data(
                "[mitm] profile '\(profile.name)' agent/id_ed25519.raw is malformed (\(((try? Data(contentsOf: raw))?.count) ?? -1) bytes, expected 64) — regenerate\n".utf8))
            return []
        }
        // raw layout: 32-byte seed (private) + 32-byte public.
        let secret = rawData.prefix(32)
        let publicKey = rawData.suffix(32)
        FileHandle.standardError.write(Data(
            "[mitm] loaded 1 agent key from \(raw.path)\n".utf8))
        return [AgentKey(comment: "bromure-ac",
                         publicKey: Data(publicKey),
                         seed: Data(secret),
                         requireApproval: profile.sshKeyRequiresApproval,
                         consentCredentialID: ConsentCredentialID.bromureSSHKey())]
    }

    /// Extract the SSH wire-format public-key blob from an OpenSSH
    /// public-key line (`<keytype> <base64> [comment]`). The base64
    /// payload IS the wire-format blob the SSH client passes to
    /// SIGN_REQUEST as the key identifier, so callers can match it
    /// 1:1 against incoming sign requests.
    ///
    /// Returns nil for empty / malformed input — callers that can't
    /// resolve a blob skip the consent gate (better than refusing to
    /// sign for keys we can't identify).
    private func sshPublicKeyBlob(fromOpenSSHText text: String) -> Data? {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2,
                               omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// Copy a user-supplied SSH private key into the profile's
    /// host-only `agent/imported/` dir, optionally storing the
    /// passphrase in the macOS keychain. Reads the matching `.pub`
    /// file if present so the editor can show the public key text
    /// without re-deriving it. Returns the metadata to store on the
    /// profile.
    func importSSHKey(at sourceURL: URL,
                      passphrase: String?,
                      label: String,
                      for profile: Profile) throws -> ImportedSSHKey {
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: importedDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        // Rename on copy: original filename leaks intent ("work_id_rsa")
        // and could collide. UUID-prefix keeps things scoped + unique.
        let basename = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let dst = importedDir.appendingPathComponent(basename)
        try FileManager.default.copyItem(at: sourceURL, to: dst)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: dst.path)

        // Pull the matching .pub for display purposes if the user had
        // one alongside (typical: ~/.ssh/id_ed25519 + .pub).
        var pubText = ""
        let candidatePub = sourceURL.deletingPathExtension()
            .appendingPathExtension("pub")
        // ssh keypair convention: the file might be id_ed25519 with no
        // extension and id_ed25519.pub. Try both forms.
        let altPub = URL(fileURLWithPath: sourceURL.path + ".pub")
        for pubURL in [altPub, candidatePub] {
            if let s = try? String(contentsOf: pubURL, encoding: .utf8) {
                pubText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let pubDst = importedDir.appendingPathComponent(basename + ".pub")
                try? FileManager.default.copyItem(at: pubURL, to: pubDst)
                break
            }
        }

        let trimmed = passphrase?.trimmingCharacters(in: CharacterSet()) ?? ""

        // If we still don't have the public-key text (common for .pem
        // imports), derive it from the private key via `ssh-keygen
        // -y -f <key> -P <passphrase>`. Captures stdout, caches the
        // result on disk so future launches don't re-run ssh-keygen,
        // and unblocks the per-key consent gate (which keys requests
        // by the wire-format public-key blob).
        if pubText.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            // -y: print public-key text from a private file.
            // -P: passphrase. Empty string for unencrypted keys —
            //     ssh-keygen accepts empty -P silently.
            p.arguments = ["-y", "-f", dst.path, "-P", trimmed]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let data = try? outPipe.fileHandleForReading.readToEnd(),
               let s = String(data: data, encoding: .utf8) {
                let derived = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !derived.isEmpty {
                    pubText = derived
                    // Cache the derived pub next to the private key so
                    // future launches read it from disk (avoids the
                    // ssh-keygen shell-out and avoids needing the
                    // passphrase again post-import).
                    let pubDst = importedDir.appendingPathComponent(basename + ".pub")
                    try? derived.write(to: pubDst, atomically: true, encoding: .utf8)
                }
            }
        }
        let hasPass = !trimmed.isEmpty
        if hasPass {
            try PassphraseKeychain.set(passphrase: trimmed,
                                       profileID: profile.id,
                                       filename: basename)
        }

        return ImportedSSHKey(
            label: label.isEmpty ? sourceURL.lastPathComponent : label,
            filename: basename,
            publicKeyText: pubText,
            hasPassphrase: hasPass)
    }

    /// Remove an imported key: file + (optional) keychain entry. The
    /// editor calls this when the user clicks the row's minus button.
    func removeImportedSSHKey(_ key: ImportedSSHKey, for profile: Profile) {
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        try? FileManager.default.removeItem(
            at: importedDir.appendingPathComponent(key.filename))
        try? FileManager.default.removeItem(
            at: importedDir.appendingPathComponent(key.filename + ".pub"))
        if key.hasPassphrase {
            PassphraseKeychain.delete(profileID: profile.id, filename: key.filename)
        }
    }

    /// Walk the profile's imported keys and ssh-add each one into the
    /// private bromure agent. Called from `launch()` after the auto-
    /// generated key is loaded so multiple keys end up live in the
    /// agent simultaneously.
    private func loadImportedSSHKeys(for profile: Profile) {
        guard let agentSocket = mitmEngine?.privateAgent.socketPath,
              !profile.importedSSHKeys.isEmpty else { return }
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        for key in profile.importedSSHKeys {
            let path = importedDir.appendingPathComponent(key.filename).path
            guard FileManager.default.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data(
                    "[mitm] imported key '\(key.label)' missing on disk (\(path))\n".utf8))
                continue
            }
            sshAddImportedKey(path: path,
                              label: key.label,
                              passphrase: key.hasPassphrase
                                  ? PassphraseKeychain.get(profileID: profile.id, filename: key.filename)
                                  : nil,
                              agentSocket: agentSocket)
        }
    }

    /// Run `ssh-add <path>` against our private agent, feeding the
    /// passphrase via the SSH_ASKPASS env-var protocol when one is
    /// known. The askpass script lives in /tmp for the duration of
    /// the call and is unlinked immediately after. SSH_ASKPASS_REQUIRE=force
    /// makes ssh-add use the script even though we're not running
    /// under X11 / a TTY.
    private func sshAddImportedKey(path: String,
                                   label: String,
                                   passphrase: String?,
                                   agentSocket: String) {
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = agentSocket

        var askpassURL: URL?
        if let pass = passphrase, !pass.isEmpty {
            // Script just echoes the passphrase. Single-quote the value
            // safely; ssh-add doesn't do shell expansion on the result.
            let escaped = pass.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bromure-ac-askpass-\(UUID().uuidString).sh")
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path)
            env["SSH_ASKPASS"] = url.path
            // Apple's ssh-add only consults SSH_ASKPASS when DISPLAY is
            // also set, OR when SSH_ASKPASS_REQUIRE=force. Belt-and-
            // braces both.
            env["DISPLAY"] = ":0"
            env["SSH_ASKPASS_REQUIRE"] = "force"
            askpassURL = url
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = [path]
        p.environment = env
        // ssh-add reading from /dev/null prevents it from blocking on
        // tty even when SSH_ASKPASS is missing or fails.
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        p.standardOutput = Pipe()
        let stderr = Pipe()
        p.standardError = stderr
        defer {
            if let u = askpassURL { try? FileManager.default.removeItem(at: u) }
        }
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data(
                    "[mitm] ssh-add (imported '\(label)') failed (\(p.terminationStatus)): \(msg)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] added imported key '\(label)' from \(path)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[mitm] ssh-add (imported '\(label)') launch failed: \(error)\n".utf8))
        }
    }

    /// Add the per-profile key to bromure's private ssh-agent so the
    /// in-VM ssh client can sign with it without the user having to
    /// `ssh-add` anything by hand. Idempotent — re-adding an already-
    /// loaded key is harmless. Removed in `windowWillClose`.
    ///
    /// The user's macOS launchd ssh-agent is intentionally NOT a
    /// target — exposing it to the VM was the source of an earlier
    /// security gap; see `SSHAgentServer` for the full rationale.
    private func addKeyToHostAgent(seed: Data, publicKey: Data, comment: String) {
        // Target our private bromure ssh-agent specifically: it gives
        // us predictable lifecycle (key gone when bromure-ac quits)
        // and keeps the in-VM agent's reachable key set fully under
        // bromure's control.
        guard let sock = mitmEngine?.privateAgent.socketPath else {
            FileHandle.standardError.write(Data(
                "[mitm] skipping ssh-add — private agent not running\n".utf8))
            return
        }
        let pem = OpenSSHKeyFormat.ed25519PEM(
            seed: seed, publicKey: publicKey, comment: comment)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = ["-"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = sock
        // Belt-and-braces: macOS ssh-add uses `--apple-use-keychain`
        // when adding to the system agent — but not setting that means
        // in-memory only, which is exactly what we want for ephemeral
        // session loads.
        p.environment = env
        let stdin = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = Pipe()
        p.standardError = stderr
        do {
            try p.run()
            try stdin.fileHandleForWriting.write(contentsOf: pem)
            try stdin.fileHandleForWriting.close()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data(
                    "[mitm] ssh-add failed (\(p.terminationStatus)): \(msg)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] added per-profile key to host ssh-agent (\(comment))\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[mitm] ssh-add launch failed: \(error)\n".utf8))
        }
    }

    /// Remove a key from the host ssh-agent by sending the agent
    /// protocol's REMOVE_IDENTITY message directly — sidesteps
    /// `ssh-add -d` needing a file path. Best-effort.
    private func removeKeyFromHostAgent(publicKey: Data) {
        guard let host = HostAgentClient._bromurePrivate else { return }
        let blob = OpenSSHKeyFormat.ed25519PublicBlob(publicKey: publicKey)
        // SSH_AGENTC_REMOVE_IDENTITY = 18; payload = ssh-string(blob).
        var msg = Data([18])
        var len = UInt32(blob.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(blob)
        _ = host.request(msg)
    }

    /// Mint a fresh Curve25519 ed25519 keypair into `dir` (the profile's
    /// host-only agent directory). The raw seed + public bytes are
    /// written to `id_ed25519.raw` so the in-process ssh-agent can load
    /// it; an OpenSSH-format public key is written to `id_ed25519.pub`
    /// for display + paste-into-GitHub. **No private key file** is
    /// produced — there's literally no plaintext form to leak.
    private func makeSSHKey(in dir: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation             // 32 bytes
        let pub  = key.publicKey.rawRepresentation   // 32 bytes

        // raw layout: 32 seed + 32 public = 64 bytes. Single file so
        // host-side load is one read; agent-side, the seed reconstructs
        // the full PrivateKey via Curve25519.Signing.PrivateKey(rawRepresentation:).
        var raw = Data()
        raw.append(seed)
        raw.append(pub)
        let rawURL = dir.appendingPathComponent("id_ed25519.raw")
        try raw.write(to: rawURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: rawURL.path)

        // OpenSSH public key: ssh-ed25519 <base64-blob> <comment>
        // Blob: ssh-string("ssh-ed25519") || ssh-string(public-key)
        let label = "ssh-ed25519"
        var blob = Data()
        blob.append(uint32be(UInt32(label.utf8.count)))
        blob.append(Data(label.utf8))
        blob.append(uint32be(UInt32(pub.count)))
        blob.append(pub)
        let pubText = "ssh-ed25519 \(blob.base64EncodedString()) bromure-ac"
        let pubURL = dir.appendingPathComponent("id_ed25519.pub")
        try pubText.write(to: pubURL, atomically: true, encoding: .utf8)

        // Belt-and-braces: nuke any prior OpenSSH-private-key in the
        // profile's VM-visible home dir. The previous codepath wrote
        // one there; under the new model nothing private should ever
        // sit in /home/ubuntu/.ssh.
        let homeSSH = store.homeDirectory(for: profileFromAgentDir(dir))
            .appendingPathComponent(".ssh", isDirectory: true)
        let stalePriv = homeSSH.appendingPathComponent("id_ed25519")
        try? fm.removeItem(at: stalePriv)
        // Keep id_ed25519.pub in the VM home for the user's reference.
        if fm.fileExists(atPath: homeSSH.path) {
            try? pubText.write(
                to: homeSSH.appendingPathComponent("id_ed25519.pub"),
                atomically: true, encoding: .utf8)
        }

        return pubText
    }

    /// Reverse-derive the profile from the agent dir URL — the agent
    /// dir is `…/profiles/<UUID>/agent`, two levels above. Used only
    /// for the housekeeping step in makeSSHKey.
    private func profileFromAgentDir(_ url: URL) -> Profile {
        let id = url.deletingLastPathComponent().lastPathComponent
        guard let uuid = UUID(uuidString: id),
              let p = profiles.first(where: { $0.id == uuid }) else {
            // Fallback: return a placeholder profile; the cleanup
            // step is best-effort anyway.
            return Profile(name: "", tool: .claude, authMode: .token)
        }
        return p
    }

    /// Build a session token plan, enabling Claude subscription mode when a
    /// shared subscription credential is registered, and register the minted
    /// bogus `ANTHROPIC_API_KEY` so the proxy recognizes it. Use this instead
    /// of calling `profile.makeTokenPlan` directly at session-launch sites.
    private func sessionTokenPlan(for profile: Profile, salt: Data) -> SessionTokenPlan {
        let available = mitmEngine?.claudeSubscriptionStore.hasCredential(for: profile.id) ?? false
        let plan = profile.makeTokenPlan(salt: salt, claudeSubscriptionAvailable: available)
        if let bogus = plan.claudeSubscriptionBogusKey {
            mitmEngine?.claudeSubscriptionStore.registerBogusKey(bogus, for: profile.id)
        }
        return plan
    }

    /// Codex subscription mode: write a bogus `~/.codex/auth.json` into the
    /// profile's (host-side, pre-boot) home dir so the guest runs Codex without
    /// logging in. The bogus access/id JWTs carry a far-future `exp` so the
    /// guest never refreshes; the host owns the real token + refresh and the
    /// proxy swaps the bogus Bearer for the live one on chatgpt.com/openai.com.
    /// No-op unless this profile is Codex+subscription with a registered cred.
    ///
    /// `homeRoot` — where "~" lives for this write: nil = the profile's
    /// host-side virtiofs home (legacy model); ext4-model launches pass the
    /// home-seed `files/` staging dir instead (the guest agent copies it in).
    func seedCodexAuthFile(for profile: Profile, homeRoot: URL? = nil) {
        guard let engine = mitmEngine,
              profile.allToolSpecs.contains(where: { $0.tool == .codex && $0.authMode == .subscription }),
              let real = engine.codexSubscriptionStore.record(for: profile.id) else { return }
        let saltA = Data("codex-bogus-access:\(profile.id)".utf8)
        let saltR = Data("codex-bogus-refresh:\(profile.id)".utf8)
        let saltI = Data("codex-bogus-id:\(profile.id)".utf8)
        guard let bogusAccess = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.accessToken, salt: saltA),
              let bogusID = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.idToken, salt: saltI) else {
            FileHandle.standardError.write(Data(
                "[codex-sub] seed skipped — stored tokens aren't JWT-shaped\n".utf8))
            return
        }
        let bogusRefresh = SubscriptionFakeMint.mintCodexRefreshFake(real: real.refreshToken, salt: saltR)
        engine.codexSubscriptionStore.registerBogusKey(bogusAccess, for: profile.id)

        var tokens: [String: Any] = [
            "id_token": bogusID, "access_token": bogusAccess, "refresh_token": bogusRefresh,
        ]
        if let accountID = Self.codexAccountID(fromIDToken: real.idToken) {
            tokens["account_id"] = accountID
        }
        let doc: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        let dir = (homeRoot ?? store.homeDirectory(for: profile))
            .appendingPathComponent(".codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    /// Grok subscription mode: write a bogus `~/.grok/auth.json` into the
    /// profile's (host-side, pre-boot) home dir so the guest runs Grok without
    /// logging in. The bogus token carries a far-future `expires_at` so the
    /// guest never refreshes; the host owns refresh and the proxy swaps the
    /// bogus Bearer for the live one on cli-chat-proxy.grok.com.
    /// `homeRoot`: see seedCodexAuthFile.
    func seedGrokAuthFile(for profile: Profile, homeRoot: URL? = nil) {
        guard let engine = mitmEngine,
              profile.allToolSpecs.contains(where: { $0.tool == .grok && $0.authMode == .subscription }),
              let real = engine.grokSubscriptionStore.record(for: profile.id) else { return }
        let saltA = Data("grok-bogus-access:\(profile.id)".utf8)
        let saltR = Data("grok-bogus-refresh:\(profile.id)".utf8)
        // Grok's access token is a JWT — mint a JWT-shaped bogus (real claims,
        // far-future exp, fake signature) so grok can decode it locally;
        // an opaque placeholder makes grok treat the session as logged out.
        let bogusAccess = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.accessToken, salt: saltA)
            ?? SessionTokenPlan.deriveFake(
                prefix: "grok-brm-", real: real.accessToken, salt: saltA,
                targetLength: max(40, real.accessToken.count))
        let bogusRefresh = SessionTokenPlan.deriveFake(
            prefix: "grokrt-brm-", real: real.refreshToken, salt: saltR,
            targetLength: max(40, real.refreshToken.count))
        engine.grokSubscriptionStore.registerBogusKey(bogusAccess, for: profile.id)

        // Rebuild grok's scope entry from the captured template (which carries
        // the account-specific fields grok's strict serde requires —
        // auth_mode, team_name, subscription_tier, …) and inject bogus secrets.
        // `expires_at` must be an RFC 3339 STRING (serde rejects a bare epoch
        // integer, making the file unreadable). Push it ~10y out.
        let farFuture = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(10 * 365 * 24 * 3600))
        var entry: [String: Any] = (real.templateJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }) ?? [:]
        entry["key"] = bogusAccess
        entry["refresh_token"] = bogusRefresh
        entry["expires_at"] = farFuture
        let doc: [String: Any] = [real.scopeKey: entry]
        let dir = (homeRoot ?? store.homeDirectory(for: profile))
            .appendingPathComponent(".grok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    /// Pull `chatgpt_account_id` out of a Codex id-token JWT (best effort).
    static func codexAccountID(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let acct = auth["chatgpt_account_id"] as? String { return acct }
        return obj["chatgpt_account_id"] as? String
    }

    private func populateMCPBearerTokens(in profile: inout Profile) {
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  var oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            if let exp = oauth.expiresAt, exp.timeIntervalSinceNow < 60,
               oauth.refreshToken != nil {
                let sem = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        let refreshed = try await MCPOAuthBroker.refresh(state: oauth)
                        oauth = refreshed
                    } catch { /* keep stale token */ }
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 10)
                profile.mcpServers[i].oauthState = oauth
            }
            profile.mcpServers[i].bearerToken = oauth.accessToken
        }
    }
}

/// Big-endian uint32 → Data. Wire-format helper used in the OpenSSH
/// public-key blob.
private func uint32be(_ v: UInt32) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 4)
}

// MARK: - reset

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete the base image so the next `init` starts from scratch."
    )

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() throws {
        let imageManager = try makeImageManager()
        if !yes {
            print("This will delete \(imageManager.baseDiskURL.path). Continue? [y/N] ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Aborted.")
                return
            }
        }
        let fm = FileManager.default
        for url in [imageManager.baseDiskURL, imageManager.efiVarsURL,
                    imageManager.versionStampURL, imageManager.imageStateURL] {
            try? fm.removeItem(at: url)
        }
        print("Base image cleared.")
    }
}

// MARK: - shared

private func makeImageManager(storageDir: URL? = nil) throws -> UbuntuImageManager {
    let dir = try locateSetupDir()
    return UbuntuImageManager(storageDir: storageDir, setupDir: dir)
}

/// Locate the vm-setup directory (containing setup.sh) shipped in the SPM
/// resource bundle. `acResourceBundle` handles both the .app layout
/// (Contents/Resources/) and the `swift run` layout.
private func locateSetupDir() throws -> URL {
    if let url = acResourceBundle.url(forResource: "vm-setup", withExtension: nil) {
        return url
    }
    throw ValidationError("vm-setup directory not found in resource bundle")
}

// ISO-8601 JSON coders for the headless profile create/edit round-trip.
// File-private on purpose: several files keep their own copy (Profile.swift,
// TraceStore.swift) rather than sharing one internal symbol — matching that
// convention avoids cross-file redeclaration clashes.
private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
