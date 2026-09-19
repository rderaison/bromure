import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// The file-explorer pane's data layer: git status / file tree / diff / file
// contents for the active tab's repo, all sourced from INSIDE the guest.
// Every query is a shell command run over the guest shell channel (vsock
// 5800, `ACAppDelegate.guestExec`) — deliberately not the virtio share, so
// the pane keeps working when the VM is remote and no share is mounted.

/// Runs a shell command in a profile's guest and returns its stdout.
typealias GuestExecProvider =
    @MainActor (_ profileID: Profile.ID, _ command: String, _ timeout: Int) async throws -> String

// MARK: - Git file status

enum GitFileStatus: Sendable {
    case modified, added, untracked, deleted, renamed, conflicted

    var tint: Color {
        switch self {
        case .modified: .orange
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed: .blue
        case .conflicted: .purple
        }
    }

    /// One-letter badge, VS Code convention.
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "!"
        }
    }

    /// Parse a porcelain-v1 `XY` pair (index + worktree status).
    init?(porcelain xy: Substring) {
        guard xy.count == 2, let x = xy.first, let y = xy.last else { return nil }
        switch (x, y) {
        case ("?", "?"): self = .untracked
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): self = .conflicted
        default:
            if x == "R" || y == "R" { self = .renamed }
            else if x == "D" || y == "D" { self = .deleted }
            else if x == "A" { self = .added }
            else if "MT".contains(x) || "MT".contains(y) { self = .modified }
            else { return nil }
        }
    }
}

// MARK: - File tree

/// One node of the repo tree. Reference type so the (potentially large) tree
/// is built once per refresh and shared; SwiftUI identity is the path.
final class FileNode: Identifiable {
    let name: String
    /// Repo-relative path ("Sources/App/main.swift").
    let path: String
    let isDirectory: Bool
    var children: [FileNode] = []
    var status: GitFileStatus?
    /// A descendant has a status — lets folders carry the "something changed
    /// in here" dot even while collapsed.
    var containsChanges = false
    /// False for a folder listed lazily whose contents haven't been fetched
    /// yet (they are, the moment it's unfolded).
    var childrenLoaded = true

    var id: String { path }

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Build a tree from repo-relative file paths + a status map. Directories
    /// first, then files, both alphabetical (case-insensitive) — IDE order.
    static func tree(paths: [String], statuses: [String: GitFileStatus]) -> [FileNode] {
        let root = FileNode(name: "", path: "", isDirectory: true)
        var dirs: [String: FileNode] = ["": root]

        func directory(_ path: String) -> FileNode {
            if let d = dirs[path] { return d }
            let name = String(path.split(separator: "/").last ?? "")
            let parentPath = path.contains("/")
                ? String(path[..<path.lastIndex(of: "/")!]) : ""
            let node = FileNode(name: name, path: path, isDirectory: true)
            dirs[path] = node
            directory(parentPath).children.append(node)
            return node
        }

        // Deleted files vanish from `ls-files` once staged, so union in every
        // status path to keep them visible (struck through) in the tree.
        for p in Set(paths).union(statuses.keys) where !p.isEmpty {
            let name = String(p.split(separator: "/").last ?? "")
            let parentPath = p.contains("/") ? String(p[..<p.lastIndex(of: "/")!]) : ""
            let node = FileNode(name: name, path: p, isDirectory: false)
            node.status = statuses[p]
            directory(parentPath).children.append(node)
        }

        // Propagate "contains changes" up and sort each directory.
        @discardableResult
        func finalize(_ node: FileNode) -> Bool {
            var dirty = node.status != nil
            for child in node.children where finalize(child) { dirty = true }
            node.containsChanges = dirty && node.isDirectory
            node.children.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return dirty
        }
        finalize(root)
        return root.children
    }
}

// MARK: - Unified diff model

/// A parsed `git diff` for one file, ready to render with per-line coloring
/// and old/new line-number gutters.
struct DiffDocument {
    struct Line: Identifiable {
        enum Kind { case meta, hunk, context, addition, deletion }
        let id: Int
        let kind: Kind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }

    var lines: [Line] = []
    var additions = 0
    var deletions = 0

    init(unifiedDiff: String) {
        var oldLine = 0, newLine = 0, id = 0
        for raw in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { id += 1 }
            let text = String(raw)
            if text.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@ optional heading
                let parts = text.split(separator: " ")
                if parts.count >= 3,
                   let o = Int(parts[1].dropFirst().split(separator: ",").first ?? ""),
                   let n = Int(parts[2].dropFirst().split(separator: ",").first ?? "") {
                    oldLine = o
                    newLine = n
                }
                lines.append(Line(id: id, kind: .hunk, text: text, oldLine: nil, newLine: nil))
            } else if text.hasPrefix("+") && !text.hasPrefix("+++") {
                lines.append(Line(id: id, kind: .addition, text: String(text.dropFirst()),
                                  oldLine: nil, newLine: newLine))
                newLine += 1
                additions += 1
            } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                lines.append(Line(id: id, kind: .deletion, text: String(text.dropFirst()),
                                  oldLine: oldLine, newLine: nil))
                oldLine += 1
                deletions += 1
            } else if text.hasPrefix(" ") {
                lines.append(Line(id: id, kind: .context, text: String(text.dropFirst()),
                                  oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            } else if !text.isEmpty {
                // diff --git / index / ---/+++ / "\ No newline at end of file"
                lines.append(Line(id: id, kind: .meta, text: text, oldLine: nil, newLine: nil))
            }
        }
    }
}

// MARK: - Model

/// Data model for the file-explorer pane. One instance per unified window;
/// re-pointed at whatever repo the selected VM's active tab sits in.
@MainActor
@Observable
final class FileExplorerModel {
    /// The git top level the shown folder sits in (nil = not a repo). Found
    /// by the guest on every refresh, so it's right wherever the user browses.
    private(set) var repoRoot: String?
    /// The folder on show (absolute guest path). Defaults to the tab's repo
    /// root when it sits in one, else the tab's own folder; ".." and entering
    /// a folder move it by hand until the tab's context changes.
    private(set) var root: String?
    private var manualRoot: String?
    private var contextCwd: String?
    private var contextRepo: String?
    /// Folders unfolded in the tree (root-relative); each is listed on refresh.
    private(set) var expandedDirs: Set<String> = []
    /// An upload or download in flight — the progress pill.
    private(set) var transferText: String?
    /// Injected by the window: the guest file service (read/write/mkdir) —
    /// what makes dragging a file out and dropping one in work.
    var fileOpProvider: ((_ profileID: Profile.ID, _ op: [String: Any]) async throws -> [String: Any])?
    private static let chunkBytes = 6 * 1024 * 1024
    private let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bromure-files", isDirectory: true)
        .appendingPathComponent("explorer", isDirectory: true)

    var canGoUp: Bool { (root ?? "/") != "/" }
    var canTransfer: Bool { fileOpProvider != nil && root != nil && profileID != nil }
    /// The profile whose guest the queries run in — changing VMs swaps this.
    private(set) var profileID: Profile.ID?

    private(set) var rootNodes: [FileNode] = []
    private(set) var statuses: [String: GitFileStatus] = [:]
    /// Where each status came from: the repository (absolute guest path)
    /// and the path inside it — what `git diff` needs, since a folder on
    /// show may hold several repositories (the home with a project in it).
    private(set) var statusOrigins: [String: (repo: String, path: String)] = [:]
    private(set) var loadError: String?
    /// True until the first listing for the current repo lands.
    private(set) var loading = false
    /// File count cap hit — tree truncated (giant repos).
    private(set) var truncated = false
    var changedOnly = false
    /// True while the pop-out viewer window is showing this model. Keeps the
    /// pane from parking the model when it collapses and keeps its git-status
    /// polling alive — the window follows the pane's selection live.
    var poppedOut = false

    private(set) var selectedPath: String?

    enum Detail {
        case none
        case loading
        case diff(DiffDocument)
        case markdown(String)
        case code(String, language: String?)
        case binary
        case tooLarge
        case error(String)
    }
    private(set) var detail: Detail = .none

    enum DetailMode { case diff, preview }
    private(set) var detailMode: DetailMode = .preview

    /// Injected by the window: runs a command in a profile's guest.
    var execProvider: GuestExecProvider?

    /// Newest-wins guards: a stale refresh/detail load for a previous repo or
    /// file must not clobber the current one.
    private var refreshGeneration = 0
    private var detailGeneration = 0
    /// "path|mode" the detail currently shows — a poll-driven reload of the
    /// same selection keeps the content up (no spinner flash every 4s).
    private var shownDetailKey: String?

    private static let maxFiles = 20_000
    private static let maxPreviewBytes = 512 * 1024
    private static let maxDiffBytes = 1024 * 1024

    // MARK: Review comments (diff pane → the live agent)

    /// A margin annotation drafted on the diff pane, to be batched to the
    /// coding agent running in the active tab.
    struct ReviewDraft: Identifiable, Equatable {
        let id = UUID()
        var file: String
        var line: Int
        var text: String
    }

    var reviewDrafts: [ReviewDraft] = []
    /// tmux window index of the active tab WHEN its front process is a
    /// coding agent — nil hides the commenting UI. Kept fresh by the pane.
    var agentTabIndex: Int?
    var sendingReview = false

    func addReviewDraft(file: String, line: Int, text: String) {
        reviewDrafts.append(ReviewDraft(file: file, line: line, text: text))
    }

    func removeReviewDraft(_ id: UUID) {
        reviewDrafts.removeAll { $0.id == id }
    }

    /// Batch every draft into one feedback message and type it into the
    /// active tab's agent session. Clears the drafts on success.
    func submitReviewDrafts() async -> Bool {
        guard let index = agentTabIndex, !reviewDrafts.isEmpty else { return false }
        var msg = "Review feedback on your current changes — address each point:"
        for d in reviewDrafts {
            msg += "\n- In \(d.file), line \(d.line): \(d.text)"
        }
        sendingReview = true
        defer { sendingReview = false }
        let cmd = CodingTaskEngine.typeCommand(tabIndex: index, text: msg)
        guard (try? await exec(cmd, timeout: 25)) != nil else { return false }
        reviewDrafts.removeAll()
        return true
    }

    private func exec(_ command: String, timeout: Int = 30) async throws -> String {
        guard let profileID, let execProvider else {
            throw ACAppDelegate.GuestExecError.vmNotRunning
        }
        return try await execProvider(profileID, command, timeout)
    }

    /// Point the pane at the active tab: its folder, and the repo it sits in
    /// when it does. A hand-picked folder ("..", entering one) survives
    /// refreshes and is dropped when the tab's context changes. A nil cwd
    /// empties the pane (also used to park the model while the pane is
    /// closed).
    func setLocation(profileID: Profile.ID?, cwd: String?, repoRoot hint: String?) {
        let contextChanged = profileID != self.profileID || cwd != contextCwd || hint != contextRepo
        if contextChanged { manualRoot = nil }
        contextCwd = cwd
        contextRepo = hint
        let newRoot = manualRoot ?? hint ?? cwd
        guard contextChanged || newRoot != root else { return }
        self.profileID = profileID
        show(newRoot, repoHint: hint)
    }

    /// Compatibility: a repo root as both the folder and the repo.
    func setRepo(profileID: Profile.ID?, root: String?) {
        setLocation(profileID: profileID, cwd: root, repoRoot: root)
    }

    /// Up one folder — all the way to "/" if the user insists.
    func goUp() {
        guard let r = root, r != "/" else { return }
        let parent = (r as NSString).deletingLastPathComponent
        manualRoot = parent.isEmpty ? "/" : parent
        show(manualRoot, repoHint: contextRepo)
    }

    /// Make a folder of the tree the one on show.
    func enter(_ dir: String) {
        guard let r = root else { return }
        manualRoot = (r as NSString).appendingPathComponent(dir)
        show(manualRoot, repoHint: contextRepo)
    }

    func toggleExpanded(_ dir: String) {
        if expandedDirs.contains(dir) {
            expandedDirs.remove(dir)
        } else {
            expandedDirs.insert(dir)
            Task { await refresh() }
        }
    }

    func expand(_ dirs: Set<String>) {
        let new = dirs.subtracting(expandedDirs)
        guard !new.isEmpty else { return }
        expandedDirs.formUnion(new)
        Task { await refresh() }
    }

    private func show(_ newRoot: String?, repoHint: String?) {
        reviewDrafts.removeAll()
        root = newRoot
        repoRoot = newRoot.flatMap { r in
            repoHint.flatMap { r == $0 || r.hasPrefix($0 + "/") ? $0 : nil }
        }
        refreshGeneration += 1   // orphan any in-flight refresh
        detailGeneration += 1
        shownDetailKey = nil
        rootNodes = []
        statuses = [:]
        statusOrigins = [:]
        expandedDirs = []
        selectedPath = nil
        detail = .none
        loadError = nil
        truncated = false
        loading = newRoot != nil
        guard newRoot != nil else { return }
        Task { await refresh() }
    }

    /// Re-list the folder (one level, plus every unfolded folder), find the
    /// repositories in play and their git status — one guest round-trip,
    /// safe on a timer. "In play" = the repo the folder sits in, plus the
    /// repo of every unfolded folder: browsing the home and unfolding a
    /// project in it shows that project's changes. The whole payload is
    /// base64-wrapped in the guest: filenames are raw bytes, and one
    /// non-UTF-8 name must not poison the channel.
    func refresh() async {
        guard let root else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let dirs = [root] + expandedDirs.sorted().map { (root as NSString).appendingPathComponent($0) }
        // Each folder: "\002<path>\001<type><name>\0…" — `find -L` so a
        // symlinked folder (a shared folder) reads as a folder; .git hidden.
        let listing = dirs.map { d in
            let q = shellQuote(d)
            return "printf '\\002%s\\001' \(q); find -L \(q) -mindepth 1 -maxdepth 1 ! -name .git "
                + "-printf '%y%f\\0' 2>/dev/null"
        }.joined(separator: "; ")
        let q = shellQuote(root)
        // Then, per distinct repository among those folders:
        // "\002<toplevel>\001<status --porcelain -z>".
        let probe = dirs.map(shellQuote).joined(separator: " ")
        let cmd = "{ t=$(git -C \(q) rev-parse --show-toplevel 2>/dev/null); printf '%s\\003' \"$t\"; "
            + "\(listing); printf '\\003'; "
            + "for d in \(probe); do git -C \"$d\" rev-parse --show-toplevel 2>/dev/null; done | sort -u "
            + "| while IFS= read -r r; do [ -n \"$r\" ] || continue; printf '\\002%s\\001' \"$r\"; "
            + "git -C \"$r\" status --porcelain -z 2>/dev/null; done; true; } | base64 -w0"
        do {
            let out = try await exec(cmd)
            guard generation == refreshGeneration, root == self.root else { return }
            let data = Data(base64Encoded: out.filter { !$0.isWhitespace }) ?? Data()
            let parts = data.split(separator: UInt8(0x03), maxSplits: 2, omittingEmptySubsequences: false)
            let toplevel = parts.first.map {
                String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            repoRoot = toplevel.isEmpty ? nil : toplevel
            // Statuses come repo-relative; the tree is root-relative.
            var sections: [(toplevel: String, porcelain: String)] = []
            if parts.count > 2 {
                for section in parts[2].split(separator: UInt8(0x02), omittingEmptySubsequences: true) {
                    let kv = section.split(separator: UInt8(0x01), maxSplits: 1, omittingEmptySubsequences: false)
                    guard let first = kv.first else { continue }
                    let top = String(decoding: first, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    sections.append((top, kv.count > 1 ? String(decoding: kv[1], as: UTF8.self) : ""))
                }
            }
            let (mapped, origins) = Self.mapStatuses(root: root, sections: sections)
            statuses = mapped
            statusOrigins = origins
            var byDir: [String: [(name: String, isDir: Bool)]] = [:]
            if parts.count > 1 {
                for section in parts[1].split(separator: UInt8(0x02), omittingEmptySubsequences: true) {
                    let kv = section.split(separator: UInt8(0x01), maxSplits: 1, omittingEmptySubsequences: false)
                    guard let first = kv.first else { continue }
                    let dpath = String(decoding: first, as: UTF8.self)
                    let entries = kv.count > 1 ? kv[1].split(separator: UInt8(0)) : []
                    byDir[dpath] = entries.compactMap { e in
                        guard let t = e.first else { return nil }
                        return (String(decoding: e.dropFirst(), as: UTF8.self), t == UInt8(ascii: "d"))
                    }
                }
            }
            rootNodes = Self.buildTree(root: root, listings: byDir, expanded: expandedDirs, statuses: mapped)
            truncated = false
            loadError = nil
            loading = false
            // The selected file's change state may have moved under us (the
            // agent edited it) — re-pull the detail so the diff stays live.
            if selectedPath != nil { await loadDetail() }
        } catch {
            guard generation == refreshGeneration else { return }
            loadError = error.localizedDescription
            loading = false
        }
    }

    /// Each repository's statuses (toplevel-relative, as porcelain reports
    /// them) as paths relative to the folder on show: the folder may sit
    /// inside the repository (keep what's under it, strip the way down) or
    /// hold it (prefix the way in). Repositories elsewhere are ignored.
    /// Also where each mapped path came from, for `git diff`.
    static func mapStatuses(root: String, sections: [(toplevel: String, porcelain: String)])
        -> (statuses: [String: GitFileStatus], origins: [String: (repo: String, path: String)]) {
        var statuses: [String: GitFileStatus] = [:]
        var origins: [String: (repo: String, path: String)] = [:]
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        for (top, raw) in sections where !top.isEmpty {
            let parsed = parsePorcelain(raw)
            if top == root {
                for (k, v) in parsed { statuses[k] = v; origins[k] = (top, k) }
            } else if root.hasPrefix(top + "/") {
                let prefix = String(root.dropFirst(top.count + 1)) + "/"
                for (k, v) in parsed where k.hasPrefix(prefix) {
                    let rel = String(k.dropFirst(prefix.count))
                    statuses[rel] = v; origins[rel] = (top, k)
                }
            } else if top.hasPrefix(rootPrefix) {
                let prefix = String(top.dropFirst(rootPrefix.count)) + "/"
                for (k, v) in parsed { statuses[prefix + k] = v; origins[prefix + k] = (top, k) }
            }
        }
        return (statuses, origins)
    }

    /// The tree from per-folder listings: folders first, then files, both
    /// alphabetical; a folder carries the "changed inside" dot from the
    /// statuses whether or not it's been unfolded.
    static func buildTree(root: String, listings: [String: [(name: String, isDir: Bool)]],
                          expanded: Set<String>, statuses: [String: GitFileStatus]) -> [FileNode] {
        var dirty = Set<String>()
        for k in statuses.keys {
            var p = k
            while let i = p.lastIndex(of: "/") { p = String(p[..<i]); dirty.insert(p) }
        }
        func nodes(dirAbs: String, rel: String) -> [FileNode] {
            var out: [FileNode] = []
            for e in listings[dirAbs] ?? [] {
                let path = rel.isEmpty ? e.name : rel + "/" + e.name
                let n = FileNode(name: e.name, path: path, isDirectory: e.isDir)
                if e.isDir {
                    n.containsChanges = dirty.contains(path)
                    if expanded.contains(path) {
                        n.children = nodes(dirAbs: (dirAbs as NSString).appendingPathComponent(e.name), rel: path)
                    } else {
                        n.childrenLoaded = false
                    }
                } else {
                    n.status = statuses[path]
                }
                out.append(n)
            }
            out.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return out
        }
        return nodes(dirAbs: root, rel: "")
    }

    // MARK: Transfers (the guest file service)

    private func fileOp(_ op: [String: Any]) async throws -> [String: Any] {
        guard let profileID, let fileOpProvider else { throw ACAppDelegate.GuestExecError.vmNotRunning }
        return try await fileOpProvider(profileID, op)
    }

    /// Pull a file (root-relative) into the local cache; returns the local URL.
    func download(_ relPath: String) async throws -> URL {
        guard let root, let profileID else { throw CocoaError(.fileNoSuchFile) }
        let guestPath = (root as NSString).appendingPathComponent(relPath)
        let local = downloadRoot
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent(String(guestPath.drop(while: { $0 == "/" })))
        // The guest is untrusted: a crafted name must never steer the write
        // outside the cache root.
        let rootPath = downloadRoot.standardizedFileURL.path
        guard local.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: local.path) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? handle.close() }
        let name = (relPath as NSString).lastPathComponent
        var offset: Int64 = 0
        while true {
            let resp = try await fileOp(["op": "read", "path": guestPath,
                                         "offset": offset, "length": Self.chunkBytes])
            guard let b64 = resp["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            handle.write(data)
            offset += Int64(data.count)
            transferText = String(format: NSLocalizedString("Copying %@ out… %@", comment: ""),
                                  name, ByteCountFormatter.string(fromByteCount: offset, countStyle: .file))
            let eof = (resp["eof"] as? Bool) ?? (resp["eof"] as? Int).map { $0 != 0 } ?? data.isEmpty
            if eof || data.isEmpty { break }
        }
        transferText = nil
        return local
    }

    /// Download, then put a copy in ~/Downloads and show it in the Finder.
    func saveToDownloads(_ relPath: String) {
        Task { @MainActor in
            do {
                let local = try await download(relPath)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                var dst = downloads.appendingPathComponent(local.lastPathComponent)
                var n = 2
                while FileManager.default.fileExists(atPath: dst.path) {
                    let stem = local.deletingPathExtension().lastPathComponent
                    let ext = local.pathExtension
                    dst = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                    n += 1
                }
                try FileManager.default.copyItem(at: local, to: dst)
#if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([dst])
#endif
            } catch {
                loadError = error.localizedDescription
                transferText = nil
            }
        }
    }

    /// Copy files dropped from the Finder into the folder on show (or the
    /// given root-relative folder), folders whole, chunked.
    func receive(_ urls: [URL], into dir: String? = nil) {
        guard let root, canTransfer else { return }
        let base = dir.map { (root as NSString).appendingPathComponent($0) } ?? root
        Task { @MainActor in
            for src in urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
                do {
                    try await uploadItem(at: src, to: (base as NSString).appendingPathComponent(src.lastPathComponent),
                                         isDirectory: isDir.boolValue)
                } catch {
                    loadError = error.localizedDescription
                }
            }
            transferText = nil
            await refresh()
        }
    }

    private func uploadItem(at src: URL, to guestPath: String, isDirectory: Bool) async throws {
        if isDirectory {
            _ = try await fileOp(["op": "mkdir", "path": guestPath])
            let children = (try? FileManager.default.contentsOfDirectory(
                at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children {
                let childIsDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                try await uploadItem(at: child, to: (guestPath as NSString).appendingPathComponent(child.lastPathComponent),
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
            _ = try await fileOp(["op": "write", "path": guestPath,
                                  "data": data.base64EncodedString(), "append": !first])
            sent += Int64(data.count)
            transferText = String(format: NSLocalizedString("Copying %@ in… %@", comment: ""),
                                  src.lastPathComponent,
                                  ByteCountFormatter.string(fromByteCount: sent, countStyle: .file))
            first = false
            if data.count < Self.chunkBytes { break }
        }
    }

#if os(macOS)
    /// Drag-out: a lazy file representation that downloads on drop, so a
    /// row can be dragged to the Finder, Mail, or any other app.
    nonisolated static func dragProvider(for relPath: String, model: FileExplorerModel) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = (relPath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        // The receiver names the file suggestedName + the type's preferred
        // extension — hand it an extension-less base.
        provider.suggestedName = type.preferredFilenameExtension != nil
            ? (name as NSString).deletingPathExtension : name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do { completion(try await model.download(relPath), false, nil) }
                catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }
#endif

    static func nulSeparatedStrings(_ data: Data.SubSequence) -> [String] {
        data.split(separator: UInt8(0)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `git status --porcelain -z`: entries `XY path` NUL-separated; renames
    /// carry the ORIGINAL path as one extra NUL-separated token.
    static func parsePorcelain(_ raw: String) -> [String: GitFileStatus] {
        var result: [String: GitFileStatus] = [:]
        let tokens = raw.split(separator: "\u{0}", omittingEmptySubsequences: true)
        var i = 0
        while i < tokens.count {
            let entry = tokens[i]
            i += 1
            guard entry.count > 3 else { continue }
            let xy = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            if xy.first == "R" || xy.last == "R" || xy.first == "C" || xy.last == "C" {
                i += 1   // skip the origin-path token
            }
            if let status = GitFileStatus(porcelain: xy) {
                result[path] = status
            }
        }
        return result
    }

    // MARK: Selection + detail (diff / preview)

    /// Diff only means something for tracked changes; untracked/added files
    /// have no HEAD side, so they get the preview.
    var selectionHasDiff: Bool {
        guard let p = selectedPath, let s = statuses[p] else { return false }
        return s != .untracked && s != .added
    }

    func select(_ path: String?) {
        selectedPath = path
        detailMode = {
            guard let path, let s = statuses[path], s != .untracked, s != .added
            else { return .preview }
            return .diff
        }()
        Task { await loadDetail() }
    }

    func setDetailMode(_ mode: DetailMode) {
        guard mode != detailMode else { return }
        detailMode = mode
        Task { await loadDetail() }
    }

    private func loadDetail() async {
        guard let root, let path = selectedPath else {
            detail = .none
            shownDetailKey = nil
            return
        }
        detailGeneration += 1
        let generation = detailGeneration
        let detailKey = "\(path)|\(detailMode)"
        if shownDetailKey != detailKey {
            detail = .loading
            shownDetailKey = detailKey
        }
        let qroot = shellQuote(root)
        let qpath = shellQuote(path)
        do {
            if detailMode == .diff && selectionHasDiff {
                // In the file's own repository — the folder on show may not
                // be one (the home, with the project unfolded in it).
                let (qrepo, qfile) = statusOrigins[path].map { (shellQuote($0.repo), shellQuote($0.path)) }
                    ?? (qroot, qpath)
                // base64 for the same reason as refresh(): the diff body is
                // whatever bytes the file contains.
                let out = try await exec(
                    "git -C \(qrepo) diff HEAD --no-color --no-ext-diff -- \(qfile) " +
                    "| head -c \(Self.maxDiffBytes) | base64 -w0")
                guard generation == detailGeneration else { return }
                let data = Data(base64Encoded: out.filter { !$0.isWhitespace }) ?? Data()
                detail = .diff(DiffDocument(unifiedDiff: String(decoding: data, as: UTF8.self)))
            } else if statuses[path] == .deleted {
                guard generation == detailGeneration else { return }
                detail = .error("File was deleted — switch to Diff to see what was removed.")
            } else {
                let out = try await exec(
                    "head -c \(Self.maxPreviewBytes + 1) \(qroot)/\(qpath) | base64 -w0")
                guard generation == detailGeneration else { return }
                let data = Data(base64Encoded: out.filter { !$0.isWhitespace }) ?? Data()
                if data.count > Self.maxPreviewBytes {
                    detail = .tooLarge
                } else if data.prefix(8192).contains(0) {
                    detail = .binary
                } else {
                    let text = String(decoding: data, as: UTF8.self)
                    let ext = (path as NSString).pathExtension.lowercased()
                    if ext == "md" || ext == "markdown" {
                        detail = .markdown(text)
                    } else {
                        detail = .code(text, language: Self.language(forExtension: ext))
                    }
                }
            }
        } catch {
            guard generation == detailGeneration else { return }
            detail = .error(error.localizedDescription)
        }
    }

    /// highlight.js language name by file extension; nil → plain text.
    static func language(forExtension ext: String) -> String? {
        switch ext {
        case "swift": "swift"
        case "py": "python"
        case "js", "mjs", "cjs", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "rb": "ruby"
        case "rs": "rust"
        case "go": "go"
        case "c", "h": "c"
        case "cpp", "cc", "hpp", "cxx": "cpp"
        case "m", "mm": "objectivec"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "cs": "csharp"
        case "php": "php"
        case "sh", "bash", "zsh": "bash"
        case "json": "json"
        case "yaml", "yml": "yaml"
        case "toml", "ini", "tf": "ini"
        case "xml", "plist", "sdef", "html", "htm": "xml"
        case "css": "css"
        case "scss", "sass": "scss"
        case "sql": "sql"
        case "diff", "patch": "diff"
        case "dockerfile": "dockerfile"
        case "proto": "protobuf"
        case "lua": "lua"
        case "pl", "pm": "perl"
        case "r": "r"
        case "vim": "vim"
        case "gradle": "gradle"
        case "cmake": "cmake"
        case "make", "mk": "makefile"
        default: nil
        }
    }
}

/// Single-quote a string for POSIX sh: ' → '\''.
private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
