import AppKit
import Foundation

/// Where and how a MITM consent prompt (credential use, guardrail write,
/// supply-chain bypass, prompt injection) is asked — without ever blocking
/// the app.
///
/// The old prompts were `NSAlert.runModal()` with no timeout: while one was
/// open the main thread sat in a modal loop, the control socket stopped
/// answering, every other workspace's boots and automations stalled, and an
/// unattended Mac waited forever. Now:
///
///  • remote (fat client / attached terminal): unchanged — `RemoteConsent`;
///  • local: a NON-modal floating panel. The asking broker awaits a
///    continuation; the main thread keeps running everything else;
///  • every prompt has a deadline (default 2 minutes, `consent.timeoutSeconds`
///    in the app's defaults). No answer means no: it resolves to the deny
///    choice, like closing the panel;
///  • prompts are queued per workspace — one panel per workspace at a time,
///    the next shows when it's answered — so a chatty agent can't bury the
///    screen, and one workspace's open prompt never holds up another's.
///
/// Returns the chosen index, or nil for deny / timeout / dismissal, the same
/// mapping `RemoteConsent` uses.
enum ConsentPrompt {
    static var defaultTimeout: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "consent.timeoutSeconds")
        return v >= 10 ? v : 120
    }

    static func choose(profileID: UUID, title: String, message: String,
                       choices: [String], denyIndex: Int,
                       style: NSAlert.Style = .informational,
                       detailText: String? = nil,
                       timeout: TimeInterval = ConsentPrompt.defaultTimeout) async -> Int? {
        switch RemoteConsent.route(for: profileID) {
        case .fatClient:
            // On the fat client AND here: whoever answers first wins, the
            // other surface is withdrawn. A local user is never left without
            // a prompt because a mirror happens to be connected.
            let body = detailText.map { message + "\n\n" + String($0.prefix(1500)) } ?? message
            let idx = await race(
                remote: {
                    await PendingPromptBroker.shared.answerAsync(
                        profileID: profileID, title: title, message: body,
                        buttons: choices, fallback: denyIndex, timeout: timeout)
                },
                local: { token in
                    await ConsentPanelPresenter.shared.present(
                        profileID: profileID, title: title, message: message, choices: choices,
                        denyIndex: denyIndex, style: style, detailText: detailText, timeout: timeout,
                        token: token)
                }) ?? denyIndex
            return idx == denyIndex ? nil : idx
        case .terminalPump:
            let body = detailText.map { message + "\n\n" + String($0.prefix(1500)) } ?? message
            let idx = await Task.detached {
                RemoteConsent.choose(profileID: profileID, title: title, message: body,
                                     choices: choices, timeoutSeconds: timeout)
            }.value
            return idx == denyIndex ? nil : idx
        case .localAlert:
            let idx = await ConsentPanelPresenter.shared.present(
                profileID: profileID, title: title, message: message, choices: choices,
                denyIndex: denyIndex, style: style, detailText: detailText, timeout: timeout)
            return idx == denyIndex ? nil : idx
        }
    }
}

extension ConsentPrompt {
    /// The first answer of two surfaces. `remote` gives nil when nobody
    /// answered there (no client, the client left, its timeout) — that
    /// never ends the race: the local panel still stands. `local` always
    /// answers (a dismissal or its deadline is its deny). The loser is
    /// withdrawn: the remote task is cancelled (its prompt leaves `/state`),
    /// the local panel closed (`withdraw(token:)`).
    static func race(remote: @escaping @Sendable () async -> Int?,
                     local: @escaping @Sendable (UUID) async -> Int?) async -> Int? {
        let token = UUID()
        return await withTaskGroup(of: (Bool, Int?).self) { group in
            group.addTask { (true, await remote()) }
            group.addTask { (false, await local(token)) }
            var answer: Int?
            var localDone = false
            while let (isRemote, idx) = await group.next() {
                if isRemote, idx == nil { continue }
                answer = idx
                localDone = !isRemote
                break
            }
            group.cancelAll()
            if !localDone { await ConsentPanelPresenter.shared.withdraw(token: token) }
            return answer
        }
    }
}

/// The local, non-modal consent panels: a per-workspace queue, a deadline per
/// prompt, and a continuation the asking actor awaits.
@MainActor
final class ConsentPanelPresenter {
    static let shared = ConsentPanelPresenter()

    struct Request {
        let id = UUID()
        let profileID: UUID
        let title: String
        let message: String
        let choices: [String]
        let denyIndex: Int
        let style: NSAlert.Style
        let detailText: String?
        let timeout: TimeInterval
        /// A notice, not a question: no "counts as Don't allow" countdown.
        var isNotice = false
        /// The caller's handle for `withdraw(token:)`.
        var token: UUID? = nil
    }

    /// Builds and shows the UI for a request; calls `answer` (index, or nil
    /// for dismissed) at most once; returns a handle closed by `dismiss`.
    /// Replaceable so tests can drive the queue without windows.
    var makeUI: (Request, @escaping (Int?) -> Void) -> ConsentPanelUI? = { req, answer in
        ConsentPanelWindow(request: req, answer: answer)
    }

    private var queues: [UUID: [(Request, CheckedContinuation<Int?, Never>)]] = [:]
    private var active: [UUID: (request: Request, cont: CheckedContinuation<Int?, Never>, ui: ConsentPanelUI?)] = [:]

    /// Prompts currently on screen or waiting (all workspaces) — for tests and
    /// the debug state.
    var openCount: Int { active.count + queues.values.reduce(0) { $0 + $1.count } }
    var shownTitles: [String] { active.values.map(\.request.title) }

    func present(profileID: UUID, title: String, message: String, choices: [String],
                 denyIndex: Int, style: NSAlert.Style, detailText: String?,
                 timeout: TimeInterval, isNotice: Bool = false, token: UUID? = nil) async -> Int? {
        var req = Request(profileID: profileID, title: title, message: message, choices: choices,
                          denyIndex: denyIndex, style: style, detailText: detailText, timeout: timeout)
        req.isNotice = isNotice
        req.token = token
        if let token, withdrawn.remove(token) != nil { return denyIndex }
        return await withCheckedContinuation { cont in
            queues[profileID, default: []].append((req, cont))
            pump(profileID)
        }
    }

    /// Tokens withdrawn before their request arrived (the race's other
    /// surface answered first).
    private var withdrawn: Set<UUID> = []

    /// Take back the request presented with `token` — answered elsewhere
    /// first: its panel closes (or it leaves the queue) and its caller gets
    /// the deny index (ignored by a caller that already has its answer).
    func withdraw(token: UUID) {
        for (pid, a) in active where a.request.token == token {
            resolve(pid, requestID: a.request.id, choice: nil)
            return
        }
        for (pid, q) in queues {
            if let i = q.firstIndex(where: { $0.0.token == token }) {
                let (req, cont) = q[i]
                var rest = q
                rest.remove(at: i)
                queues[pid] = rest.isEmpty ? nil : rest
                cont.resume(returning: req.denyIndex)
                return
            }
        }
        withdrawn.insert(token)
    }

    /// Answer the prompt on screen for `profileID` (tests / automation).
    @discardableResult
    func answer(profileID: UUID, choice: Int?) -> Bool {
        guard let a = active[profileID] else { return false }
        resolve(profileID, requestID: a.request.id, choice: choice)
        return true
    }

    private func pump(_ profileID: UUID) {
        guard active[profileID] == nil, var q = queues[profileID], !q.isEmpty else { return }
        let (req, cont) = q.removeFirst()
        queues[profileID] = q.isEmpty ? nil : q
        active[profileID] = (req, cont, nil)
        let ui = makeUI(req) { [weak self] choice in
            self?.resolve(profileID, requestID: req.id, choice: choice)
        }
        if active[profileID]?.request.id == req.id { active[profileID]?.ui = ui }
        // No answer means no.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, req.timeout) * 1_000_000_000))
            guard let self, self.active[profileID]?.request.id == req.id else { return }
            FileHandle.standardError.write(Data(
                "[consent] prompt for \(profileID.uuidString.prefix(8)) timed out after \(Int(req.timeout))s — denied\n".utf8))
            self.resolve(profileID, requestID: req.id, choice: nil)
        }
    }

    private func resolve(_ profileID: UUID, requestID: UUID, choice: Int?) {
        guard let a = active[profileID], a.request.id == requestID else { return }
        active[profileID] = nil
        a.ui?.dismiss()
        a.cont.resume(returning: choice.map { $0 >= 0 && $0 < a.request.choices.count ? $0 : a.request.denyIndex }
                      ?? a.request.denyIndex)
        pump(profileID)
    }
}

@MainActor
protocol ConsentPanelUI: AnyObject {
    func dismiss()
}

/// One floating, non-modal consent panel with a live countdown.
///
/// Sized to its content, never past ~80 % of the screen's visible height: the
/// title, countdown and buttons always show in full, and the long parts — the
/// message (which carries the guarded operation: a full path, an AWS action, a
/// whole SQL statement) and the flagged/detail text — get scroll views that
/// shrink to fit. Buttons sit in one row when they fit, else stack full-width
/// (wrapping a label that is wider than the panel).
@MainActor
final class ConsentPanelWindow: NSObject, ConsentPanelUI, NSWindowDelegate {
    let panel: NSPanel
    /// The choice buttons, by choice index (tests).
    private(set) var buttons: [NSButton] = []
    /// True when the buttons are stacked vertically (tests).
    private(set) var buttonsStacked = false
    private let answer: (Int?) -> Void
    private var answered = false
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private let countdown = NSTextField(labelWithString: "")
    private let deadline: Date
    private let req: Request

    /// Layout constants.
    static let inset: CGFloat = 16
    static let iconColumn: CGFloat = 28 + 12
    static let spacing: CGFloat = 8
    static let buttonSpacing: CGFloat = 8
    static let regularTextWidth: CGFloat = 460
    static let wideTextWidth: CGFloat = 560
    static let heightFraction: CGFloat = 0.8

    /// `show: false` builds and lays out the panel without putting it on
    /// screen (tests, offscreen shots); `screenFrame` overrides the visible
    /// frame the panel must fit in.
    init(request req: Request, answer: @escaping (Int?) -> Void,
         show: Bool = true, screenFrame: NSRect? = nil) {
        self.answer = answer
        self.req = req
        self.deadline = Date().addingTimeInterval(req.timeout)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = NSLocalizedString("Bromure — approval needed", comment: "Consent panel window title")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let anchorWindow = show ? (NSApp.keyWindow ?? NSApp.mainWindow) : nil
        let visible = screenFrame
            ?? (anchorWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1366, height: 768)

        let message = req.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (req.detailText?.isEmpty == false) ? req.detailText : nil
        let longContent = message.count > 280 || (detail?.count ?? 0) > 280
            || message.split(separator: "\n").contains { $0.count > 70 }
        let textW = min(longContent ? Self.wideTextWidth : Self.regularTextWidth,
                        max(300, visible.width - 2 * Self.inset - Self.iconColumn - 80))

        let icon = NSImageView(image: NSImage(systemSymbolName: req.style == .critical
                                                ? "exclamationmark.octagon.fill" : "lock.shield",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = req.style == .informational ? .controlAccentColor : .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: req.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        title.preferredMaxLayoutWidth = textW
        title.translatesAutoresizingMaskIntoConstraints = false

        countdown.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countdown.textColor = .secondaryLabelColor
        countdown.lineBreakMode = .byTruncatingTail
        countdown.translatesAutoresizingMaskIntoConstraints = false

        // Buttons: one row if they fit, else a full-width stack (index 0 on
        // top, like NSAlert), wrapping any label wider than the panel.
        var made: [NSButton] = []
        for (i, label) in req.choices.enumerated() {
            let b = NSButton(title: label, target: self, action: #selector(choose(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            if i == 0 { b.keyEquivalent = "\r" }
            if i == req.denyIndex { b.keyEquivalent = "\u{1b}" }
            b.translatesAutoresizingMaskIntoConstraints = false
            made.append(b)
        }
        buttons = made
        let rowWidth = made.reduce(0) { $0 + $1.fittingSize.width }
            + Self.buttonSpacing * CGFloat(max(0, made.count - 1))
        buttonsStacked = rowWidth > textW
        let buttonBox = NSStackView()
        buttonBox.translatesAutoresizingMaskIntoConstraints = false
        if buttonsStacked {
            buttonBox.orientation = .vertical
            buttonBox.alignment = .leading
            buttonBox.spacing = 6
            for b in made {
                let natural = b.fittingSize.width
                buttonBox.addArrangedSubview(b)
                b.widthAnchor.constraint(equalToConstant: textW).isActive = true
                if natural > textW {
                    b.bezelStyle = .flexiblePush
                    b.usesSingleLineMode = false
                    b.lineBreakMode = .byWordWrapping
                    b.cell?.wraps = true
                    b.cell?.truncatesLastVisibleLine = false
                    let h = b.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 10_000)).height ?? 32
                    b.heightAnchor.constraint(equalToConstant: ceil(max(h + 6, 28))).isActive = true
                }
            }
        } else {
            buttonBox.orientation = .horizontal
            buttonBox.alignment = .centerY
            buttonBox.spacing = Self.buttonSpacing
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            buttonBox.addArrangedSubview(spacer)
            for b in made.reversed() { buttonBox.addArrangedSubview(b) }   // index 0 rightmost
        }

        // Scrollable sections, measured at the column width.
        var messageView = message.isEmpty ? nil
            : Self.textSection(message, width: textW, monospaced: false, bordered: false)
        let detailView = detail.map { Self.textSection($0, width: textW, monospaced: true, bordered: true) }

        // Heights: everything but the scroll sections is fixed; those split
        // what's left under the cap (detail capped at a comfortable size
        // first, the message gets the rest, each keeps a readable minimum).
        let titleH = ceil(title.fittingSize.height)
        let countdownH = req.isNotice ? 0 : ceil(countdown.fittingSize.height + 2)
        buttonBox.layoutSubtreeIfNeeded()
        let buttonsH = ceil(buttonBox.fittingSize.height)
        let rows = 2 + (messageView == nil ? 0 : 1) + (detailView == nil ? 0 : 1) + (req.isNotice ? 0 : 1)
        let fixed = 2 * Self.inset + titleH + countdownH + buttonsH + Self.spacing * CGFloat(rows - 1)
        let titleBar = panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
        let maxContentH = floor(visible.height * Self.heightFraction) - titleBar
        var avail = max(0, maxContentH - fixed)
        var detailH: CGFloat = 0, messageH: CGFloat = 0
        if let d = detailView {
            let want = min(d.natural, messageView == nil ? avail : max(260, avail * 0.6))
            detailH = max(min(want, avail), min(d.natural, 80))
            avail -= detailH
        }
        if let m = messageView {
            messageH = max(min(m.natural, avail), min(m.natural, 60))
            if m.natural > messageH + 0.5 {
                // Clipped: frame it so it reads as a scrollable box, not as
                // text cut off mid-line.
                messageView = Self.textSection(message, width: textW, monospaced: false, bordered: true)
            }
        }

        var column: [NSView] = [title]
        if let m = messageView {
            m.scroll.heightAnchor.constraint(equalToConstant: messageH).isActive = true
            m.scroll.hasVerticalScroller = m.natural > messageH + 0.5
            column.append(m.scroll)
        }
        if let d = detailView {
            d.scroll.heightAnchor.constraint(equalToConstant: detailH).isActive = true
            column.append(d.scroll)
        }
        if !req.isNotice { column.append(countdown) }
        column.append(buttonBox)

        let text = NSStackView(views: column)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Self.spacing
        text.translatesAutoresizingMaskIntoConstraints = false
        for v in column { v.widthAnchor.constraint(equalToConstant: textW).isActive = true }

        let outer = NSStackView(views: [icon, text])
        outer.orientation = .horizontal
        outer.alignment = .top
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset,
                                        bottom: Self.inset, right: Self.inset)
        outer.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
        ])
        panel.contentView = content
        tick()
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        size.height = min(size.height, maxContentH)
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = size
        content.layoutSubtreeIfNeeded()
        for section in [messageView?.scroll, detailView?.scroll].compactMap({ $0 }) {
            section.contentView.scroll(to: .zero)   // start at the top
            section.reflectScrolledClipView(section.contentView)
        }

        // Centred on the window that asked (the key window), else the
        // screen, and always inside the visible frame.
        let f = panel.frame
        let anchor = anchorWindow?.frame ?? visible
        var origin = NSPoint(x: anchor.midX - f.width / 2, y: anchor.midY - f.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - f.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - f.height)
        panel.setFrameOrigin(origin)

        guard show else { return }
        if !req.isNotice {
            // In the common run-loop modes (a default-mode timer stops while
            // a menu is open or the mouse tracks) and with no slack; and the
            // app is held out of App Nap while the panel is up — a panel
            // over a background app saw its seconds stretch (14 → 8 in
            // ~20 s) and its deadline slip by minutes.
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Bromure approval countdown")
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.requestUserAttention(.criticalRequest)
    }

    /// A read-only, selectable text block in a scroll view, with its natural
    /// (unscrolled) height at `width`.
    private static func textSection(_ string: String, width: CGFloat, monospaced: Bool,
                                    bordered: Bool) -> (scroll: NSScrollView, natural: CGFloat) {
        let border: NSBorderType = bordered ? .bezelBorder : .noBorder
        let contentW = NSScrollView.contentSize(
            forFrameSize: NSSize(width: width, height: 100), horizontalScrollerClass: nil,
            verticalScrollerClass: NSScroller.self, borderType: border, controlSize: .regular,
            scrollerStyle: NSScroller.preferredScrollerStyle).width
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: contentW, height: 10))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                             : .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        tv.textColor = .labelColor
        tv.drawsBackground = bordered
        if bordered { tv.backgroundColor = .textBackgroundColor }
        tv.textContainerInset = bordered ? NSSize(width: 2, height: 4) : .zero
        tv.textContainer?.lineFragmentPadding = bordered ? 4 : 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.string = string
        var textH: CGFloat = 16
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            textH = ceil(lm.usedRect(for: tc).height + 2 * tv.textContainerInset.height)
        }
        tv.frame.size.height = textH
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.borderType = border
        scroll.drawsBackground = bordered
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let frameH = NSScrollView.frameSize(
            forContentSize: NSSize(width: contentW, height: textH), horizontalScrollerClass: nil,
            verticalScrollerClass: NSScroller.self, borderType: border, controlSize: .regular,
            scrollerStyle: NSScroller.preferredScrollerStyle).height
        return (scroll, ceil(frameH))
    }

    /// Whole seconds left before `deadline`, from the wall clock (never a
    /// count of ticks: a late tick can't stretch the countdown).
    nonisolated static func secondsLeft(until deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The countdown line, refreshed each second; at zero the panel answers
    /// "Don't allow" itself (the presenter's own deadline is the backstop).
    func tick(now: Date = Date()) {
        let left = Self.secondsLeft(until: deadline, now: now)
        countdown.stringValue = Self.countdownLine(secondsLeft: left, request: req)
        if left == 0, !req.isNotice { finish(nil) }
    }

    /// The countdown in the words of the button it stands for: "No answer
    /// within 9 s means “Block this request”." — never a fixed "Don't
    /// allow" next to buttons that say something else.
    nonisolated static func countdownLine(secondsLeft left: Int, request req: ConsentPanelPresenter.Request) -> String {
        let deny = req.choices.indices.contains(req.denyIndex) ? req.choices[req.denyIndex] : ""
        guard !deny.isEmpty else {
            return String(format: NSLocalizedString(
                "No answer within %d s counts as Don't allow.",
                comment: "Consent panel countdown: seconds left before the prompt auto-denies"), left)
        }
        return String(format: NSLocalizedString(
            "No answer within %1$d s means “%2$@”.",
            comment: "Consent panel countdown: seconds left, then the deny button's own label (e.g. “Block this request”) — what no answer amounts to"),
                      left, deny)
    }

    /// The countdown line as shown (tests).
    var countdownText: String { countdown.stringValue }

    @objc private func choose(_ sender: NSButton) {
        finish(sender.tag)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func finish(_ choice: Int?) {
        guard !answered else { return }
        answered = true
        answer(choice)
    }

    func dismiss() {
        answered = true
        timer?.invalidate()
        timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }
}

extension ConsentPanelWindow {
    typealias Request = ConsentPanelPresenter.Request
}
