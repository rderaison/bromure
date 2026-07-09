import AppKit
import MarkdownUI
import SwiftUI

// The file-explorer pane (right side of the unified window): the active
// tab's repo as a tree with IDE-style git-status coloring, plus a detail
// split showing a colored diff or a rendered preview (Markdown / highlighted
// source) of the selected file. Data arrives via FileExplorerModel over the
// guest shell vsock — see FileExplorer.swift.

struct FileExplorerPane: View {
    @Bindable var model: FileExplorerModel
    @Bindable var listModel: SessionListModel
    /// Called on repo transitions: true when the active tab ENTERS a git repo
    /// while the pane is closed (IDE-style auto-show), false when it LEAVES a
    /// repo for a non-repo directory (auto-collapse).
    let onAutoSetOpen: (Bool) -> Void

    /// Expanded directories (repo-relative paths). Reset per repo.
    @State private var expanded: Set<String> = []
    /// Repo the tree was last auto-expanded for (dirs containing changes).
    @State private var autoExpandedRepo: String?
    /// The (VM, repo) context the pane last auto-opened for. Keeps the 0.7s
    /// roster ticks from re-opening after a manual close: only a TRANSITION
    /// into a repo triggers, and leaving the repo re-arms it.
    @State private var lastAutoOpenKey: String?
    /// Last DEFINITIVE repo-ness (a live tab with a cwd). Detects the
    /// repo → non-repo edge for auto-collapse; unknown states (booting VM,
    /// empty selection, no roster yet) never count as "left the repo".
    @State private var wasInRepo = false

    /// The selected VM's active tab, live via @Observable.
    private var activeTab: TabsModel.Tab? {
        listModel.entries.first { $0.id == listModel.selectedID }?.model.activeTab
    }
    private var currentRepoRoot: String? {
        guard let tab = activeTab, tab.isGitRepo else { return nil }
        return tab.repoRoot
    }
    /// One key that captures everything the pane's context depends on; any
    /// change re-points the model and restarts the status polling task.
    private var contextKey: String {
        let id = listModel.selectedID?.uuidString ?? "-"
        return "\(id)|\(currentRepoRoot ?? "-")|\(listModel.filePaneOpen)|\(listModel.gridSelected)"
    }
    /// Auto-open watches only (VM, repo) — deliberately NOT filePaneOpen, so
    /// closing the pane doesn't retrigger the transition check.
    private var autoRepoKey: String {
        "\(listModel.selectedID?.uuidString ?? "-")|\(currentRepoRoot ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Seam against the terminal — the pane owns its own divider line.
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .onAppear {
            applyContext()
            handleRepoTransition()
        }
        .onChange(of: contextKey) { applyContext() }
        .onChange(of: autoRepoKey) { handleRepoTransition() }
        .onChange(of: model.loading) {
            // Auto-expand directories containing changes once per repo, when
            // the first listing lands. Additive only — the user's collapse
            // choices survive later refreshes.
            guard !model.loading, let repo = model.repoRoot, autoExpandedRepo != repo
            else { return }
            autoExpandedRepo = repo
            expanded = Self.dirtyDirectories(model.rootNodes)
        }
        .task(id: contextKey) {
            // Poll git status while the pane is actually showing (not closed,
            // not covered by the grid). 4s keeps the tree live against agent
            // edits without meaningfully loading the guest.
            guard listModel.filePaneOpen, !listModel.gridSelected,
                  currentRepoRoot != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
    }

    private func applyContext() {
        guard listModel.filePaneOpen else {
            model.setRepo(profileID: nil, root: nil)   // park while closed
            return
        }
        model.setRepo(profileID: listModel.selectedID, root: currentRepoRoot)
    }

    /// IDE-style auto-show/auto-hide, both edge-triggered so the 0.7s roster
    /// ticks can't fight a manual toggle:
    ///  - entering a repo (cd in, or switching to a tab sitting in one) while
    ///    closed → open. A manual close then wins for as long as the context
    ///    stays on that repo.
    ///  - leaving a repo for a definitively non-repo directory → close.
    /// Only a live tab with a cwd counts as definitive; unknown states (VM
    /// booting, nothing selected) change nothing in either direction.
    private func handleRepoTransition() {
        guard let tab = activeTab, let cwd = tab.cwd, !cwd.isEmpty else { return }
        let inRepo = currentRepoRoot != nil
        defer { wasInRepo = inRepo }
        if inRepo {
            if !listModel.filePaneOpen, lastAutoOpenKey != autoRepoKey {
                lastAutoOpenKey = autoRepoKey
                onAutoSetOpen(true)
            }
        } else {
            lastAutoOpenKey = nil
            if wasInRepo, listModel.filePaneOpen {
                onAutoSetOpen(false)
            }
        }
    }

    private static func dirtyDirectories(_ nodes: [FileNode]) -> Set<String> {
        var result: Set<String> = []
        func walk(_ node: FileNode) {
            if node.isDirectory && node.containsChanges {
                result.insert(node.path)
                node.children.forEach(walk)
            }
        }
        nodes.forEach(walk)
        return result
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.7)
            if !model.statuses.isEmpty {
                Text("\(model.statuses.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .help("\(model.statuses.count) changed files")
            }
            Spacer()
            Button {
                model.changedOnly.toggle()
            } label: {
                Image(systemName: model.changedOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(model.changedOnly ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.changedOnly ? "Show all files" : "Show changed files only")
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.repoRoot == nil {
            placeholder(icon: "folder.badge.questionmark",
                        text: activeTab?.cwd == nil
                            ? "No session selected"
                            : "The current directory isn't a git repository")
        } else if model.loading && model.rootNodes.isEmpty {
            VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxWidth: .infinity)
        } else if let err = model.loadError, model.rootNodes.isEmpty {
            placeholder(icon: "exclamationmark.triangle", text: err, retry: true)
        } else if model.selectedPath == nil {
            tree
        } else {
            VSplitView {
                tree.frame(minHeight: 110, maxHeight: .infinity)
                FileDetailSection(model: model)
                    .frame(minHeight: 140, maxHeight: .infinity)
            }
        }
    }

    private func placeholder(icon: String, text: String, retry: Bool = false) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if retry {
                Button("Retry") { Task { await model.refresh() } }
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.changedOnly {
                    let changed = model.statuses.keys.sorted()
                    if changed.isEmpty {
                        Text("No changes")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .padding(8)
                    }
                    ForEach(changed, id: \.self) { path in
                        FileRow(name: path, depth: 0, isDirectory: false,
                                isExpanded: false, status: model.statuses[path],
                                isSelected: model.selectedPath == path,
                                onTap: { model.select(path) })
                    }
                } else {
                    ForEach(Self.flatten(model.rootNodes, expanded: expanded),
                            id: \.node.id) { item in
                        FileRow(name: item.node.name, depth: item.depth,
                                isDirectory: item.node.isDirectory,
                                isExpanded: expanded.contains(item.node.path),
                                status: item.node.status,
                                containsChanges: item.node.containsChanges,
                                isSelected: model.selectedPath == item.node.path,
                                onTap: {
                                    if item.node.isDirectory {
                                        if expanded.contains(item.node.path) {
                                            expanded.remove(item.node.path)
                                        } else {
                                            expanded.insert(item.node.path)
                                        }
                                    } else {
                                        model.select(item.node.path)
                                    }
                                })
                    }
                }
                if model.truncated {
                    Text("Tree truncated — repo has too many files to list")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// Depth-first flatten of the visible (expanded) tree — keeps the list
    /// lazy-friendly instead of nesting recursive view structs.
    static func flatten(_ nodes: [FileNode], expanded: Set<String>,
                        depth: Int = 0) -> [(node: FileNode, depth: Int)] {
        var rows: [(FileNode, Int)] = []
        for node in nodes {
            rows.append((node, depth))
            if node.isDirectory && expanded.contains(node.path) {
                rows.append(contentsOf: flatten(node.children, expanded: expanded,
                                                depth: depth + 1))
            }
        }
        return rows
    }
}

// MARK: - Tree row

private struct FileRow: View {
    let name: String
    let depth: Int
    let isDirectory: Bool
    let isExpanded: Bool
    let status: GitFileStatus?
    var containsChanges = false
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(isDirectory ? Color.accentColor.opacity(0.8) : Color.secondary)
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(nameColor)
                    .strikethrough(status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if let status {
                    Text(status.badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(status.tint)
                } else if containsChanges {
                    Circle().fill(Color.orange.opacity(0.7)).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + 4)
            .padding(.trailing, 6)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(
                isSelected ? Color.accentColor.opacity(0.18)
                           : hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }

    private var iconName: String {
        if isDirectory { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "icns": return "photo"
        case "md", "markdown": return "doc.richtext"
        default: return "doc.text"
        }
    }

    private var nameColor: Color {
        if let status { return status.tint }
        return .primary
    }
}

// MARK: - Detail (diff / preview)

private struct FileDetailSection: View {
    @Bindable var model: FileExplorerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            detailBody
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text((model.selectedPath as NSString?)?.lastPathComponent ?? "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.selectedPath ?? "")
            if case .diff(let doc) = model.detail, doc.additions + doc.deletions > 0 {
                Text("+\(doc.additions)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("−\(doc.deletions)").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }
            Spacer()
            if model.selectionHasDiff {
                Picker("", selection: Binding(
                    get: { model.detailMode },
                    set: { model.setDetailMode($0) })) {
                    Text("Diff").tag(FileExplorerModel.DetailMode.diff)
                    Text("File").tag(FileExplorerModel.DetailMode.preview)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 110)
            }
            Button { model.select(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var detailBody: some View {
        switch model.detail {
        case .none:
            Color.clear
        case .loading:
            VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxWidth: .infinity)
        case .diff(let doc):
            if doc.lines.isEmpty {
                centered("No changes against HEAD")
            } else {
                DiffView(document: doc)
            }
        case .markdown(let text):
            ScrollView {
                Markdown(text)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .code(let text, let language):
            CodePreview(text: text, language: language)
        case .binary:
            centered("Binary file")
        case .tooLarge:
            centered("File is too large to preview")
        case .error(let message):
            centered(message)
        }
    }

    private func centered(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

// MARK: - Colored diff

private struct DiffView: View {
    let document: DiffDocument

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines) { line in
                    DiffLineRow(line: line)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffLineRow: View {
    let line: DiffDocument.Line

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .padding(.vertical, 0.5)
        }
        .background(backgroundColor)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.13)
        case .hunk: .blue.opacity(0.07)
        case .context, .meta: .clear
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .hunk: .blue.opacity(0.8)
        case .meta: .secondary
        default: .primary
        }
    }
}

// MARK: - Source preview (Highlightr)

/// One shared highlight.js context; JavaScriptCore setup is ~100ms, so it's
/// created once and reused off the main actor.
private actor CodeHighlighter {
    static let shared = CodeHighlighter()
    private var highlightr: Highlightr?
    private var themeName: String?

    func highlight(_ text: String, language: String, dark: Bool)
        -> (text: NSAttributedString, background: NSColor)? {
        guard let h = highlightr ?? Highlightr() else { return nil }
        highlightr = h
        let theme = dark ? "atom-one-dark" : "xcode"
        if themeName != theme {
            h.setTheme(to: theme)
            h.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
            themeName = theme
        }
        guard let attributed = h.highlight(text, as: language, fastRender: true)
        else { return nil }
        return (attributed, h.theme.themeBackgroundColor ?? .textBackgroundColor)
    }
}

private struct CodePreview: View {
    let text: String
    let language: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: (text: NSAttributedString, background: NSColor)?

    var body: some View {
        Group {
            if let rendered {
                AttributedTextView(text: rendered.text, background: rendered.background)
            } else {
                // Plain monospaced while highlighting (or when no language).
                AttributedTextView(text: Self.plain(text), background: nil)
            }
        }
        .task(id: "\(language ?? "")|\(colorScheme == .dark)|\(text.hashValue)") {
            guard let language else {
                rendered = nil
                return
            }
            rendered = await CodeHighlighter.shared.highlight(
                text, language: language, dark: colorScheme == .dark)
        }
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

/// Selectable, read-only NSTextView — SwiftUI Text chokes on multi-hundred-KB
/// attributed strings; TextKit doesn't.
private struct AttributedTextView: NSViewRepresentable {
    let text: NSAttributedString
    let background: NSColor?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.textStorage?.isEqual(to: text) != true {
            textView.textStorage?.setAttributedString(text)
        }
        let bg = background ?? .textBackgroundColor
        textView.backgroundColor = bg
        scroll.backgroundColor = bg
    }
}
