import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File browser
//
// A quick, Finder-like panel for shuttling files in and out of the VM.
//
// The whole thing works on the host filesystem — no vsock, no guest
// agent. AgentCoding mounts the guest's `/home/ubuntu` (and any shared
// folders) straight through virtiofs from host directories, so whatever
// the in-VM agent writes under `~` appears immediately under the
// profile's host home dir, and anything we drop in here shows up inside
// the VM just as fast. Drag a file out → Finder copies it to the Mac;
// drop a file in → it lands in the current guest directory.

/// One navigable root in the sidebar. `url` is the host directory;
/// `guestPath` is where that same directory is mounted inside the VM,
/// used purely to label the breadcrumb so the user thinks in guest
/// terms ("/home/ubuntu/clips") rather than the opaque Application
/// Support path it physically lives at.
struct FileBrowserLocation: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let guestPath: String
    let symbol: String
}

/// One row in the listing.
struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var id: String { url.path }
}

@MainActor
@Observable
final class FileBrowserModel {
    let locations: [FileBrowserLocation]
    private(set) var location: FileBrowserLocation
    /// Where we currently are, always at or below `location.url`.
    private(set) var current: URL
    private(set) var entries: [FileEntry] = []

    init(locations: [FileBrowserLocation]) {
        // Always have at least one root so the view never deals with an
        // empty sidebar; the caller guarantees Home is first.
        self.locations = locations
        let root = locations.first!
        self.location = root
        self.current = root.url
        reload()
    }

    /// Guest-facing path for the current directory, e.g. the host's
    /// `…/profiles/<id>/home/clips` becomes `/home/ubuntu/clips`.
    var guestBreadcrumb: String {
        let rootPath = location.url.standardizedFileURL.path
        let here = current.standardizedFileURL.path
        guard here.hasPrefix(rootPath) else { return location.guestPath }
        let rel = String(here.dropFirst(rootPath.count))
        return location.guestPath + rel
    }

    /// True once we've descended below a root (enables the Up button).
    var canGoUp: Bool {
        current.standardizedFileURL.path != location.url.standardizedFileURL.path
    }

    func switchTo(_ loc: FileBrowserLocation) {
        location = loc
        current = loc.url
        reload()
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            current = entry.url
            reload()
        } else {
            // Real file on disk — open it on the Mac with its default
            // app so the user can, e.g., play that freshly-generated
            // .mp4 in QuickTime to "make sure it plays nice".
            NSWorkspace.shared.open(entry.url)
        }
    }

    func goUp() {
        guard canGoUp else { return }
        current = current.deletingLastPathComponent()
        reload()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    func newFolder() {
        let base = NSLocalizedString("New Folder", comment: "")
        var name = base
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: current.appendingPathComponent(name).path) {
            name = "\(base) \(n)"; n += 1
        }
        try? fm.createDirectory(at: current.appendingPathComponent(name),
                                withIntermediateDirectories: false)
        reload()
    }

    /// Copy files dropped from Finder into the current guest directory.
    func receive(_ urls: [URL]) {
        let fm = FileManager.default
        for src in urls {
            var dst = current.appendingPathComponent(src.lastPathComponent)
            // Don't clobber: append " copy", " copy 2", … like Finder.
            if fm.fileExists(atPath: dst.path) {
                let ext = src.pathExtension
                let stem = src.deletingPathExtension().lastPathComponent
                var n = 1
                repeat {
                    let suffix = n == 1 ? " copy" : " copy \(n)"
                    let leaf = ext.isEmpty ? stem + suffix : "\(stem)\(suffix).\(ext)"
                    dst = current.appendingPathComponent(leaf)
                    n += 1
                } while fm.fileExists(atPath: dst.path)
            }
            try? fm.copyItem(at: src, to: dst)
        }
        reload()
    }

    /// Re-read the current directory. Cheap enough to call on a poll so
    /// agent-generated files appear without the user hitting refresh.
    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .isHiddenKey]
        let contents = (try? fm.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        let mapped: [FileEntry] = contents.compactMap { url in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: vals?.isDirectory ?? false,
                size: Int64(vals?.fileSize ?? 0),
                modified: vals?.contentModificationDate ?? .distantPast)
        }
        // Folders first, then files; each group alphabetical, case-insensitive.
        entries = mapped.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - View

struct FileBrowserView: View {
    @State var model: FileBrowserModel
    @State private var selection: String?
    @State private var dropTargeted = false

    private let reloadTimer = Timer.publish(every: 1.5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
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
        .onReceive(reloadTimer) { _ in model.reload() }
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
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
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

            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            Text(model.guestBreadcrumb)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(NSLocalizedString("Path inside the VM", comment: ""))

            Spacer()

            Button(action: model.newFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("New folder", comment: ""))

            Button { model.reveal(model.current) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Reveal this folder in Finder", comment: ""))

            Button(action: model.reload) {
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
            if model.entries.isEmpty {
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
                            // Drag a file out → Finder/desktop copies it.
                            .onDrag {
                                NSItemProvider(contentsOf: entry.url)
                                    ?? NSItemProvider()
                            }
                            .contextMenu {
                                Button(NSLocalizedString("Open", comment: "")) {
                                    model.open(entry)
                                }
                                Button(NSLocalizedString("Reveal in Finder",
                                                          comment: "")) {
                                    model.reveal(entry.url)
                                }
                                Divider()
                                Button(NSLocalizedString("Move to Trash",
                                                          comment: ""),
                                       role: .destructive) {
                                    if selection == entry.id { selection = nil }
                                    model.trash(entry.url)
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

/// One file/folder row: native macOS icon (so a .png, .mp4 and .c each
/// get their own look for free), name, size, modified date.
private struct FileRow: View {
    let entry: FileEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
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

    private var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: entry.url.path)
        img.size = NSSize(width: 24, height: 24)
        return img
    }

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
