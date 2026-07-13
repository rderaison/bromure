import SwiftUI
import AppKit

// MARK: - ext4 image browser (Workspaces ▸ Open ext4 file…)
//
// A Finder-like window over a raw or partitioned ext4 `.img`, backed by the
// userland Ext4Volume reader/writer. Opens read-only by default (a workspace VM
// may still have the disk attached); editing is behind an explicit gate.

final class Ext4BrowserModel: ObservableObject {
    let imagePath: String
    private(set) var volume: Ext4Volume

    struct Row: Identifiable, Hashable {
        let id: UInt32          // inode number
        let name: String
        let size: UInt64
        let fileType: UInt8
        let isDir: Bool
        let isSymlink: Bool
    }
    struct Preview: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        let isBinary: Bool
        let shownBytes: Int
        let totalBytes: UInt64
    }
    struct FsckReport: Identifiable { let id = UUID(); let summary: String; let output: String }

    @Published var writable = false
    @Published var cwdPath = "/"
    @Published private(set) var cwdInode = Ext4Volume.rootInode
    @Published var rows: [Row] = []
    @Published var banner: String?
    @Published var busy = false
    @Published var preview: Preview?
    @Published var fsckReport: FsckReport?

    var volumeLabel: String { volume.volumeName.isEmpty ? "(unnamed)" : volume.volumeName }
    var infoLine: String {
        let bytes = ByteCountFormatter.string(fromByteCount:
            Int64(volume.sb.blocksCount) * Int64(volume.blockSize), countStyle: .file)
        let clean = volume.sb.needsRecovery ? "journal needs recovery"
            : (volume.sb.isClean ? "clean" : "not cleanly unmounted")
        let part = volume.partitionOffset == 0 ? "raw" : "partition @\(volume.partitionOffset / (1<<20))MiB"
        return "\(volumeLabel) · \(bytes) · \(part) · \(clean)"
    }

    init(imagePath: String) throws {
        self.imagePath = imagePath
        self.volume = try Ext4Volume(path: imagePath, writable: false)
        reload()
    }

    // MARK: navigation

    func reload() {
        do {
            let entries = try volume.listDir(cwdInode)
            rows = entries.map { e in
                let node = try? volume.inode(e.ino)
                return Row(id: e.ino, name: e.name,
                          size: node?.size ?? 0, fileType: e.fileType,
                          isDir: node?.isDir ?? e.isDir,
                          isSymlink: node?.isSymlink ?? false)
            }.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }         // dirs first
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            banner = "Failed to list \(cwdPath): \(error)"
            rows = []
        }
    }

    func enter(_ row: Row) {
        guard row.isDir else { openPreview(row); return }
        cwdInode = row.id
        cwdPath = cwdPath == "/" ? "/\(row.name)" : "\(cwdPath)/\(row.name)"
        reload()
    }

    func goUp() {
        guard cwdPath != "/" else { return }
        let parent = "/" + cwdPath.split(separator: "/").dropLast().joined(separator: "/")
        do {
            cwdInode = try volume.resolve(parent.isEmpty ? "/" : parent)
            cwdPath = parent.isEmpty ? "/" : parent
            reload()
        } catch { banner = "\(error)" }
    }

    // MARK: preview

    func openPreview(_ row: Row) {
        do {
            let node = try volume.inode(row.id)
            if node.isSymlink {
                let target = try volume.symlinkTarget(node)
                preview = Preview(title: row.name + " → symlink", text: target,
                                  isBinary: false, shownBytes: target.utf8.count, totalBytes: node.size)
                return
            }
            let cap = 1 << 20                                    // preview up to 1 MiB
            let bytes = Array(try volume.readData(node).prefix(cap))
            let isText = Self.looksLikeText(bytes)
            let text = isText ? String(decoding: bytes, as: UTF8.self) : Self.hexDump(bytes)
            preview = Preview(title: row.name, text: text, isBinary: !isText,
                              shownBytes: bytes.count, totalBytes: node.size)
        } catch { banner = "Cannot read \(row.name): \(error)" }
    }

    // MARK: extract to host

    func extract(_ row: Row) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = row.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let node = try volume.inode(row.id)
            let bytes = try volume.readData(node)
            try Data(bytes).write(to: url)
            banner = "Extracted \(row.name) (\(bytes.count) bytes)"
        } catch { banner = "Extract failed: \(error)" }
    }

    // MARK: editing

    /// Reopen the volume read-write after warning that the workspace VM must be
    /// stopped (writing to a live disk corrupts it).
    func enableEditing() {
        let alert = NSAlert()
        alert.messageText = "Enable editing of this disk image?"
        alert.informativeText = """
        Only edit an image whose workspace VM is stopped. Writing to a disk that a \
        running VM has open will corrupt it.

        Edits replace a file's contents in place; the change is written directly to \
        the image.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable Editing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let fresh = try Ext4Volume(path: imagePath, writable: true)
            volume = fresh
            writable = true
            banner = "Editing enabled — replace a file to write it back."
            reload()
        } catch { banner = "Could not open for writing: \(error)" }
    }

    /// Replace a file's contents from a host file (in-place overwrite).
    func replace(_ row: Row) {
        guard writable else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file whose contents will replace “\(row.name)”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = [UInt8](try Data(contentsOf: url))
            let outcome = try volume.overwriteFile(ino: row.id, with: data)
            switch outcome {
            case .inPlace: banner = "Replaced \(row.name) (\(data.count) bytes)."
            case .grew(let n): banner = "Replaced \(row.name); grew \(n) block(s) — run fsck to finalize."
            }
            reload()
        } catch let e as Ext4Error {
            if case .unsupported = e, "\(e)".contains("grow") {
                presentGrowLimit(row: row)
            } else {
                banner = "Replace failed: \(e)"
            }
        } catch { banner = "Replace failed: \(error)" }
    }

    private func presentGrowLimit(row: Row) {
        let a = NSAlert()
        a.messageText = "That file would need to grow"
        a.informativeText = """
        The new contents need more disk blocks than “\(row.name)” currently occupies. \
        In-place editing only supports replacing a file with contents that fit its \
        existing blocks. Growing a file (allocating new blocks) requires fsck-backed \
        writes, which aren’t enabled yet.
        """
        a.runModal()
    }

    // MARK: fsck

    func runFsck() {
        guard Ext4Fsck.isAvailable else {
            let a = NSAlert()
            a.messageText = "fsck.ext4 is not installed"
            a.informativeText = "Install it with:\n\n    brew install e2fsprogs\n\nthen reopen this window."
            a.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Run fsck.ext4 on this image?"
        confirm.informativeText = """
        This checks and repairs the filesystem, replaying the journal if needed. \
        The workspace VM must be stopped. It can modify the image.
        """
        confirm.addButton(withTitle: "Run fsck")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        banner = "Running fsck.ext4…"
        let path = imagePath
        let offset = volume.partitionOffset
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Ext4Fsck.Result, Error>
            do { result = .success(try Ext4Fsck.check(imagePath: path, partitionOffset: offset, autoFix: true)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let r):
                    self.fsckReport = FsckReport(summary: r.summary, output: r.output)
                    // Reopen: fsck may have changed the fs (and cleared recovery).
                    if let fresh = try? Ext4Volume(path: path, writable: self.writable) {
                        self.volume = fresh; self.cwdInode = Ext4Volume.rootInode
                        self.cwdPath = "/"; self.reload()
                    }
                case .failure(let e):
                    self.banner = "fsck failed: \(e)"
                }
            }
        }
    }

    // MARK: helpers

    static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        if bytes.contains(0) { return false }                    // NUL ⇒ binary
        let sample = bytes.prefix(4096)
        let printable = sample.filter { $0 == 9 || $0 == 10 || $0 == 13 || (0x20...0x7E).contains($0) || $0 >= 0x80 }
        return Double(printable.count) / Double(sample.count) > 0.85
    }

    static func hexDump(_ bytes: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < bytes.count {
            let row = bytes[i..<min(i + 16, bytes.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)   // 16×3 − 1
            let ascii = row.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            out += String(format: "%08x  ", i) + hex + "  " + ascii + "\n"
            i += 16
        }
        return out
    }
}

// MARK: - View

struct Ext4BrowserView: View {
    @ObservedObject var model: Ext4BrowserModel
    @State private var selection: Ext4BrowserModel.Row.ID?

    private var selectedRow: Ext4BrowserModel.Row? {
        model.rows.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            if let banner = model.banner {
                Divider()
                HStack {
                    Text(banner).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { model.banner = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .sheet(item: $model.preview) { p in previewSheet(p) }
        .sheet(item: $model.fsckReport) { r in fsckSheet(r) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(model.cwdPath == "/").help("Up")
            Text(model.cwdPath).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.head)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            if model.writable {
                Label("Editing", systemImage: "pencil").font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Button("Enable Editing…") { model.enableEditing() }
            }
            Button("Run fsck…") { model.runFsck() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Text(model.infoLine).font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .offset(y: 10)
        }
    }

    private var table: some View {
        Table(model.rows, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: 6) {
                    Image(systemName: icon(row)).foregroundStyle(row.isDir ? Color.accentColor : .secondary)
                    Text(row.name)
                    if row.isSymlink { Image(systemName: "arrow.turn.up.right").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            TableColumn("Size") { row in
                Text(row.isDir ? "—" : ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(90)
            TableColumn("Type") { row in
                Text(typeName(row)).foregroundStyle(.secondary).font(.caption)
            }.width(80)
        }
        .contextMenu(forSelectionType: Ext4BrowserModel.Row.ID.self) { ids in
            if let row = model.rows.first(where: { ids.contains($0.id) }) {
                if row.isDir { Button("Open") { model.enter(row) } }
                else {
                    Button("Preview") { model.openPreview(row) }
                    Button("Extract…") { model.extract(row) }
                    if model.writable { Button("Replace…") { model.replace(row) } }
                }
            }
        } primaryAction: { ids in
            if let row = model.rows.first(where: { ids.contains($0.id) }) { model.enter(row) }
        }
    }

    private func previewSheet(_ p: Ext4BrowserModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                Button("Done") { model.preview = nil }.keyboardShortcut(.defaultAction)
            }.padding(12)
            Divider()
            ScrollView {
                Text(p.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            Text(p.isBinary
                 ? "Binary · showing first \(p.shownBytes) of \(p.totalBytes) bytes"
                 : "\(p.totalBytes) bytes\(p.shownBytes < Int(p.totalBytes) ? " · showing first \(p.shownBytes)" : "")")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 680, height: 520)
    }

    private func fsckSheet(_ r: Ext4BrowserModel.FsckReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("fsck.ext4").font(.headline)
                Spacer()
                Button("Done") { model.fsckReport = nil }.keyboardShortcut(.defaultAction)
            }.padding(12)
            Divider()
            Text(r.summary).font(.callout).bold().padding(.horizontal, 12).padding(.top, 8)
            ScrollView {
                Text(r.output.isEmpty ? "(no output)" : r.output)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(width: 680, height: 480)
    }

    private func icon(_ row: Ext4BrowserModel.Row) -> String {
        if row.isDir { return "folder.fill" }
        if row.isSymlink { return "link" }
        return "doc"
    }
    private func typeName(_ row: Ext4BrowserModel.Row) -> String {
        if row.isDir { return "Folder" }
        if row.isSymlink { return "Symlink" }
        switch row.fileType { case 3: return "Char"; case 4: return "Block"; case 5: return "FIFO"; case 6: return "Socket"; default: return "File" }
    }
}

// MARK: - Window controller

@MainActor
final class Ext4BrowserWindowController: NSObject, NSWindowDelegate {
    private static var open: [String: Ext4BrowserWindowController] = [:]
    private let window: NSWindow
    private let key: String

    /// Open (or focus) a browser window for an ext4 image.
    static func show(imagePath: String) {
        if let existing = open[imagePath] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        do {
            let model = try Ext4BrowserModel(imagePath: imagePath)
            let controller = Ext4BrowserWindowController(imagePath: imagePath, model: model)
            open[imagePath] = controller
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let a = NSAlert()
            a.messageText = "Can’t open ext4 image"
            a.informativeText = "\((imagePath as NSString).lastPathComponent): \(error)"
            a.alertStyle = .warning
            a.runModal()
        }
    }

    private init(imagePath: String, model: Ext4BrowserModel) {
        key = imagePath
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "ext4 — \((imagePath as NSString).lastPathComponent)"
        window.center()
        super.init()
        window.contentView = NSHostingView(rootView: Ext4BrowserView(model: model))
        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    func windowWillClose(_ notification: Notification) {
        Ext4BrowserWindowController.open[key] = nil
    }
}
