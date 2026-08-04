import AppKit
import SwiftUI

// MARK: - EXPERIMENT: "Summarize changes" via meat (boldsoftware/meat)
//
// meat (`go install meat.dev/cmd/meat@latest`) abridges a git diff into a
// "reading diff": it asks an LLM to drop everything not worth reading and
// prints what's left plus a one-line summary. This wires it to a tab
// right-click so a workspace's work can be reviewed at a glance.
//
// It runs INSIDE the guest over the existing vsock shell channel, so the diff
// never leaves the VM and meat's LLM call goes out through the same MITM proxy
// as everything else — the workspace's faked credentials, its guardrails, no
// separate key on the host.
//
// Credential note: meat reads OPENAI_API_KEY / ANTHROPIC_API_KEY from the
// environment. A TOKEN-mode workspace exports a proxy-swapped fake so this
// works out of the box; a SUBSCRIPTION-mode workspace authenticates Claude Code
// over OAuth and exports no key, so meat reports "no OpenAI credentials".

@MainActor
@Observable
final class MeatSummaryModel {
    enum Scope: String, CaseIterable, Identifiable {
        case working = "Working tree"
        case staged  = "Staged"
        case head    = "Last commit"
        var id: String { rawValue }
        /// meat's selector for this scope, and git's equivalent for the
        /// full-diff baseline we measure the reduction against.
        var meatFlag: String {
            switch self {
            case .working: return "-w"
            case .staged:  return "-staged"
            case .head:    return "HEAD"
            }
        }
        var gitArgs: String {
            switch self {
            case .working: return "diff"
            case .staged:  return "diff --staged"
            case .head:    return "show --format= HEAD"
            }
        }
    }

    var scope: Scope = .working
    var abridged: MeatDiff = .empty
    var reduction: MeatReduction?
    var running = false
    var error: String?
    /// Files collapsed by the user, by path.
    var collapsed: Set<String> = []

    let repoPath: String
    let workspaceName: String

    init(repoPath: String, workspaceName: String) {
        self.repoPath = repoPath
        self.workspaceName = workspaceName
    }

    var repoName: String {
        repoPath.split(separator: "/").last.map(String.init) ?? repoPath
    }
}

struct MeatSummaryView: View {
    @Bindable var model: MeatSummaryModel
    let onRun: (MeatSummaryModel.Scope) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let e = model.error {
                errorState(e)
            } else if model.running && model.abridged.files.isEmpty {
                busyState
            } else if model.abridged.files.isEmpty && model.abridged.summary.isEmpty {
                emptyState
            } else {
                ScrollView { review.padding(20) }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.repoName).font(.system(size: 13, weight: .semibold))
                Text(model.workspaceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.scope) {
                ForEach(MeatSummaryModel.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize().disabled(model.running)
            Button {
                onRun(model.scope)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.running)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Review body

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title + scope chip, mirroring a PR header.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.scope.rawValue).font(.system(size: 19, weight: .semibold))
                Text(model.repoPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }

            // Stats line: "3 files changed  +106  −0"
            HStack(spacing: 10) {
                Text("\(model.abridged.files.count) file\(model.abridged.files.count == 1 ? "" : "s") changed")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("+\(model.abridged.totalAdded)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                Text("−\(model.abridged.totalRemoved)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
            }

            meatSection
            ForEach(model.abridged.files) { file in fileCard(file) }
        }
    }

    /// The "Meat" disclosure: how much was dropped, then the prose summary.
    private var meatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("Meat").font(.system(size: 13, weight: .semibold))
                if let r = model.reduction {
                    Text(r.caption).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
            }
            if !model.abridged.summary.isEmpty {
                Text(model.abridged.summary)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: One file

    private func fileCard(_ file: MeatDiff.File) -> some View {
        let isCollapsed = model.collapsed.contains(file.path)
        return VStack(spacing: 0) {
            Button {
                if isCollapsed { model.collapsed.remove(file.path) }
                else { model.collapsed.insert(file.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        Text(file.directory).foregroundStyle(.secondary)
                        Text(file.basename).fontWeight(.semibold)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text("+\(file.added)").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                    Text("−\(file.removed)").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Divider()
                VStack(spacing: 0) {
                    ForEach(file.lines) { diffLine($0) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }

    /// One diff row: old gutter, new gutter, marker, text — the shape every
    /// review tool uses, so a reader's eye already knows where to look.
    private func diffLine(_ line: MeatDiff.Line) -> some View {
        let bg: Color = {
            switch line.kind {
            case .added:   return Color.green.opacity(0.13)
            case .removed: return Color.red.opacity(0.11)
            case .hunk:    return Color.primary.opacity(0.05)
            default:       return .clear
            }
        }()
        let marker: String = {
            switch line.kind {
            case .added: return "+"
            case .removed: return "−"
            default: return " "
            }
        }()
        return HStack(spacing: 0) {
            if line.kind == .hunk || line.kind == .meta {
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                gutter(line.oldNumber)
                gutter(line.newNumber)
                Text(marker)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.kind == .added ? .green
                                     : (line.kind == .removed ? .red : .secondary))
                    .frame(width: 14)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 1)
        .background(bg)
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 4)
    }

    // MARK: States

    private func errorState(_ e: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title).foregroundStyle(.orange)
            Text("meat couldn't run").font(.headline)
            ScrollView {
                Text(e).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var busyState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Abridging the diff…").font(.callout).foregroundStyle(.secondary)
            Text("meat calls an LLM per chunk, so this takes a while.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No changes in this scope.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Running it

extension ACAppDelegate {

    /// Open (or focus) the reading-diff window for a tab's repo and run once.
    @MainActor
    func showMeatSummary(profileID: Profile.ID, repoPath: String) {
        if let existing = meatWindows[profileID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let name = profiles.first(where: { $0.id == profileID })?.name ?? "workspace"
        let model = MeatSummaryModel(repoPath: repoPath, workspaceName: name)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Reading diff — \(name)"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MeatSummaryView(model: model) { [weak self] scope in
            self?.runMeat(profileID: profileID, model: model, scope: scope)
        })
        win.makeKeyAndOrderFront(nil)
        meatWindows[profileID] = win
        runMeat(profileID: profileID, model: model, scope: model.scope)
    }

    /// Debug: open the review window with a canned diff so the layout can be
    /// checked without a running VM or an LLM key. `BROMURE_DEBUG_MEAT=1`.
    @MainActor
    func showMeatSummaryDemo() {
        let model = MeatSummaryModel(repoPath: "/home/ubuntu/mdv", workspaceName: "Demo")
        let sample = """
        Preserve CommonMark thematic-break lines during smart typography and add a manual \
        rendering fixture covering rules, setext headings, and dash edge cases.

        diff --git a/mdv/SmartTypography.swift b/mdv/SmartTypography.swift
        --- a/mdv/SmartTypography.swift
        +++ b/mdv/SmartTypography.swift
        @@ -36,6 +36,11 @@ func smartenMarkdown(_ source: String) -> String {
             if looksLikeThematicBreakLine(trimmed) {
        +        return source
        +    }
        @@ -48,10 +53,26 @@ func smartenMarkdown(_ source: String) -> String {
        +    var atLineStart = true
         
             while i < source.endIndex {
                 let c = source[i]
        +        // Emit verbatim so MarkdownUI can recognize it as a thematic break.
        +        if atLineStart && (c == "-" || c == "*" || c == "_") && codeRun == 0 {
        +            var end = i
        +            while end < source.endIndex && source[end] != "\\n" {
        +                end = source.index(after: end)
        +            }
        +            if looksLikeThematicBreakLine(String(source[i..<end])) {
        +                result.append(contentsOf: source[i..<end])
        +                i = end
        +                atLineStart = false
        +                continue
        +            }
        +        }
        -        let legacy = smarten(c)
        diff --git a/mdv/Fixtures/ThematicBreaks.md b/mdv/Fixtures/ThematicBreaks.md
        --- a/mdv/Fixtures/ThematicBreaks.md
        +++ b/mdv/Fixtures/ThematicBreaks.md
        @@ -1,0 +1,4 @@
        +# Rules
        +---
        +Setext heading
        +===
        """
        model.abridged = MeatDiff.parse(sample)
        model.reduction = MeatReduction(keptLines: 59, totalLines: 106,
                                        keptFiles: 2, totalFiles: 3)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Reading diff — Demo"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: MeatSummaryView(model: model) { _ in })
        win.makeKeyAndOrderFront(nil)
        meatWindows[UUID()] = win
    }

    @MainActor
    private func runMeat(profileID: Profile.ID, model: MeatSummaryModel,
                         scope: MeatSummaryModel.Scope) {
        model.running = true
        model.error = nil
        model.abridged = .empty
        model.reduction = nil

        // GOBIN isn't on the non-interactive PATH, so fall back to the
        // `go install` location. Paths are quoted: repo dirs can have spaces.
        let meat = "MEAT=$(command -v meat || echo \"$HOME/go/bin/meat\")"
        let abridgedCmd = "cd '\(model.repoPath)' && \(meat) && \"$MEAT\" \(scope.meatFlag) 2>&1"
        let fullCmd = "cd '\(model.repoPath)' && git --no-pager \(scope.gitArgs) 2>/dev/null"

        Task { @MainActor in
            do {
                // The full diff is cheap and local — fetch it first so the
                // reduction stat has a baseline even if meat then fails.
                let fullText = (try? await guestExec(profileID: profileID,
                                                     command: fullCmd, timeout: 30)) ?? ""
                let full = MeatDiff.parse(fullText)

                // meat calls an LLM per chunk: minutes, not seconds.
                let out = try await guestExec(profileID: profileID,
                                              command: abridgedCmd, timeout: 900)
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)

                // meat reports its own failures on stdout with a `meat:` prefix
                // and prints no diff — surface those as an error, not as an
                // empty review that looks like "no changes".
                if trimmed.hasPrefix("meat:") && !trimmed.contains("@@") {
                    model.error = trimmed
                } else {
                    model.abridged = MeatDiff.parse(trimmed)
                    model.reduction = .between(abridged: model.abridged, full: full)
                }
            } catch {
                model.error = "\(error)"
            }
            model.running = false
        }
    }
}
