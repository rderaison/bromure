#if os(macOS)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File browser
//
// A quick, Finder-like panel for shuttling files in and out of the VM.
//
// The Home location browses the guest's real /home/ubuntu over the vsock
// file service (bromure-agentd's {"file": …} ops on the shell channel) —
// NOT a host directory. That's required for ext4-model workspaces (the
// home lives inside home.img, invisible to macOS) and deliberately used
// for legacy virtiofs workspaces too: one code path, and the panel shows
// exactly what the guest sees. Shared-folder locations are real host
// directories and keep the direct FileManager path (drag out = the
// actual file, Reveal in Finder works).
//
// Drag a file out → it's downloaded from the guest on demand and handed
// to Finder; drop a file in → it's uploaded into the current directory.

/// One navigable root in the sidebar.
struct FileBrowserLocation: Identifiable {
    enum Backing {
        /// Browse `guestPath` inside the VM over the vsock file service.
        case guest
        /// Browse a host directory directly (the profile's shared folders).
        case host(URL)
    }
    let id = UUID()
    let name: String
    let backing: Backing
    /// Where this root lives inside the VM — the breadcrumb speaks guest
    /// paths ("/home/ubuntu/clips") for both backings.
    let guestPath: String
    let symbol: String

    var isGuest: Bool {
        if case .guest = backing { return true }
        return false
    }
}

/// One row in the listing. `path` is absolute within its backing domain
/// (guest path or host path); `hostURL` is set only for host-backed rows.
struct FileEntry: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    let hostURL: URL?
    var id: String { path }
}

/// Runs one {"file": …} op in the profile's guest. Throws when the VM
/// isn't running / the op failed.
typealias GuestFileOpProvider =
    @MainActor (_ op: [String: Any]) async throws -> [String: Any]

@MainActor
@Observable
final class FileBrowserModel {
    let locations: [FileBrowserLocation]
    private(set) var location: FileBrowserLocation
    /// Where we currently are, always at or below the location's root.
    private(set) var currentPath: String
    private(set) var entries: [FileEntry] = []
    /// Non-nil when the guest listing failed (VM off, agent updating…).
    private(set) var errorText: String?
    /// Most recent locally-materialized file (a download target, or a host
    /// file the user opened). macOS opens it outright; the iOS screen observes
    /// this to present QuickLook / share / save-to-Files.
    var lastDownloaded: URL?
    /// True while a download/upload is in flight — drives the progress pill.
    private(set) var transferText: String?

    private let guestOp: GuestFileOpProvider?
    /// Where guest files land when opened/dragged out. Per-profile so two
    /// browsers can't collide; cleaned by the OS (it's under /tmp).
    private let downloadRoot: URL

    /// Transfer chunk: 6 MB raw ≈ 8 MB base64 — inside the guest's 10 MB
    /// request cap and the host's 50 MB response cap with room to spare.
    private static let chunkBytes = 6 * 1024 * 1024

    /// Guards overlapping poll reloads (the 1.5s timer vs a slow guest).
    private var reloadInFlight = false
    /// Newest-wins: navigation bumps this so a stale listing can't land.
    private var generation = 0

    init(locations: [FileBrowserLocation],
         cacheKey: String,
         guestOp: GuestFileOpProvider?) {
        self.locations = locations
        self.guestOp = guestOp
        self.downloadRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-files", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
        let root = locations.first!
        self.location = root
        self.currentPath = Self.rootPath(of: root)
        Task { await reload() }
    }

    private static func rootPath(of loc: FileBrowserLocation) -> String {
        switch loc.backing {
        case .guest: return loc.guestPath
        case .host(let url): return url.standardizedFileURL.path
        }
    }

    /// Guest-facing path for the current directory (breadcrumb).
    var guestBreadcrumb: String {
        let root = Self.rootPath(of: location)
        guard currentPath.hasPrefix(root) else { return location.guestPath }
        return location.guestPath + String(currentPath.dropFirst(root.count))
    }

    var canGoUp: Bool { currentPath != Self.rootPath(of: location) }

    /// Host locations support Reveal in Finder / Move to Trash; guest
    /// locations get plain Delete and no reveal.
    var isGuestLocation: Bool { location.isGuest }

    func switchTo(_ loc: FileBrowserLocation) {
        location = loc
        currentPath = Self.rootPath(of: loc)
        entries = []
        errorText = nil
        generation += 1
        Task { await reload() }
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            currentPath = entry.path
            entries = []
            generation += 1
            Task { await reload() }
        } else if let url = entry.hostURL {
            // Real file on disk — open with its default app (macOS); on iOS
            // the hosting screen surfaces it via QuickLook / share.
#if os(macOS)
            NSWorkspace.shared.open(url)
#else
            lastDownloaded = url
#endif
        } else {
            // Guest file: pull it down, then open the local copy.
            Task { @MainActor in
                do {
                    let local = try await download(entry)
                    lastDownloaded = local
#if os(macOS)
                    NSWorkspace.shared.open(local)
#endif
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    func goUp() {
        guard canGoUp else { return }
        currentPath = (currentPath as NSString).deletingLastPathComponent
        generation += 1
        Task { await reload() }
    }

    func reveal(_ entry: FileEntry?) {
#if os(macOS)
        // Host-only affordance. nil = the current directory.
        if let entry {
            guard let url = entry.hostURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if case .host = location.backing {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: currentPath)])
        }
#endif
    }

    /// Host rows: Move to Trash. Guest rows: delete inside the VM.
    func remove(_ entry: FileEntry) {
        if let url = entry.hostURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            Task { await reload() }
            return
        }
        guard let guestOp else { return }
        Task { @MainActor in
            do {
                _ = try await guestOp(["op": "remove", "path": entry.path])
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }

    func newFolder() {
        let base = NSLocalizedString("New Folder", comment: "")
        var name = base
        var n = 2
        let existing = Set(entries.map(\.name))
        while existing.contains(name) {
            name = "\(base) \(n)"; n += 1
        }
        let target = (currentPath as NSString).appendingPathComponent(name)
        if case .host = location.backing {
            try? FileManager.default.createDirectory(
                atPath: target, withIntermediateDirectories: false)
            Task { await reload() }
            return
        }
        guard let guestOp else { return }
        Task { @MainActor in
            do { _ = try await guestOp(["op": "mkdir", "path": target]) }
            catch { errorText = error.localizedDescription }
            await reload()
        }
    }

    // MARK: Transfers

    /// Copy files dropped from Finder into the current directory.
    func receive(_ urls: [URL]) {
        if case .host = location.backing {
            let fm = FileManager.default
            for src in urls {
                var dst = URL(fileURLWithPath: currentPath)
                    .appendingPathComponent(src.lastPathComponent)
                // Don't clobber: append " copy", " copy 2", … like Finder.
                if fm.fileExists(atPath: dst.path) {
                    dst = Self.uniqued(dst)
                }
                try? fm.copyItem(at: src, to: dst)
            }
            Task { await reload() }
            return
        }
        Task { @MainActor in
            for src in urls {
                do { try await upload(src) }
                catch { errorText = error.localizedDescription }
            }
            transferText = nil
            await reload()
        }
    }

    private static func uniqued(_ dst: URL) -> URL {
        let fm = FileManager.default
        let ext = dst.pathExtension
        let stem = dst.deletingPathExtension().lastPathComponent
        let dir = dst.deletingLastPathComponent()
        var n = 1
        var candidate = dst
        repeat {
            let suffix = n == 1 ? " copy" : " copy \(n)"
            let leaf = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
            candidate = dir.appendingPathComponent(leaf)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Upload one local file into the current guest directory, chunked.
    private func upload(_ src: URL) async throws {
        guard let guestOp else { return }
        // Directories: create and recurse — a dropped folder should arrive
        // whole, like the host-path copyItem did.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        let existing = Set(entries.map(\.name))
        var leaf = src.lastPathComponent
        if existing.contains(leaf) {
            leaf = Self.uniqued(URL(fileURLWithPath: currentPath)
                .appendingPathComponent(leaf)).lastPathComponent
        }
        let dstBase = (currentPath as NSString).appendingPathComponent(leaf)
        try await uploadItem(at: src, to: dstBase, isDirectory: isDir.boolValue)
    }

    private func uploadItem(at src: URL, to guestPath: String,
                            isDirectory: Bool) async throws {
        guard let guestOp else { return }
        if isDirectory {
            _ = try await guestOp(["op": "mkdir", "path": guestPath])
            let children = (try? FileManager.default.contentsOfDirectory(
                at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                let childIsDir = (try? child.resourceValues(
                    forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                try await uploadItem(
                    at: child,
                    to: (guestPath as NSString).appendingPathComponent(child.lastPathComponent),
                    isDirectory: childIsDir)
            }
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: src) else { return }
        defer { try? handle.close() }
        var first = true
        var sent: Int64 = 0
        while true {
            let data = handle.readData(ofLength: Self.chunkBytes)
            if data.isEmpty && !first { break }
            _ = try await guestOp([
                "op": "write",
                "path": guestPath,
                "data": data.base64EncodedString(),
                "append": !first,
            ])
            sent += Int64(data.count)
            transferText = String(
                format: NSLocalizedString("Copying %@ in… %@", comment: ""),
                src.lastPathComponent,
                ByteCountFormatter.string(fromByteCount: sent, countStyle: .file))
            first = false
            if data.count < Self.chunkBytes { break }
        }
    }

    /// Pull a guest file into the local cache; returns the local URL.
    func download(_ entry: FileEntry) async throws -> URL {
        guard let guestOp else { throw CocoaError(.fileNoSuchFile) }
        // Mirror the guest directory layout under the cache so two files
        // with the same basename in different dirs don't collide.
        let rel = String(entry.path.dropFirst(1))   // strip leading /
        let local = downloadRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: local.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            let resp = try await guestOp([
                "op": "read", "path": entry.path,
                "offset": offset, "length": Self.chunkBytes,
            ])
            guard let b64 = resp["data"] as? String,
                  let data = Data(base64Encoded: b64) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            handle.write(data)
            offset += Int64(data.count)
            transferText = String(
                format: NSLocalizedString("Copying %@ out… %@", comment: ""),
                entry.name,
                ByteCountFormatter.string(fromByteCount: offset, countStyle: .file))
            let eof = (resp["eof"] as? Bool)
                ?? (resp["eof"] as? Int).map { $0 != 0 } ?? data.isEmpty
            if eof || data.isEmpty { break }
        }
        transferText = nil
        return local
    }

    // MARK: Listing

    /// Re-read the current directory. Safe on a timer: overlapping guest
    /// reloads are coalesced, and stale results are dropped.
    func reload() async {
        switch location.backing {
        case .host:
            reloadHost()
        case .guest:
            guard !reloadInFlight else { return }
            reloadInFlight = true
            defer { reloadInFlight = false }
            let gen = generation
            let path = currentPath
            guard let guestOp else {
                errorText = NSLocalizedString("Guest file access isn't available.", comment: "")
                return
            }
            do {
                let resp = try await guestOp(["op": "list", "path": path])
                guard gen == generation, path == currentPath else { return }
                guard let raw = resp["entries"] as? [[String: Any]] else {
                    // An old in-VM agent that predates the file service ran
                    // this as an empty shell command. It hot-upgrades within
                    // seconds of boot — tell the user to retry.
                    errorText = NSLocalizedString(
                        "The in-VM agent is updating — try again in a few seconds.",
                        comment: "")
                    return
                }
                errorText = nil
                entries = Self.sorted(raw.compactMap { dict -> FileEntry? in
                    guard let name = dict["name"] as? String else { return nil }
                    // Match the host branch's .skipsHiddenFiles.
                    guard !name.hasPrefix(".") else { return nil }
                    return FileEntry(
                        path: (path as NSString).appendingPathComponent(name),
                        name: name,
                        isDirectory: dict["dir"] as? Bool ?? false,
                        size: Int64(dict["size"] as? Int ?? 0),
                        modified: Date(timeIntervalSince1970:
                            TimeInterval(dict["mtime"] as? Int ?? 0)),
                        hostURL: nil)
                })
            } catch {
                guard gen == generation else { return }
                entries = []
                errorText = error.localizedDescription
            }
        }
    }

    private func reloadHost() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: currentPath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .isHiddenKey]
        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        errorText = nil
        entries = Self.sorted(contents.compactMap { url in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(
                path: url.standardizedFileURL.path,
                name: url.lastPathComponent,
                isDirectory: vals?.isDirectory ?? false,
                size: Int64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate ?? .distantPast,
                hostURL: url)
        })
    }

    /// Folders first, then files; each group alphabetical, case-insensitive.
    private static func sorted(_ list: [FileEntry]) -> [FileEntry] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Drag-out provider. Host rows hand Finder the real file; guest rows
    /// register a lazy file representation that downloads on drop.
    nonisolated static func dragProvider(for entry: FileEntry,
                                         model: FileBrowserModel) -> NSItemProvider {
        if let url = entry.hostURL {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        let provider = NSItemProvider()
        let ext = (entry.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        // The receiver names the dropped file suggestedName + the registered
        // type's preferred extension, so hand it an extension-less base —
        // "index.html" would otherwise land as "index.html.html".
        provider.suggestedName = type.preferredFilenameExtension != nil
            ? (entry.name as NSString).deletingPathExtension
            : entry.name
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [], visibility: .all
        ) { completion in
            Task { @MainActor in
                do {
                    let local = try await model.download(entry)
                    completion(local, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

// MARK: - View

struct FileBrowserView: View {
    @State var model: FileBrowserModel
    @State private var selection: String?
    @State private var dropTargeted = false
    /// Compact = iPhone portrait → the locations sidebar becomes a chip row and
    /// the fixed min-width is dropped. `.regular` on macOS (layout unchanged).
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    private let reloadTimer = Timer.publish(every: 1.5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        content
        // Drop target covers the whole panel so the user can drop a file
        // anywhere — it lands in whatever directory is on screen.
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(reloadTimer) { _ in Task { await model.reload() } }
    }

    @ViewBuilder private var content: some View {
        if compact {
            // Phone: locations as a horizontal chip row above the listing, no
            // fixed min-width (which would push the content off-screen).
            VStack(spacing: 0) {
                if model.locations.count > 1 {
                    compactLocations
                    Divider()
                }
                pathBar
                Divider()
                listing
            }
        } else {
            HStack(spacing: 0) {
                if model.locations.count > 1 {
                    sidebar
                    Divider()
                }
                VStack(spacing: 0) {
                    pathBar
                    Divider()
                    listing
                }
            }
            .frame(minWidth: 560, minHeight: 360)
        }
    }

    // MARK: Locations (phone: horizontal chips)

    private var compactLocations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.locations) { loc in
                    let selected = loc.id == model.location.id
                    Button {
                        selection = nil
                        model.switchTo(loc)
                    } label: {
                        Label(loc.name, systemImage: loc.symbol)
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(selected
                                ? Color.accentColor.opacity(0.2)
                                : Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(NSLocalizedString("Locations", comment: ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(model.locations) { loc in
                Button {
                    selection = nil
                    model.switchTo(loc)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: loc.symbol)
                            .frame(width: 16)
                            .foregroundStyle(.tint)
                        Text(loc.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(loc.id == model.location.id
                                ? Color.gray.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .help(loc.guestPath)
            }
            Spacer()
        }
        .frame(width: 180)
        .background(Color.platformWindowBackground.opacity(0.5))
    }

    // MARK: Path / toolbar row

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button(action: model.goUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoUp)
            .help(NSLocalizedString("Enclosing folder", comment: ""))

            Image(systemName: model.isGuestLocation ? "desktopcomputer" : "externaldrive")
                .foregroundStyle(.secondary)
            Text(model.guestBreadcrumb)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(NSLocalizedString("Path inside the VM", comment: ""))

            Spacer()

            if let transfer = model.transferText {
                Text(transfer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: model.newFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("New folder", comment: ""))

            if !model.isGuestLocation {
                Button { model.reveal(nil) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Reveal this folder in Finder", comment: ""))
            }

            Button { Task { await model.reload() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Refresh", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Listing

    private var listing: some View {
        ScrollView {
            if let error = model.errorText {
                VStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(NSLocalizedString("The workspace must be running to browse its files.",
                                           comment: ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 24)
            } else if model.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(NSLocalizedString("Empty folder", comment: ""))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("Drag files here to copy them into the VM",
                                           comment: ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        FileRow(entry: entry, selected: selection == entry.id)
                            .onTapGesture(count: 2) {
                                selection = entry.id
                                model.open(entry)
                            }
                            .onTapGesture { selection = entry.id }
                            // Drag a file out → Finder/desktop copies it
                            // (guest files download lazily on drop).
                            .onDrag {
                                FileBrowserModel.dragProvider(for: entry, model: model)
                            }
                            .contextMenu {
                                Button(NSLocalizedString("Open", comment: "")) {
                                    model.open(entry)
                                }
                                if entry.hostURL != nil {
                                    Button(NSLocalizedString("Reveal in Finder",
                                                              comment: "")) {
                                        model.reveal(entry)
                                    }
                                }
                                Divider()
                                Button(entry.hostURL != nil
                                       ? NSLocalizedString("Move to Trash", comment: "")
                                       : NSLocalizedString("Delete", comment: ""),
                                       role: .destructive) {
                                    if selection == entry.id { selection = nil }
                                    model.remove(entry)
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: Drop handling

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.receive([url]) }
            }
        }
    }
}

/// One file/folder row: native macOS icon (extension-based for guest
/// files, so a .png / .mp4 / .c each get their own look), name, size,
/// modified date.
private struct FileRow: View {
    let entry: FileEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
#if os(macOS)
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
#else
            Image(systemName: iosSymbolName)
                .font(.system(size: 15))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
#endif
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !entry.isDirectory {
                Text(sizeText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            Text(dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
    }

#if os(macOS)
    private var icon: NSImage {
        let img: NSImage
        if let url = entry.hostURL {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else if entry.isDirectory {
            img = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (entry.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            img = NSWorkspace.shared.icon(for: type)
        }
        img.size = NSSize(width: 24, height: 24)
        return img
    }
#else
    private var iosSymbolName: String {
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "xz", "bz2", "7z": return "doc.zipper"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "mp3", "wav", "flac", "m4a": return "waveform"
        case "swift", "py", "js", "ts", "c", "h", "cpp", "rs", "go", "rb", "sh",
             "json", "yaml", "yml", "toml", "html", "css", "md":
            return "doc.plaintext"
        default: return "doc"
        }
    }
#endif

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }

    private var dateText: String {
        guard entry.modified > .distantPast else { return "" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: entry.modified)
    }
}
