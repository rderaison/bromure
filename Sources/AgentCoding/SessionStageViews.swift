#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dropped files

/// A file dragged onto a composer (host bytes + name + whether it's an
/// image, so the drop can show a thumbnail). Shared by the chat's composer
/// and the new-session screen, on every platform.
struct DroppedFile {
    let name: String
    let data: Data
    let isImage: Bool

    /// Largest file a drop attaches. Anything bigger is refused with a beep
    /// rather than vanishing silently. Files are memory-mapped, so a pending
    /// attachment doesn't hold a copy in RAM; staging writes it in chunks.
    static let maxBytes = 512 * 1024 * 1024

    /// Load one dragged item as bytes. Uses `loadObject(ofClass: URL.self)` —
    /// the same call the file browser's working drop uses — for Finder file
    /// drags (any type), and falls back to a raw image representation for images
    /// dragged from a browser/Preview (no backing file URL).
    static func load(_ p: NSItemProvider) async -> DroppedFile? {
        if p.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
            }
            guard let url, url.isFileURL,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxBytes else { return nil }
            let isImg = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            return DroppedFile(name: url.lastPathComponent, data: data, isImage: isImg)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { cont in
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in
                    cont.resume(returning: d)
                }
            }
            guard let data, data.count <= maxBytes else { return nil }
            return DroppedFile(name: "pasted-image.png", data: data, isImage: true)
        }
        return nil
    }

    /// Every item of a drop, loaded; empty when nothing usable was dragged.
    static func load(_ providers: [NSItemProvider]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for p in providers {
            if let f = await load(p) { files.append(f) }
        }
        #if canImport(AppKit)
        if files.count < providers.count { NSSound.beep() }   // too big / unreadable
        #endif
        return files
    }

    /// A readable host FILE for `token` (absolute path, `~`, or `file://`), or nil.
    static func hostFileURL(_ token: String) -> URL? {
        var path = token
        if path.hasPrefix("file://"), let u = URL(string: path) { path = u.path }
        else if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        guard path.hasPrefix("/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Host file paths a text field took on a drop — the field itself accepts
    /// the drag and pastes the path, before any drop handler around it sees
    /// anything. Each becomes a file and leaves the text. Lines and the whole
    /// text are tried first, so a path with spaces is found whole; then the
    /// whitespace-separated tokens.
    static func absorbHostPaths(in text: String) -> (text: String, files: [DroppedFile]) {
        var out = text
        var files: [DroppedFile] = []
        var candidates: [String] = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        candidates += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        candidates += text.split(whereSeparator: { " \n\t".contains($0) }).map(String.init)
        var seen: Set<String> = []
        for tok in candidates where !tok.isEmpty && !seen.contains(tok) {
            seen.insert(tok)
            guard out.contains(tok), let url = hostFileURL(tok),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxBytes else { continue }
            let isImg = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            files.append(DroppedFile(name: url.lastPathComponent, data: data, isImage: isImg))
            out = out.replacingOccurrences(of: tok, with: "")
        }
        guard !files.isEmpty else { return (text, []) }
        // Collapse what the removal left behind (a double space, a bare line).
        let cleaned = out.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ").joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (cleaned, files)
    }

    /// Wire form for the remote session API: {name, data (base64), isImage}.
    var wireDictionary: [String: Any] {
        ["name": name, "data": data.base64EncodedString(), "isImage": isImage]
    }

    init(name: String, data: Data, isImage: Bool) {
        self.name = name; self.data = data; self.isImage = isImage
    }

    init?(wire: [String: Any]) {
        guard let name = wire["name"] as? String,
              let b64 = wire["data"] as? String, let data = Data(base64Encoded: b64),
              data.count <= Self.maxBytes else { return nil }
        self.init(name: name, data: data, isImage: wire["isImage"] as? Bool ?? false)
    }
}

/// The files staged for the next send, as thumbnails with a remove badge.
struct PendingAttachmentChips: View {
    let files: [DroppedFile]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files.indices, id: \.self) { i in
                    chip(files[i], index: i)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func thumbnail(_ f: DroppedFile) -> some View {
        #if canImport(AppKit)
        if f.isImage, let ns = NSImage(data: f.data) {
            Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
        } else { placeholder(f) }
        #else
        if f.isImage, let ui = UIImage(data: f.data) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
        } else { placeholder(f) }
        #endif
    }

    private func placeholder(_ f: DroppedFile) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.text").font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(f.name).font(.system(size: 9.5)).lineLimit(1)
                .truncationMode(.middle).foregroundStyle(.secondary)
                .frame(maxWidth: 76)
        }
        .frame(width: 84, height: 64)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func chip(_ f: DroppedFile, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            thumbnail(f)
                .frame(width: 84, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15)))
            Button { onRemove(index) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help(NSLocalizedString("Remove attachment", comment: "chip"))
        }
    }
}

// MARK: - Session-first stage views (macOS)
//
// What the stage shows for the selected session:
//   • SessionHeaderView — the strip above every session surface: name, status,
//                         the (agent, workspace, folder) chips, Resume when the
//                         agent is gone, and — under the hood — the machine
//                         shortcuts (terminal is the surface itself; files,
//                         containers, machine one click each).
//   • SessionLaunchView — the chat surface while the session is on its way.
//   • SessionRestView   — an ended or asleep session: what happened, the last
//                         conversation when it can be read, and Resume.
//   • NewSessionView    — "New session": workspace, agent, where, opening
//                         message. Start.

struct SessionStageActions {
    var resume: (UUID) -> Void = { _ in }
    var close: (UUID) -> Void = { _ in }
    var rename: (UUID, String) -> Void = { _, _ in }
    /// Give the session the name agents reach it by ("@nick"; empty
    /// clears). Returns why not, or nil.
    var setNickname: (UUID, String) -> String? = { _, _ in nil }
    /// Resume and say this — wakes the machine and the agent if need be.
    var resumeWith: (UUID, String) -> Void = { _, _ in }
    var forget: (UUID) -> Void = { _ in }
    /// Put the conversation away: ends the agent, moves the row to the
    /// Archived fold. Still readable; resuming brings it back.
    var archive: (UUID) -> Void = { _ in }
    var unarchive: (UUID) -> Void = { _ in }
    /// Delete the session: ends the agent (asking first when it's running),
    /// drops the record and its transcript copy. The folder on the machine
    /// stays.
    var delete: (UUID) -> Void = { _ in }
    /// Start a new session in a git worktree branched off this session's
    /// folder: (session, worktree name — empty = from the message, agent,
    /// opening message, `git init` the folder first).
    var newWorktree: (UUID, NewBranchRequest) -> Void = { _, _ in }
    /// What the session's folder is, git-wise. nil: the machine can't be
    /// asked right now.
    var gitState: (UUID) async -> GitFolderState? = { _ in nil }

    // Branch sessions (worktrees)
    /// Merge the session's branch: (session, into — nil = where it came
    /// from, squash, remove the worktree once it has landed).
    var mergeBranch: (UUID, String?, Bool, Bool) -> Void = { _, _, _, _ in }
    /// Ask the session's agent to push the branch and open a pull request.
    var branchPullRequest: (UUID) -> Void = { _ in }
    /// Throw the branch away — checkout, branch and session (asks first).
    var discardBranch: (UUID) -> Void = { _ in }
    /// The machine's branches (worktrees), by profile id.
    var showBranches: (UUID) -> Void = { _ in }
    /// Say no to a merge an agent asked for.
    var declineMerge: (UUID) -> Void = { _ in }
    /// The session's changes in the review window (any session with a
    /// folder, not only a branch).
    var reviewBranch: (UUID) -> Void = { _ in }
    var represent: (UUID) -> Void = { _ in }
    /// The machine's dashboard (the header's machine name).
    var showMachine: (UUID) -> Void = { _ in }
    /// Put the Switchboard on stage — starting it first when there's none.
    var openSwitchboard: () -> Void = {}

    /// The machine's settings (the workspace editor), by profile id — from
    /// a session's right-click, its ⋯ menu, its sidebar row.
    var editMachine: (UUID) -> Void = { _ in }
    /// The session's Linux terminal (its tmux tab), by session id.
    var openLinux: (UUID) -> Void = { _ in }

    // Rooms
    /// Put a room on stage: its sessions' grid + its Switchboard.
    var openRoom: (UUID) -> Void = { _ in }
    /// Create a room (named), optionally moving a session into it.
    var newRoom: (String, UUID?) -> Void = { _, _ in }
    /// Move a session into a room, or out of any (nil).
    var moveToRoom: (UUID, UUID?) -> Void = { _, _ in }
    var renameRoom: (UUID, String) -> Void = { _, _ in }
    var setRoomColor: (UUID, String) -> Void = { _, _ in }
    /// Delete the room and every session in it (after a word).
    var deleteRoom: (UUID) -> Void = { _ in }
    /// Archive the room with all its sessions; bring it back.
    var archiveRoom: (UUID) -> Void = { _ in }
    var unarchiveRoom: (UUID) -> Void = { _ in }
    /// Dissolve the room: its sessions go back to the list.
    var ungroupRoom: (UUID) -> Void = { _ in }
    var newSessionInRoom: (UUID) -> Void = { _ in }
    /// One session dropped on another: into the other's room, or a new
    /// room holding both. (dragged, onto)
    var groupSessions: (UUID, UUID) -> Void = { _, _ in }
}

/// Name a new room, or rename one.
struct RoomNameSheet: View {
    let title: String
    let action: String
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, action: String, initial: String = "", onSet: @escaping (String) -> Void) {
        self.title = title
        self.action = action
        self.onSet = onSet
        _name = State(initialValue: initial)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(NSLocalizedString("A room groups sessions that work on the same thing. Its own Switchboard keeps track of them — and only them.", comment: "room sheet"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(NSLocalizedString("e.g. Payments v2", comment: "room sheet"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSet(trimmed)
        dismiss()
    }
}

// MARK: - Small chrome

struct SessionStatusPill: View {
    let bucket: SessionBucket
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(bucket.tint).frame(width: 7, height: 7)
            Text(bucket.title).font(.system(size: 12, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text("· " + detail).font(.system(size: 12)).opacity(0.85)
            }
        }
        .foregroundStyle(bucket.tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(bucket.tint.opacity(0.12)))
        .fixedSize()
    }
}

struct InfoChip<Leading: View>: View {
    let text: String
    var mono = false
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 5) {
            leading()
            Text(text)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

private struct WorkspaceSquare: View {
    let accentHex: String
    var size: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color(hex: accentHex)).frame(width: size, height: size)
    }
}

/// The folder as the user thinks of it: "~/clock", never /home/ubuntu/clock.
func prettyGuestPath(_ path: String) -> String {
    let home = "/home/ubuntu"
    if path == home || path == "~" || path.isEmpty { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: - Header

struct SessionHeaderView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let actions: SessionStageActions
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var worktreeSheet = false
    @State private var nicknameSheet = false

    private var session: AgentSession? { model.selectedSessionID.flatMap { store.session($0) } }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
    private func accentHex(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.accentHex ?? "#888888"
    }

    /// The machine behind the session: its settings, its terminal, its
    /// dashboard — a right-click on the session's name away.
    @ViewBuilder
    private func machineItems(_ s: AgentSession, gone: Bool) -> some View {
        if !workspaceName(s.profileID).isEmpty {
            Button {
                actions.editMachine(s.profileID)
            } label: {
                Label(String(format: NSLocalizedString("“%@” Settings…", comment: "session menu: machine settings"),
                             workspaceName(s.profileID)), systemImage: "gearshape")
            }
            if !gone, s.windowIndex != nil, !s.hasEnded {
                Button {
                    actions.openLinux(s.id)
                } label: {
                    Label(NSLocalizedString("Open in Linux Terminal", comment: "session menu"), systemImage: "terminal")
                }
            }
            Button {
                actions.showMachine(s.profileID)
            } label: {
                Label(NSLocalizedString("Machine Details", comment: "session menu"), systemImage: "cpu")
            }
            Button {
                actions.showBranches(s.profileID)
            } label: {
                Label(NSLocalizedString("Branches on This Machine…", comment: "session menu"), systemImage: "arrow.triangle.branch")
            }
        }
    }

    var body: some View {
        if let s = session {
            let bucket = SessionHome.bucket(for: s, in: model)
            let live = SessionHome.liveTabPosition(for: s, in: model)
            let gone = SessionHome.isGone(s, in: model)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if renaming {
                            TextField("", text: $draftTitle, onCommit: {
                                actions.rename(s.id, draftTitle); renaming = false
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))
                            .platformExitCommand { renaming = false }
                        } else {
                            Text(s.title)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .onTapGesture(count: 2) {
                                    guard !gone else { return }
                                    draftTitle = s.title; renaming = true
                                }
                                .help(gone ? "" : NSLocalizedString("Double-click to rename", comment: "session header"))
                                .contextMenu { machineItems(s, gone: gone) }
                        }
                        // One quiet line: @nick · status · agent · machine · folder.
                        HStack(spacing: 7) {
                            if let nick = s.nickname, !nick.isEmpty {
                                Text("@" + nick)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize()
                                    .help(NSLocalizedString("How agents and the composer reach this session", comment: "session header"))
                                metaDot
                            }
                            HStack(spacing: 5) {
                                if let st = SessionHome.dot(for: s, in: model) {
                                    AgentStatusDot(status: st).scaleEffect(1.15)   // breathes while working
                                } else {
                                    Circle().fill(bucket.tint).frame(width: 7, height: 7)
                                }
                                Text(SessionHome.goneReason(s, in: model) ?? statusText(s, bucket: bucket))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(bucket.tint)
                            }
                            .fixedSize()
                            metaDot
                            HStack(spacing: 5) {
                                AgentAvatar(tool: s.tool, size: 13)
                                Text(s.tool.displayName)
                            }
                            .fixedSize()
                            if !workspaceName(s.profileID).isEmpty {
                                metaDot
                                HStack(spacing: 5) {
                                    WorkspaceSquare(accentHex: accentHex(s.profileID), size: 7)
                                    Text(workspaceName(s.profileID))
                                }
                                .fixedSize()
                                .contentShape(Rectangle())
                                .onTapGesture { actions.showMachine(s.profileID) }
                                .contextMenu { machineItems(s, gone: gone) }
                                .help(NSLocalizedString("The machine this session runs on — click for its details, right-click for its settings", comment: "session header"))
                            }
                            metaDot
                            HStack(spacing: 4) {
                                Image(systemName: "folder").font(.system(size: 10.5))
                                Text(prettyGuestPath(s.cwd))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .truncationMode(.middle)
                            }
                            if let branch = s.worktreeBranch, !branch.isEmpty {
                                metaDot
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                                    Text(branch)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .truncationMode(.middle)
                                    if let sum = SessionHome.branchSummary(s), s.branchMerge == nil {
                                        Text(sum).foregroundStyle(.tertiary)
                                    }
                                }
                                .help(s.branchParent.map {
                                    String(format: NSLocalizedString("Its own git branch, off %@ — merge it back when it's ready", comment: "session header"), $0)
                                } ?? NSLocalizedString("A git worktree: its own branch, off the session it was started from", comment: "session header"))
                            }
                            if let url = s.cloneURL, !url.isEmpty {
                                metaDot
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle").font(.system(size: 10.5))
                                    Text(CodingTask.shortRepoURL(url))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .truncationMode(.middle)
                                }
                                .help(url)
                            }
                            #if os(macOS)
                            if let t = TranscriptSearchIndex.shared.tokens(s.id) {
                                metaDot
                                HStack(spacing: 4) {
                                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 10.5))
                                    Text(String(format: NSLocalizedString("%@ tokens", comment: "session header"),
                                                TranscriptSearchIndex.compact(t.total)))
                                        .monospacedDigit()
                                }
                                .help(String(format: NSLocalizedString("Input %@ · cached %@ · output %@", comment: "session header"),
                                             TranscriptSearchIndex.compact(t.input),
                                             TranscriptSearchIndex.compact(t.cached),
                                             TranscriptSearchIndex.compact(t.output)))
                            }
                            #endif
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !gone, SessionHome.isBranch(s) {
                        BranchMergeControl(session: s, actions: actions)
                    }
                    // Picking the conversation back up, said in words.
                    if !gone, bucket == .ended || bucket == .asleep {
                        Button {
                            actions.resume(s.id)
                        } label: {
                            Label(NSLocalizedString("Resume", comment: "session header"), systemImage: "play.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .foregroundStyle(.white)
                                .background(Capsule().fill(Color.accentColor.gradient))
                                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help(bucket == .asleep
                              ? NSLocalizedString("Wake up and continue where it left off", comment: "session header")
                              : NSLocalizedString("Resume where it left off", comment: "session header"))
                    }
                    Menu {
                        if !gone {
                            Button(NSLocalizedString("Rename…", comment: "session menu")) {
                                draftTitle = s.title; renaming = true
                            }
                            Button(NSLocalizedString("Nickname…", comment: "session menu")) { nicknameSheet = true }
                            if s.isArchived {
                                Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                            } else {
                                // Putting a live conversation away stops its agent
                                // — say so in the item itself.
                                Button(s.windowIndex != nil && !s.hasEnded
                                       ? NSLocalizedString("End & Archive", comment: "session menu")
                                       : NSLocalizedString("Archive", comment: "session menu")) {
                                    actions.archive(s.id)
                                }
                            }
                            if s.windowIndex != nil {
                                Button(NSLocalizedString("End session", comment: "session menu")) { actions.close(s.id) }
                            }
                            if SessionHome.hasFolder(s) {
                                Divider()
                                if !SessionHome.isBranch(s) {
                                    Button(NSLocalizedString("Review Changes", comment: "branch menu")) { actions.reviewBranch(s.id) }
                                }
                                Button(NSLocalizedString("New Branch…", comment: "session menu")) { worktreeSheet = true }
                            }
                            if SessionHome.isBranch(s) {
                                BranchMenuItems(session: s, actions: actions)
                            }
                        } else if s.isArchived {
                            Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                        }
                        Divider()
                        machineItems(s, gone: gone)
                        Divider()
                        Button(NSLocalizedString("Delete session", comment: "session menu"), role: .destructive) {
                            actions.delete(s.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .platformBorderlessMenuStyle()
                    .menuIndicator(.hidden)
                    .frame(width: 26)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
                if !gone, s.branchMerge?.phase == .requested {
                    Divider().opacity(0.6)
                    BranchMergeRequestBanner(session: s,
                                             asker: s.branchMerge?.askedBy.flatMap { store.session($0) },
                                             actions: actions)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: s.branchMerge?.phase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformWindowBackground)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
            .onChange(of: model.newBranchRequest) { _, req in
                guard req == s.id else { return }
                model.newBranchRequest = nil
                worktreeSheet = true
            }
            .onAppear {
                if model.newBranchRequest == s.id { model.newBranchRequest = nil; worktreeSheet = true }
            }
            .onChange(of: s.branchMerge?.phase) { _, _ in actions.represent(s.id) }
            .onChange(of: live) { _, _ in actions.represent(s.id) }
            .onChange(of: bucket) { _, _ in actions.represent(s.id) }
            .sheet(isPresented: $nicknameSheet) {
                NicknameSheet(session: s) { actions.setNickname(s.id, $0) }
            }
            .sheet(isPresented: $worktreeSheet) {
                NewWorktreeSheet(parent: s, gitState: actions.gitState) { req in
                    actions.newWorktree(s.id, req)
                }
            }
        }
    }

    private var metaDot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func statusText(_ s: AgentSession, bucket: SessionBucket) -> String {
        let detail: String?
        switch bucket {
        case .working: detail = s.isLaunching ? NSLocalizedString("starting", comment: "pill") : nil
        case .idle:    detail = SessionHome.elapsed(since: s.lastSeenAt)
        case .ended:   detail = SessionHome.elapsed(since: s.endedAt).map {
            // "3 min ago" — but never "just now ago".
            $0 == NSLocalizedString("just now", comment: "elapsed")
                ? $0 : String(format: NSLocalizedString("%@ ago", comment: "pill"), $0) }
        default:       detail = nil
        }
        let title = bucket == .ended && s.isArchived
            ? NSLocalizedString("Archived", comment: "session status") : bucket.title
        return detail.map { title + " · " + $0 } ?? title
    }
}

// MARK: - Branch sessions

/// What you do with a branch session's branch — the ⋯ menu's section and
/// the merge button's menu.
struct BranchMenuItems: View {
    let session: AgentSession
    let actions: SessionStageActions
    /// The merge itself is the button next to the menu.
    var includeMerge = true

    private var parent: String { session.branchParent ?? NSLocalizedString("its parent", comment: "branch menu") }

    var body: some View {
        let s = session
        let busy = s.branchMerge.map { $0.phase == .merging || $0.phase == .conflicts } ?? false
        Section(NSLocalizedString("Branch", comment: "branch menu")) {
            Button(NSLocalizedString("Review Changes", comment: "branch menu")) { actions.reviewBranch(s.id) }
            if includeMerge {
                Button(String(format: NSLocalizedString("Merge into %@", comment: "branch menu"), parent)) {
                    actions.mergeBranch(s.id, nil, false, true)
                }
                .disabled(busy)
            }
            Button(String(format: NSLocalizedString("Squash and Merge into %@", comment: "branch menu"), parent)) {
                actions.mergeBranch(s.id, nil, true, true)
            }
            .disabled(busy)
            Button(NSLocalizedString("Merge, Keep Working on the Branch", comment: "branch menu")) {
                actions.mergeBranch(s.id, nil, false, false)
            }
            .disabled(busy)
            Button(NSLocalizedString("Open a Pull Request", comment: "branch menu")) { actions.branchPullRequest(s.id) }
                .disabled(busy)
            Button(NSLocalizedString("Open Terminal Here", comment: "branch menu")) { actions.openLinux(s.id) }
            Divider()
            #if os(macOS)
            Button(NSLocalizedString("Discard Branch…", comment: "branch menu"), role: .destructive) {
                actions.discardBranch(s.id)   // asks first
            }
            #else
            // No alert from a closure here: the submenu is the second step.
            Menu(NSLocalizedString("Discard Branch…", comment: "branch menu")) {
                Button(NSLocalizedString("Discard — This Can't Be Undone", comment: "branch menu"), role: .destructive) {
                    actions.discardBranch(s.id)
                }
            }
            #endif
        }
    }
}

/// An agent asked to merge (worktree_merge): a full-width strip under the
/// header says who asks for what, and the user answers there.
struct BranchMergeRequestBanner: View {
    let session: AgentSession
    let asker: AgentSession?
    let actions: SessionStageActions

    var body: some View {
        let s = session
        let m = s.branchMerge
        let who: String = {
            if let a = asker, a.id != s.id {
                return String(format: NSLocalizedString("%@ in “%@”", comment: "merge request: agent in session"),
                              a.tool.displayName, a.title)
            }
            return s.tool.displayName
        }()
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.16))
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("%@ asks to merge %@ into %@", comment: "merge request banner"),
                            who, s.worktreeBranch ?? "", m?.target ?? ""))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([m?.squash == true ? NSLocalizedString("As one squashed commit", comment: "merge request banner") : nil,
                      SessionHome.branchSummary(s),
                      NSLocalizedString("The checkout is removed once it has landed.", comment: "merge request banner")]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(NSLocalizedString("Review Changes", comment: "branch menu")) { actions.reviewBranch(s.id) }
            Button(NSLocalizedString("Not Now", comment: "branch merge")) { actions.declineMerge(s.id) }
            Button {
                if let m { actions.mergeBranch(s.id, m.target, m.squash, m.removeAfter) }
            } label: {
                Text(m?.squash == true ? NSLocalizedString("Squash and Merge", comment: "branch merge")
                                       : NSLocalizedString("Merge", comment: "branch merge"))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.07))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

/// The header's merge control for a branch session: "Merge into main" (its
/// menu has the other ways), then the merge as it goes — merging, the agent
/// finishing it, merged.
struct BranchMergeControl: View {
    let session: AgentSession
    let actions: SessionStageActions

    var body: some View {
        let s = session
        let parent = s.branchParent ?? NSLocalizedString("parent", comment: "branch menu")
        if s.branchMerge?.phase == .requested {
            EmptyView()   // the banner under the header asks
        } else if let m = s.branchMerge, m.phase != .failed {
            HStack(spacing: 6) {
                switch m.phase {
                case .merged:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                default:
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                }
                Text(SessionHome.mergeLine(s) ?? "")
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(m.phase == .merged ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .help(m.phase == .conflicts
                  ? NSLocalizedString("It couldn't merge on its own (uncommitted work or a conflict), so the agent is committing and merging it — follow along in the chat", comment: "branch merge")
                  : "")
        } else if s.branchInfo?.isEmpty != true {
            Menu {
                BranchMenuItems(session: s, actions: actions, includeMerge: false)
            } label: {
                Label(s.branchMerge?.phase == .failed
                      ? NSLocalizedString("Retry Merge", comment: "branch merge")
                      : String(format: NSLocalizedString("Merge into %@", comment: "branch menu"), parent),
                      systemImage: "arrow.triangle.merge")
            } primaryAction: {
                actions.mergeBranch(s.id, nil, false, true)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .help(s.branchMerge?.detail
                  ?? String(format: NSLocalizedString("Merge this branch into %@, then remove its checkout. Uncommitted work or a conflict is handed to the agent to finish.", comment: "branch merge"), parent))
        }
    }
}

// MARK: - Launch surface

/// The chat before the agent's tab exists: the opening message as the first
/// turn, a live cue for what is happening, the composer parked.
struct SessionLaunchView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let sessionID: UUID
    let accent: Color
    let actions: SessionStageActions
    @State private var draft = ""

    private var session: AgentSession? { store.session(sessionID) }

    private func phase(for s: AgentSession) -> String {
        switch SessionHome.workspaceState(of: s, in: model) {
        case .off, .suspended: return NSLocalizedString("Waking up…", comment: "session launch")
        case .booting:         return NSLocalizedString("Almost there…", comment: "session launch")
        case .running:
            if s.cloneURL != nil {
                return String(format: NSLocalizedString("Checking out the repository and starting %@…", comment: "session launch"), s.tool.displayName)
            }
            return String(format: NSLocalizedString("Starting %@…", comment: "session launch"), s.tool.displayName)
        }
    }

    var body: some View {
        if let s = session {
            let live = SessionHome.liveTabPosition(for: s, in: model)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let msg = s.openingMessage, !msg.isEmpty {
                            TranscriptItemView(item: TranscriptItem(id: 0, kind: .userText(msg), timestamp: nil))
                        }
                        HStack(spacing: 10) {
                            AgentAvatar(tool: s.tool, size: 22)
                            ProgressView().controlSize(.small)
                            Text(phase(for: s))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                Divider().opacity(0.5)
                ChatComposer(
                    placeholder: String(format: NSLocalizedString("%@ is starting — you can talk to it in a moment…", comment: "session launch"), s.tool.displayName),
                    text: $draft, disabled: true, accent: accent, onSend: {})
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.platformTextBackground)
            .onChange(of: live) { _, new in if new != nil { actions.represent(s.id) } }
            .onChange(of: s.launchingSince) { _, _ in actions.represent(s.id) }
            .onChange(of: s.lastError) { _, _ in actions.represent(s.id) }
        }
    }
}

// MARK: - Ended / asleep surface

/// A session with no live tab: why, the last conversation when the
/// workspace can be read, and the way back in.
struct SessionRestView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let sessionID: UUID
    let accent: Color
    let actions: SessionStageActions
    /// Raw transcript of the agent's last conversation in the folder (nil
    /// when the workspace can't be read).
    let fetchTranscript: (AgentSession) async -> String?
    /// The conversation as last copied to this Mac — readable with the
    /// machine asleep.
    let cachedTranscript: (AgentSession) -> Data?
    /// Ask `fetchTranscript` for asleep sessions too (a fat client: the
    /// server answers from its own copy).
    var fetchWhenAsleep = false

    private enum Load { case idle, loading, loaded([TranscriptItem]), unavailable }
    @State private var load: Load = .idle
    /// Words to scroll to once the conversation is in.
    @State private var pendingFind: String?
    private var loadedCount: Int { if case .loaded(let items) = load { return items.count } else { return 0 } }

    private func applyFind(_ proxy: ScrollViewProxy) {
        guard let q = pendingFind, !q.isEmpty, case .loaded(let items) = load else { return }
        pendingFind = nil
        guard let hit = items.first(where: { item in
            switch item.kind {
            case .userText(let t), .assistantText(let t):
                return t.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            default: return false
            }
        }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(hit.id, anchor: .center) }
        }
    }
    @State private var draft = ""
    @State private var sending = false

    private var session: AgentSession? { store.session(sessionID) }

    var body: some View {
        if let s = session {
            let bucket = SessionHome.bucket(for: s, in: model)
            let live = SessionHome.liveTabPosition(for: s, in: model)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let err = s.lastError, !err.isEmpty { errorCard(err) }
                        transcript(s, bucket: bucket)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                // Opened from a search: to the first message with the words
                // (once the conversation has loaded).
                .onReceive(NotificationCenter.default.publisher(for: .bromureFindInChat)) { note in
                    pendingFind = note.object as? String
                    applyFind(proxy)
                }
                .onChange(of: loadedCount) { _, _ in applyFind(proxy) }
                }
                Divider().opacity(0.5)
                if let why = SessionHome.goneReason(s, in: model) {
                    // Nothing to send to: the machine or the folder is gone.
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: NSLocalizedString("%@. The conversation stays readable here; delete the session when you're done with it.", comment: "session rest gone"), why))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                } else {
                    // The way back in is the same as ever: say something.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: s.isArchived ? "archivebox"
                                  : bucket == .asleep ? "pause.circle" : "checkmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(s.isArchived
                                 ? NSLocalizedString("Archived. Your next message brings it back and carries on from here.", comment: "session rest")
                                 : bucket == .asleep
                                 ? NSLocalizedString("Paused. Your next message picks it up from here.", comment: "session rest")
                                 : NSLocalizedString("Finished. Your next message picks it up from here.", comment: "session rest"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        ChatComposer(
                            placeholder: String(format: NSLocalizedString("Message %@…", comment: "session rest composer"), s.tool.displayName),
                            text: $draft, busy: sending, accent: accent,
                            onSend: { send(s) })
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .background(Color.platformTextBackground)
            .task(id: s.id) { await loadTranscript(s, bucket: bucket) }
            .onChange(of: live) { _, new in if new != nil { actions.represent(s.id) } }
            .onChange(of: s.launchingSince) { _, _ in actions.represent(s.id) }
            .onChange(of: bucket) { _, _ in actions.represent(s.id) }
        }
    }

    private func send(_ s: AgentSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        draft = ""
        actions.resumeWith(s.id, text)
    }

    /// The local copy first — instantly, machine on or off — then the live
    /// file when the workspace can still be read.
    private func loadTranscript(_ s: AgentSession, bucket: SessionBucket) async {
        load = .loading
        let agent = s.tool.rawValue
        if let cached = cachedTranscript(s), !cached.isEmpty {
            let items = await Task.detached(priority: .userInitiated) {
                AgentTranscript.parse(cached, agent: agent)
            }.value
            load = items.isEmpty ? .unavailable : .loaded(items)
        }
        guard bucket == .ended || fetchWhenAsleep, let raw = await fetchTranscript(s), !raw.isEmpty else {
            if case .loading = load { load = .unavailable }
            return
        }
        let items = await Task.detached(priority: .userInitiated) {
            AgentTranscript.parse(Data(raw.utf8), agent: agent)
        }.value
        if !items.isEmpty { load = .loaded(items) } else if case .loading = load { load = .unavailable }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
    }

    @ViewBuilder
    private func transcript(_ s: AgentSession, bucket: SessionBucket) -> some View {
        switch load {
        case .idle, .unavailable:
            if let msg = s.openingMessage, !msg.isEmpty {
                TranscriptItemView(item: TranscriptItem(id: 0, kind: .userText(msg), timestamp: nil))
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Reading the conversation…", comment: "session rest"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .loaded(let items):
            LazyVStack(alignment: .leading, spacing: 14) {
                TranscriptRowsView(items: items)
            }
        }
    }
}

// MARK: - New session

/// "New session": the message is the hero — type, press Return, done. The
/// choices that shape it (agent, machine, where) ride along the bottom of
/// the composer as chips, pre-filled from last time, each one click away.
struct NewSessionView: View {
    let profiles: [Profile]
    let runningIDs: Set<UUID>
    /// Folders earlier sessions in a workspace ran in, most recent first.
    let recentFolders: (UUID) -> [String]
    let onStart: (AgentSessionRequest) -> Void
    let onCancel: () -> Void
    /// No machine yet: the new-workspace flow.
    let onNewMachine: () -> Void
    /// The subfolders of a folder on a machine ("~", "~/proj"), for the
    /// browser in the Where popover — nil when the machine can't be read
    /// right now. Absent on a host without the verb (a mirror of an older
    /// server): the browser stays hidden and the field is typed.
    let listFolders: ((UUID, String) async -> [String]?)?
    /// The agents a machine can start with credentials in hand, resolved
    /// from the global Models settings (or the workspace's override) plus the
    /// machine's own tools. nil (a mirror, which can't see the host's model
    /// settings) falls back to the machine's saved tool list.
    let readyTools: ((Profile) -> Set<Profile.Tool>)?
    /// The sessions the "@" palette offers for a message started in a
    /// workspace ("ask @seclio to…"), and naming one on the spot when it has
    /// no nickname yet. nil: no palette.
    let peerMentions: ((UUID) -> [PeerMention])?
    let assignNickname: ((UUID, String) -> Void)?
    /// The last few agent + machine + folder combinations, one click each.
    let recentStarts: [RecentStart]

    struct RecentStart: Hashable {
        let profileID: UUID
        let tool: Profile.Tool
        /// The folder ("" = a fresh one).
        let folder: String

        /// The newest distinct combinations among `sessions`.
        static func from(_ sessions: [AgentSession], profiles: [Profile], limit: Int = 3) -> [RecentStart] {
            var out: [RecentStart] = []
            for s in sessions.sorted(by: { $0.createdAt > $1.createdAt })
            where !s.isDeleted && !s.isSwitchboard && profiles.contains(where: { $0.id == s.profileID }) {
                let home = s.cwd.isEmpty || s.cwd == "~" || s.cwd == "/home/ubuntu"
                let r = RecentStart(profileID: s.profileID, tool: s.tool, folder: home ? "" : s.cwd)
                if !out.contains(r) { out.append(r) }
                if out.count == limit { break }
            }
            return out
        }
    }

    private enum Where: String, CaseIterable, Identifiable {
        case home, folder, repository
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home:       return NSLocalizedString("Fresh folder", comment: "new session where: a new empty folder made for the session")
            case .folder:     return NSLocalizedString("A folder", comment: "new session where")
            case .repository: return NSLocalizedString("A repository", comment: "new session where")
            }
        }
    }

    @State private var profileID: UUID
    @State private var tool: Profile.Tool
    @State private var place: Where
    @State private var folder: String
    @State private var repoURL: String = ""
    @State private var derivedFolder: String?
    @State private var message = ""
    /// The greeting, one of a rotation: picked when the screen comes up
    /// and kept while it's on show. Each is its own key, so every
    /// language phrases it in its own way.
    @State private var greeting = NewSessionView.greetings.randomElement() ?? ""
    static let greetings: [String] = [
        NSLocalizedString("What can I help you with?", comment: "new session greeting"),
        NSLocalizedString("What are we building today?", comment: "new session greeting"),
        NSLocalizedString("Let's build something.", comment: "new session greeting"),
        NSLocalizedString("What's on your mind?", comment: "new session greeting"),
        NSLocalizedString("Where should we start?", comment: "new session greeting"),
        NSLocalizedString("What would you like to make?", comment: "new session greeting"),
        NSLocalizedString("Ready when you are.", comment: "new session greeting"),
        NSLocalizedString("What's the plan?", comment: "new session greeting"),
        NSLocalizedString("Let's get to work.", comment: "new session greeting"),
        NSLocalizedString("What shall we tackle first?", comment: "new session greeting"),
        NSLocalizedString("Tell me what you need.", comment: "new session greeting"),
        NSLocalizedString("What are we working on?", comment: "new session greeting"),
        NSLocalizedString("Let's make something great.", comment: "new session greeting"),
        NSLocalizedString("What needs doing?", comment: "new session greeting"),
        NSLocalizedString("What's next?", comment: "new session greeting"),
        NSLocalizedString("Got something in mind?", comment: "new session greeting"),
        NSLocalizedString("Let's ship something.", comment: "new session greeting"),
        NSLocalizedString("What should we fix today?", comment: "new session greeting"),
        NSLocalizedString("Where do we begin?", comment: "new session greeting"),
        NSLocalizedString("What can we improve?", comment: "new session greeting"),
        NSLocalizedString("Let's write some code.", comment: "new session greeting"),
        NSLocalizedString("What are you working on?", comment: "new session greeting"),
        NSLocalizedString("What's the task?", comment: "new session greeting"),
        NSLocalizedString("Let's dig in.", comment: "new session greeting"),
        NSLocalizedString("What do you want to build?", comment: "new session greeting"),
        NSLocalizedString("Let's solve something.", comment: "new session greeting"),
        NSLocalizedString("What are we shipping today?", comment: "new session greeting"),
        NSLocalizedString("Ready to build?", comment: "new session greeting"),
        NSLocalizedString("What's the idea?", comment: "new session greeting"),
        NSLocalizedString("Let's start something new.", comment: "new session greeting"),
    ]
    @State private var machinePopover = false
    @State private var agentPopover = false
    @State private var wherePopover = false
    /// Files dropped on the composer: staged in the machine when the
    /// session starts and handed to the agent with the opening message.
    @State private var attachments: [DroppedFile] = []
    @State private var dropTargeted = false
    /// The folder picker sheet ("Choose…" in the Where popover).
    @State private var folderPicker = false
    @FocusState private var messageFocused: Bool
    /// Keyboard highlight in the "@" palette.
    @State private var mentionIndex = 0
    #if os(macOS)
    @State private var editorHeight: CGFloat = 24
    @State private var editorFocused = false
    #endif

    static let lastProfileKey = "sessions.lastProfileID"
    static let lastToolKey = "sessions.lastTool"

    /// The agent last started on a machine (nil: never).
    static func rememberedTool(for machine: UUID) -> Profile.Tool? {
        UserDefaults.standard.string(forKey: lastToolKey + "." + machine.uuidString).flatMap(Profile.Tool.init(rawValue:))
    }

    /// A wide stage gets a wide margin; a phone keeps every point.
    private static var sidePadding: CGFloat {
        #if os(macOS)
        return 32
        #else
        return 16
        #endif
    }

    private static var footnote: String {
        #if os(macOS)
        return NSLocalizedString("Runs in an isolated machine of its own. Nothing on your Mac is touched.", comment: "new session footnote")
        #else
        return NSLocalizedString("Runs in an isolated machine of its own on your Mac, not on this device.", comment: "new session footnote (mobile)")
        #endif
    }

    init(profiles: [Profile], runningIDs: Set<UUID>, recentFolders: @escaping (UUID) -> [String],
         onStart: @escaping (AgentSessionRequest) -> Void,
         onCancel: @escaping () -> Void,
         onNewMachine: @escaping () -> Void = {},
         listFolders: ((UUID, String) async -> [String]?)? = nil,
         readyTools: ((Profile) -> Set<Profile.Tool>)? = nil,
         peerMentions: ((UUID) -> [PeerMention])? = nil,
         assignNickname: ((UUID, String) -> Void)? = nil,
         recentStarts: [RecentStart] = []) {
        self.recentStarts = recentStarts
        self.profiles = profiles
        self.runningIDs = runningIDs
        self.recentFolders = recentFolders
        self.onStart = onStart
        self.onCancel = onCancel
        self.onNewMachine = onNewMachine
        self.listFolders = listFolders
        self.readyTools = readyTools
        self.peerMentions = peerMentions
        self.assignNickname = assignNickname
        let remembered = UserDefaults.standard.string(forKey: Self.lastProfileKey)
            .flatMap { UUID(uuidString: $0) }
        let pid = remembered.flatMap { id in profiles.first { $0.id == id }?.id }
            ?? profiles.first { runningIDs.contains($0.id) }?.id
            ?? profiles.first?.id
            ?? UUID()
        let profile = profiles.first { $0.id == pid }
        // The agent last used on THIS machine, else the machine's own agent,
        // else the last one used anywhere.
        let rememberedTool = Self.rememberedTool(for: pid)
        _profileID = State(initialValue: pid)
        // Any agent can be picked on any machine (see `configuredTools`), so
        // the last choice stands whatever the machine has set up.
        _tool = State(initialValue: rememberedTool ?? profile?.tool
                      ?? UserDefaults.standard.string(forKey: Self.lastToolKey).flatMap(Profile.Tool.init(rawValue:))
                      ?? .claude)
        _place = State(initialValue: .home)
        _folder = State(initialValue: "")
    }

    private var selectedProfile: Profile? { profiles.first { $0.id == profileID } }
    /// Agents the machine already holds credentials for. Every agent is
    /// startable regardless: the images ship all of them, and one without
    /// credentials shows its sign-in on first start, which the chat turns
    /// into a sign-in card the host completes (`beginProxySignIn`).
    private var configuredTools: [Profile.Tool] {
        guard let p = selectedProfile else { return [] }
        if let readyTools { return Array(readyTools(p)) }
        return p.allToolSpecs.map(\.tool)
    }

    private var effectiveFolder: String {
        switch place {
        case .home: return "~"
        case .folder:
            let f = folder.trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? "~" : f
        case .repository:
            let f = folder.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty { return f }
            return CodingTask.repoName(fromCloneURL: repoURL).map { "~/" + $0 } ?? ""
        }
    }

    private var canStart: Bool {
        guard selectedProfile != nil else { return false }
        if place == .repository {
            return !repoURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !effectiveFolder.isEmpty && effectiveFolder != "~"
        }
        return true
    }

    private var whereLabel: String {
        switch place {
        case .home:
            return NSLocalizedString("Fresh folder", comment: "new session where: a new empty folder made for the session")
        case .folder:
            let f = folder.trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? NSLocalizedString("A folder", comment: "new session where") : f
        case .repository:
            let u = repoURL.trimmingCharacters(in: .whitespaces)
            return u.isEmpty ? NSLocalizedString("A repository", comment: "new session where") : CodingTask.shortRepoURL(u)
        }
    }

    private var placeholderText: String {
        String(format: NSLocalizedString("Ask for anything — or just press Return to open %@.", comment: "new session message"),
               tool.displayName)
    }

    private func start() {
        guard canStart else { return }
        UserDefaults.standard.set(profileID.uuidString, forKey: Self.lastProfileKey)
        UserDefaults.standard.set(tool.rawValue, forKey: Self.lastToolKey)
        UserDefaults.standard.set(tool.rawValue, forKey: Self.lastToolKey + "." + profileID.uuidString)
        onStart(AgentSessionRequest(
            profileID: profileID, tool: tool, cwd: effectiveFolder,
            cloneURL: place == .repository ? repoURL.trimmingCharacters(in: .whitespaces) : nil,
            openingMessage: message, attachments: attachments))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            let files = await DroppedFile.load(providers)
            if !files.isEmpty { attachments.append(contentsOf: files) }
        }
        return true
    }

    /// The one question, then the composer — a new chat, not a form. The
    /// session is named after the first words typed and renamed by the agent
    /// once it has understood the task.
    var body: some View {
        content
            // Another machine: its own agent (the one last used there, else
            // the one it's set up for).
            .onChange(of: profileID) { _, pid in
                if let t = Self.rememberedTool(for: pid) ?? profiles.first(where: { $0.id == pid })?.tool { tool = t }
            }
    }

    private var content: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: max(24, geo.size.height * 0.24))
                    Text(profiles.isEmpty
                         ? NSLocalizedString("Let's set up a machine first.", comment: "new session greeting")
                         : greeting)
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.3)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.bottom, 2)
                    if profiles.isEmpty {
                        firstMachineCard
                    } else {
                        #if os(macOS)
                        if !mentionRows.isEmpty { mentionPalette }
                        #endif
                        composer
                            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { handleDrop($0) }
                            .overlay {
                                if dropTargeted {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.06)))
                                        .overlay(
                                            Label(NSLocalizedString("Drop to attach", comment: "drop hint"),
                                                  systemImage: "arrow.down.doc")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(Color.accentColor))
                                        .allowsHitTesting(false)
                                }
                            }
                        if recentStarts.count > 1 { recentStartsRow }
                        recentRow
                        Text(Self.footnote)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
                .padding(.horizontal, Self.sidePadding)
            }
        }
        .background(Color.platformWindowBackground)
        .platformExitCommand(onCancel)
        .sheet(isPresented: $folderPicker) {
            GuestFolderPickerView(
                profileID: profileID,
                machineName: selectedProfile?.name ?? "",
                start: folder.trimmingCharacters(in: .whitespaces),
                listFolders: listFolders ?? { _, _ in nil },
                onPick: { picked in
                    place = .folder
                    folder = picked
                })
        }
        .onAppear {
            messageFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { messageFocused = true }
        }
        .onChange(of: repoURL) { _, new in
            guard let name = CodingTask.repoName(fromCloneURL: new) else { return }
            let f = folder.trimmingCharacters(in: .whitespaces)
            if f.isEmpty || f == derivedFolder { folder = "~/" + name; derivedFolder = folder }
        }
    }

    // MARK: The composer

    /// macOS: the chat's own text view, so the "@" palette gets the arrow,
    /// Tab, Return and Escape keys before the field acts on them (Return
    /// otherwise starts the session). Elsewhere a plain field.
    private var fieldFocused: Bool {
        #if os(macOS)
        editorFocused
        #else
        messageFocused
        #endif
    }

    @ViewBuilder private var messageField: some View {
        #if os(macOS)
        ComposerTextView(text: $message, placeholder: placeholderText,
                         font: .systemFont(ofSize: 15), lineSpacing: 4, maxLines: 14,
                         autofocus: true, height: $editorHeight, focused: $editorFocused,
                         onKey: { handleMentionKey($0) }, onSubmit: start)
            .frame(maxWidth: .infinity)
            .frame(height: max(editorHeight, 66))   // three lines, as the field had
        #else
        TextField(placeholderText, text: $message, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .lineSpacing(4)
            .lineLimit(3...14)
            .focused($messageFocused)
            .onSubmit(start)
        #endif
    }

    #if os(macOS)
    /// The sessions the "@…" being typed could mean, for the message's
    /// workspace (a new session is nobody yet, so none is left out).
    private var mentionRows: [SlashCommand] {
        guard let peerMentions, let q = PeerMentionCompletion.query(in: message) else { return [] }
        return PeerMentionCompletion.paletteRows(q, in: peerMentions(profileID))
    }

    private func completeMention(_ c: SlashCommand) {
        // A session without a nickname gets the proposed one now, so the
        // "@name" typed is one the agent can resolve.
        if let peer = peerMentions?(profileID).first(where: { $0.nick == c.name }), !peer.assigned {
            assignNickname?(peer.sessionID, peer.nick)
        }
        message = PeerMentionCompletion.complete(message, with: c.name)
        mentionIndex = 0
    }

    /// The palette's keys, before the field acts on them. False = the field's own.
    private func handleMentionKey(_ key: ComposerKey) -> Bool {
        let rows = mentionRows
        guard !rows.isEmpty else { return false }
        switch key {
        case .up: mentionIndex = max(0, mentionIndex - 1)
        case .down: mentionIndex = min(rows.count - 1, mentionIndex + 1)
        case .tab, .enter: completeMention(rows[min(mentionIndex, rows.count - 1)])
        case .escape: message = PeerMentionCompletion.dismiss(message); mentionIndex = 0
        }
        return true
    }

    private var mentionPalette: some View {
        SlashCommandPalette(
            commands: mentionRows,
            agentName: NSLocalizedString("sessions you can ask", comment: "mention palette"),
            highlighted: mentionIndex,
            onPick: { completeMention($0) },
            onHover: { mentionIndex = $0 },
            prefix: "@",
            title: NSLocalizedString("Sessions", comment: "mention palette"))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    #endif

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attachments.isEmpty {
                PendingAttachmentChips(files: attachments) { i in
                    if attachments.indices.contains(i) { attachments.remove(at: i) }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
            messageField
                // A drop that lands ON the field pastes the file's host path
                // (the field takes the drag first): turn it into a chip.
                .onChange(of: message) { _, text in
                    mentionIndex = 0
                    let (rest, files) = DroppedFile.absorbHostPaths(in: text)
                    guard !files.isEmpty else { return }
                    attachments.append(contentsOf: files)
                    message = rest
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            HStack(spacing: 8) {
                ChipStrip {
                ComposerChip(help: NSLocalizedString("The agent that runs this session", comment: "new session chip"),
                             action: { agentPopover.toggle() }) {
                    AgentAvatar(tool: tool, size: 16)
                    Text(tool.displayName)
                }
                .popover(isPresented: $agentPopover, arrowEdge: .bottom) { agentList.platformCompactPopover() }

                ComposerChip(help: runningIDs.contains(profileID)
                                ? NSLocalizedString("The machine it runs on — running", comment: "new session chip")
                                : NSLocalizedString("The machine it runs on — asleep, wakes up when you start", comment: "new session chip"),
                             action: { machinePopover.toggle() }) {
                    WorkspaceSquare(accentHex: selectedProfile?.color.hexInUI ?? "#888888", size: 9)
                    Text(selectedProfile?.name ?? NSLocalizedString("Machine", comment: "new session"))
                    if runningIDs.contains(profileID) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                }
                .popover(isPresented: $machinePopover, arrowEdge: .bottom) { machineList.platformCompactPopover() }

                ComposerChip(help: NSLocalizedString("Where it works: a fresh folder, one of yours, or a repository to check out", comment: "new session chip"),
                             action: { wherePopover.toggle() }) {
                    Image(systemName: place == .repository ? "arrow.down.circle" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    // Hugs its text, truncating only past 220pt.
                    Text(whereLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .popover(isPresented: $wherePopover, arrowEdge: .bottom) { whereEditor.platformCompactPopover() }
                }

                Spacer(minLength: 8)
                #if os(macOS)
                Text(NSLocalizedString("⏎ start   ⌥⏎ newline", comment: "new session hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                #endif
                Button(action: start) {
                    HStack(spacing: 6) {
                        // Touch screens get the familiar arrow-only send pill;
                        // the label would cost the third chip its room.
                        #if os(macOS)
                        Text(NSLocalizedString("Start", comment: "new session"))
                            .font(.system(size: 12.5, weight: .semibold))
                        #endif
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule().fill(canStart ? Color.accentColor : Color.secondary.opacity(0.28)))
                }
                .fixedSize()   // never squeezed by the chip strip beside it
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Start", comment: "new session"))
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .help(NSLocalizedString("Start the session (⏎)", comment: "new session"))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(fieldFocused ? Color.accentColor.opacity(0.6) : Color.acHairline,
                          lineWidth: fieldFocused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: fieldFocused)
    }

    /// Folders earlier sessions on this machine ran in — one click to work
    /// there again.
    /// "Pick up where you were": agent, machine and folder in one click.
    private var recentStartsRow: some View {
        HStack(spacing: 8) {
            ForEach(recentStarts, id: \.self) { r in
                let name = profiles.first { $0.id == r.profileID }?.name ?? ""
                let picked = profileID == r.profileID && tool == r.tool
                    && (r.folder.isEmpty ? place == .home : (place == .folder && folder == r.folder))
                Button {
                    profileID = r.profileID
                    tool = r.tool
                    if r.folder.isEmpty { place = .home; folder = "" } else { place = .folder; folder = r.folder }
                } label: {
                    HStack(spacing: 7) {
                        AgentAvatar(tool: r.tool, size: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                            Text(r.folder.isEmpty ? NSLocalizedString("Fresh folder", comment: "new session where: a new empty folder made for the session")
                                                  : (r.folder as NSString).lastPathComponent)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 190, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(picked ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(picked ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .help(String(format: NSLocalizedString("%@ on %@, in %@", comment: "new session recent start"),
                             r.tool.displayName, name,
                             r.folder.isEmpty ? NSLocalizedString("Fresh folder", comment: "new session where: a new empty folder made for the session") : r.folder))
            }
        }
    }

    @ViewBuilder
    private var recentRow: some View {
        let recent = Array(recentFolders(profileID).prefix(4))
        if !recent.isEmpty {
            ChipStrip {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(NSLocalizedString("Recent", comment: "new session recent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.trailing, 2)
                ForEach(recent, id: \.self) { p in
                    let picked = place == .folder && folder == p
                    Button {
                        if picked { place = .home; folder = "" } else { place = .folder; folder = p }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text(p)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .frame(maxWidth: 200)
                        .background(Capsule().fill(picked ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(picked
                          ? NSLocalizedString("Working in this folder — click to start in a new folder instead", comment: "new session recent")
                          : NSLocalizedString("Work in this folder again", comment: "new session recent"))
                }
                Spacer(minLength: 0)
            }
            }
        }
    }

    /// Nothing to run on yet.
    private var firstMachineCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Set up your first machine", comment: "new session first machine"))
                    .font(.system(size: 15, weight: .semibold))
                Text(NSLocalizedString("An isolated Linux machine with the agents and keys you choose. Sessions run inside it — nothing on your Mac is touched.", comment: "new session first machine"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onNewMachine) {
                    Label(NSLocalizedString("Create a machine", comment: "new session first machine"), systemImage: "plus")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.acHairline))
    }

    // MARK: Agent

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Profile.Tool.allCases, id: \.self) { t in
                let configured = configuredTools.contains(t)
                let selected = t == tool
                Button {
                    tool = t; agentPopover = false
                } label: {
                    HStack(spacing: 10) {
                        AgentAvatar(tool: t, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.displayName)
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            Text(configured
                                 ? NSLocalizedString("Ready", comment: "new session agent")
                                 : t == .omp
                                 ? NSLocalizedString("Pick a model provider when it starts", comment: "new session agent")
                                 : NSLocalizedString("Sign in when it starts", comment: "new session agent"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    // MARK: Machine

    private var machineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(profiles) { p in
                    let running = runningIDs.contains(p.id)
                    Button {
                        profileID = p.id; machinePopover = false
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(hex: p.color.hexInUI).opacity(running ? 0.9 : 0.35))
                                .frame(width: 26, height: 26)
                                .overlay(Image(systemName: "desktopcomputer")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 13, weight: p.id == profileID ? .semibold : .medium))
                                Text(p.allToolSpecs.map { $0.tool.displayName }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if p.id == profileID {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            } else if running {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(p.id == profileID ? Color.accentColor.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // A machine that doesn't exist yet: the editor opens, and the
                // saved machine comes back selected here (the caller remembers
                // it as the last-used one before the screen is rebuilt).
                Divider().padding(.vertical, 4)
                Button {
                    machinePopover = false
                    onNewMachine()
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 26, height: 26)
                            .overlay(Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary))
                        Text(NSLocalizedString("New machine…", comment: "new session machine picker"))
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
        .frame(width: 320)
        .frame(maxHeight: min(440, CGFloat(profiles.count) * 46 + 12 + 50))
    }

    // MARK: Where

    private var whereEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $place) {
                ForEach(Where.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch place {
            case .home:
                Text(NSLocalizedString("A fresh folder of its own in the machine's home, named after your message.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .folder:
                HStack(spacing: 8) {
                    pathField(prompt: "~/my-project")
                    if listFolders != nil {
                        // The panel comes up once the popover is out of the way.
                        Button(NSLocalizedString("Choose…", comment: "new session where")) {
                            wherePopover = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { folderPicker = true }
                        }
                        .fixedSize()
                    }
                    let recent = recentFolders(profileID).filter { $0 != folder }
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { p in Button(p) { folder = p } }
                        } label: {
                            Label(NSLocalizedString("Recent", comment: "new session where"), systemImage: "clock")
                        }
                        .platformBorderlessMenuStyle()
                        .fixedSize()
                    }
                }
                Text(NSLocalizedString("A folder inside the machine — created if it doesn't exist yet.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .repository:
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("https://github.com/org/repo.git", text: $repoURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
                HStack(spacing: 8) {
                    Text(NSLocalizedString("into", comment: "new session where")).font(.system(size: 12)).foregroundStyle(.secondary)
                    pathField(prompt: "~/repo")
                }
                Text(NSLocalizedString("Checked out with the machine's git credentials or SSH key. If the folder already holds the repository, it's used as is.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("Done", comment: "")) { wherePopover = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .platformPopoverWidth(420)
    }

    private func pathField(prompt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $folder)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
    }

    // MARK: Guest paths

    /// "~/a/b" → "~/a", "~/a" → "~", "/x/y" → "/x", "/x" → "/", "a" → "~".
    static func parentFolder(of path: String) -> String {
        if path == "~" || path == "/" { return path }
        guard let cut = path.lastIndex(of: "/") else { return "~" }
        let parent = String(path[..<cut])
        return parent.isEmpty ? "/" : parent
    }

    /// "~" + "proj" → "~/proj"; "/" + "tmp" → "/tmp".
    static func childFolder(of path: String, named name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    /// The path and its ancestors up to the home (or the root), nearest
    /// first: "~/a/b" → ["~/a/b", "~/a", "~"].
    static func ancestors(of path: String) -> [String] {
        var out = [path]
        var p = path
        while true {
            let parent = parentFolder(of: p)
            if parent == p { break }
            out.append(parent)
            p = parent
        }
        return out
    }
}

/// "Nickname…": the name other agents (and the composer's @ palette) reach
/// this session by. Letters, digits, dots, dashes, underscores; unique on
/// this host. Empty clears it.
struct NicknameSheet: View {
    let session: AgentSession
    /// Returns why the name was refused, or nil once it's set.
    let onSet: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(session: AgentSession, onSet: @escaping (String) -> String?) {
        self.session = session
        self.onSet = onSet
        _name = State(initialValue: session.nickname ?? "")
    }

    private var normalized: String? { DelegationNotice.normalizeNickname(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Nickname", comment: "nickname sheet"))
                    .font(.system(size: 15, weight: .semibold))
                Text(String(format: NSLocalizedString("How other agents reach “%@”: they ask it with request(to: \"@name\"), and you can write @name in any composer. Letters, digits, dots, dashes and underscores.", comment: "nickname sheet"),
                            session.title))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("@")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(NSLocalizedString("e.g. seclio", comment: "nickname sheet"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused)
                    .onSubmit { save() }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let n = normalized, n != name.trimmingCharacters(in: .whitespaces) {
                Text(String(format: NSLocalizedString("Will be @%@", comment: "nickname sheet"), n))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack {
                if session.nickname != nil {
                    Button(NSLocalizedString("Clear", comment: "nickname sheet")) {
                        _ = onSet(""); dismiss()
                    }
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Set", comment: "nickname sheet")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func save() {
        guard normalized != nil else { return }
        if let why = onSet(name) { error = why } else { dismiss() }
    }
}

// MARK: - New branch (worktree)

/// "New branch": a session of its own on a git worktree off this session's
/// folder. The ask comes first (the name defaults to it); the folder is
/// checked as the sheet opens, and one that isn't a repository yet gets an
/// offer to become one. The guest branches the folder at its current commit
/// into ~/.bromure/worktrees/<repo>/<slug> (branch wt/<slug>).
struct NewWorktreeSheet: View {
    let parent: AgentSession
    let gitState: (UUID) async -> GitFolderState?
    let onCreate: (NewBranchRequest) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Repo: Equatable { case checking, repo(String?), notRepo, noCommits, unknown }
    /// Branches it can start from (the current one first) and what the
    /// repository's .worktreeinclude copies in.
    @State private var branches: [String] = []
    @State private var includes: [String] = []
    /// nil = the folder's current commit.
    @State private var base: String?

    @State private var name = ""
    @State private var tool: Profile.Tool
    @State private var message = ""
    @State private var repo: Repo = .checking
    @State private var initGit = true
    @FocusState private var messageFocused: Bool

    init(parent: AgentSession,
         gitState: @escaping (UUID) async -> GitFolderState?,
         onCreate: @escaping (NewBranchRequest) -> Void) {
        self.parent = parent
        self.gitState = gitState
        self.onCreate = onCreate
        _tool = State(initialValue: parent.tool)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the session (and its branch) will be called.
    private var effectiveName: String {
        if !trimmedName.isEmpty { return trimmedName }
        if !trimmedMessage.isEmpty { return AgentSession.title(fromMessage: trimmedMessage) }
        return ""
    }
    private var folder: String { prettyGuestPath(SessionHome.guestPath(parent.cwd)) }
    private var canCreate: Bool {
        guard !effectiveName.isEmpty else { return false }
        switch repo {
        case .notRepo: return initGit
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("New branch", comment: "new worktree"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(String(format: NSLocalizedString("A session of its own, on a copy of %@ with its own git branch. Your work in “%@” isn't touched; merge it back when it's ready.", comment: "new worktree"),
                                folder, parent.title))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("What should it do?", comment: "new worktree"))
                    .font(.system(size: 12, weight: .medium))
                TextField(NSLocalizedString("e.g. Try moving the session cache to SQLite", comment: "new worktree"),
                          text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    .focused($messageFocused)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Name", comment: "new worktree"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(trimmedMessage.isEmpty
                              ? NSLocalizedString("e.g. Session cache in SQLite", comment: "new worktree")
                              : AgentSession.title(fromMessage: trimmedMessage),
                              text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Agent", comment: "new worktree"))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $tool) {
                        ForEach(Profile.Tool.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            repoStatus

            HStack(spacing: 10) {
                if !effectiveName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text("wt/" + AgentSession.worktreeSlug(effectiveName))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.secondary)
                    .help(NSLocalizedString("The git branch this session works on", comment: "new worktree"))
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Start", comment: "new worktree")) {
                    onCreate(NewBranchRequest(
                        name: trimmedName, tool: tool,
                        message: trimmedMessage.isEmpty ? nil : trimmedMessage,
                        initGit: repo == .notRepo || repo == .unknown ? initGit : false,
                        base: base))
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 480)
        #endif
        .onAppear { messageFocused = true }
        .task {
            // A machine that just woke can take a few seconds to answer.
            for attempt in 0..<8 {
                let st = await gitState(parent.id)
                guard !Task.isCancelled else { return }
                let next: Repo = st.map {
                    switch $0.kind {
                    case .repo: return .repo($0.branch)
                    case .noCommits: return .noCommits
                    case .notRepo: return .notRepo
                    }
                } ?? .unknown
                if let st {
                    branches = st.branches
                    includes = st.includes
                }
                if next != repo { withAnimation(.easeOut(duration: 0.15)) { repo = next } }
                if st != nil || attempt == 7 { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// One line on where it branches from — or what's missing.
    @ViewBuilder private var repoStatus: some View {
        switch repo {
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(String(format: NSLocalizedString("Checking %@…", comment: "new worktree"), folder))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        case .repo(let branch):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(NSLocalizedString("Start from", comment: "new worktree"))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $base) {
                        Text(branch.map { String(format: NSLocalizedString("%@ (current)", comment: "new worktree base"), $0) }
                             ?? NSLocalizedString("The current commit", comment: "new worktree base"))
                            .tag(String?.none)
                        let others = branches.filter { $0 != branch }
                        if !others.isEmpty {
                            Divider()
                            ForEach(others, id: \.self) { b in Text(b).tag(String?.some(b)) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                Label {
                    Text(base == nil
                         ? NSLocalizedString("At its latest commit — uncommitted changes stay behind. Merges back into it.", comment: "new worktree")
                         : String(format: NSLocalizedString("At %@'s latest commit, and it merges back into %@.", comment: "new worktree"), base ?? "", base ?? ""))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                if !includes.isEmpty {
                    Label {
                        Text(String(format: NSLocalizedString("Also copies in, as .worktreeinclude says: %@", comment: "new worktree"),
                                    includes.prefix(6).joined(separator: ", ") + (includes.count > 6 ? "…" : "")))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help(includes.joined(separator: "\n"))
                }
            }
        case .noCommits:
            Label {
                Text(NSLocalizedString("The repository has no commit yet, so the branch starts from an empty first commit. Files in the folder stay behind.", comment: "new worktree"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        case .notRepo:
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(String(format: NSLocalizedString("%@ isn't a git repository yet, and a branch needs one.", comment: "new worktree"), folder))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Toggle(isOn: $initGit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Make it one (git init)", comment: "new worktree"))
                        Text(NSLocalizedString("Everything in the folder goes into a first commit, which the branch starts from.", comment: "new worktree"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5))
        case .unknown:
            VStack(alignment: .leading, spacing: 6) {
                Label(NSLocalizedString("The machine isn't running — the folder is checked once it starts.", comment: "new worktree"),
                      systemImage: "moon.zzz")
                Toggle(NSLocalizedString("If it isn't a git repository, make it one", comment: "new worktree"), isOn: $initGit)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Folder picker

/// The panel behind "Choose…" in the new-session screen: a file-panel
/// look over a machine's folders — the folder on show and its ancestors
/// in a popup on top, its subfolders below, Cancel and Choose at the
/// bottom. On the Mac a click selects and a double-click steps in, like
/// an Open panel choosing directories; on a phone a tap steps in and
/// Choose takes the folder on show. Read from the machine live when it
/// runs, from its home image when it's off.
struct GuestFolderPickerView: View {
    let profileID: UUID
    let machineName: String
    /// The path to open on ("" = the home).
    let start: String
    let listFolders: (UUID, String) async -> [String]?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var path = "~"
    @State private var entries: [String]?
    @State private var unavailable = false
    @State private var selected: String?

    /// What Choose takes: the selected subfolder, else the folder on show.
    private var chosen: String {
        selected.map { NewSessionView.childFolder(of: path, named: $0) } ?? path
    }
    private var canChoose: Bool { chosen != "~" && chosen != "/" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 560, height: 440)
        #endif
        .onAppear { path = start.isEmpty ? "~" : start }
        .task(id: path) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                go(NewSessionView.parentFolder(of: path))
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .disabled(path == "~" || path == "/")
            .help(NSLocalizedString("Up one folder", comment: "folder picker"))
            // The folder on show and the way back up, like the panel's path popup.
            Menu {
                ForEach(NewSessionView.ancestors(of: path), id: \.self) { p in
                    Button { go(p) } label: {
                        Label(prettyGuestPath(SessionHome.guestPath(p)), systemImage: "folder")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(Self.name(of: path)).font(.system(size: 13, weight: .medium))
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            if entries == nil && !unavailable {
                ProgressView().controlSize(.small)
            }
            if !machineName.isEmpty {
                Text(machineName).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private var content: some View {
        if unavailable {
            placeholder(NSLocalizedString("The machine's folders can't be read right now.", comment: "folder picker"))
        } else if let entries {
            if entries.isEmpty {
                placeholder(NSLocalizedString("No folders in here yet.", comment: "folder picker"))
            } else {
                #if os(macOS)
                // Selection is the list's own; the double-click comes through
                // its primary action — a tap gesture on the rows would fight
                // the click that selects.
                List(entries, id: \.self, selection: $selected) { name in row(name) }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: String.self) { names in
                        if let name = names.first {
                            Button(NSLocalizedString("Open", comment: "folder picker")) {
                                go(NewSessionView.childFolder(of: path, named: name))
                            }
                            Button(NSLocalizedString("Choose", comment: "folder picker")) {
                                onPick(NewSessionView.childFolder(of: path, named: name))
                                dismiss()
                            }
                        }
                    } primaryAction: { names in
                        if let name = names.first { go(NewSessionView.childFolder(of: path, named: name)) }
                    }
                #else
                List(entries, id: \.self) { name in
                    Button { go(NewSessionView.childFolder(of: path, named: name)) } label: { row(name) }
                }
                .listStyle(.plain)
                #endif
            }
        } else {
            Color.clear
        }
    }

    private func row(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.85))
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(prettyGuestPath(SessionHome.guestPath(chosen)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(NSLocalizedString("Cancel", comment: "")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Choose", comment: "folder picker")) {
                onPick(chosen)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canChoose)
        }
        .padding(14)
    }

    private func go(_ p: String) {
        selected = nil
        path = p
    }

    private func load() async {
        entries = nil
        unavailable = false
        let pid = profileID, p = path
        let names = await listFolders(pid, p)
        guard p == path else { return }   // moved on meanwhile
        if let names { entries = names } else { unavailable = true }
    }

    /// The last component, "~" for the home.
    static func name(of path: String) -> String {
        if path == "~" || path == "/" { return path }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The composer's row of chips: inline on a wide stage, a horizontal
/// scroller on a phone so three chips never fight for 350 points.
private struct ChipStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        content()
        #else
        // Wins the width contest against the trailing Spacer, so the chips
        // only scroll when the composer is genuinely too narrow (a phone).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
        }
        .layoutPriority(1)
        #endif
    }
}

/// A choice riding along the composer's bottom edge: what it is now, a
/// chevron, a popover to change it.
private struct ComposerChip<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                content()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
