import Foundation
import SwiftUI

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
    /// Guest-side absolute path of the repo being shown (nil = no repo).
    private(set) var repoRoot: String?
    /// The profile whose guest the queries run in — changing VMs swaps this.
    private(set) var profileID: Profile.ID?

    private(set) var rootNodes: [FileNode] = []
    private(set) var statuses: [String: GitFileStatus] = [:]
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

    private func exec(_ command: String, timeout: Int = 30) async throws -> String {
        guard let profileID, let execProvider else {
            throw ACAppDelegate.GuestExecError.vmNotRunning
        }
        return try await execProvider(profileID, command, timeout)
    }

    /// Point the pane at (profile, repoRoot). Clears immediately on change so
    /// stale trees never show against a new repo; a nil root empties the pane
    /// (also used to park the model while the pane is closed).
    func setRepo(profileID: Profile.ID?, root: String?) {
        guard profileID != self.profileID || root != repoRoot else { return }
        self.profileID = profileID
        self.repoRoot = root
        refreshGeneration += 1   // orphan any in-flight refresh
        detailGeneration += 1
        shownDetailKey = nil
        rootNodes = []
        statuses = [:]
        selectedPath = nil
        detail = .none
        loadError = nil
        truncated = false
        loading = root != nil
        guard root != nil else { return }
        Task { await refresh() }
    }

    /// Re-list the tree + statuses. Safe to call on a timer; cheap in the
    /// guest (git ls-files + git status) and diffed into the UI by SwiftUI.
    /// The whole payload is base64-wrapped in the guest: filenames are raw
    /// bytes, and one non-UTF-8 name must not poison the channel.
    func refresh() async {
        guard let root = repoRoot else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let q = shellQuote(root)
        do {
            let out = try await exec(
                "{ git -C \(q) ls-files -co --exclude-standard -z; printf '\\001'; " +
                "git -C \(q) status --porcelain -z; } | base64 -w0")
            guard generation == refreshGeneration else { return }
            let data = Data(base64Encoded: out.filter { !$0.isWhitespace }) ?? Data()
            let halves = data.split(separator: UInt8(0x01), maxSplits: 1,
                                    omittingEmptySubsequences: false)
            let files = halves.first.map(Self.nulSeparatedStrings) ?? []
            let newStatuses = halves.count > 1
                ? Self.parsePorcelain(String(decoding: halves[1], as: UTF8.self)) : [:]
            truncated = files.count > Self.maxFiles
            statuses = newStatuses
            rootNodes = FileNode.tree(paths: Array(files.prefix(Self.maxFiles)),
                                      statuses: newStatuses)
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
        guard let root = repoRoot, let path = selectedPath else {
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
                // base64 for the same reason as refresh(): the diff body is
                // whatever bytes the file contains.
                let out = try await exec(
                    "git -C \(qroot) diff HEAD --no-color --no-ext-diff -- \(qpath) " +
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
