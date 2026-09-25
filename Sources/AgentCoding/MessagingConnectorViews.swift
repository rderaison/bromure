#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Signal / WhatsApp connector window
//
// File › Infrastructure › Signal / WhatsApp Connector… (and the sidebar's
// Messaging row). One window: the connector machine's state (on/off, like a
// registry), then a card per channel — Connect… opens its setup flow:
//   Signal:   its own number (code by SMS or by voice call — Signal only
//             calls a number it has texted first; a captcha when Signal asks
//             for one) or a link to the user's own account (QR).
//   WhatsApp: a link to the user's account ("Message yourself") or to a
//             second account the Switchboard answers as — QR or pairing code.
// The VM underneath is never the user's concern beyond on/off.

@MainActor
enum ConnectorWindowController {
    private static var window: NSWindow?

    static var app: ACAppDelegate? { NSApp.delegate as? ACAppDelegate }

    static func show() {
        guard let app else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = ConnectorView(store: app.kubeClusterStore, engine: app.kubeClusterEngine)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = NSLocalizedString("Signal / WhatsApp Connector", comment: "connector window")
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        if let c = app.kubeClusterStore.connector { app.kubeClusterEngine.setWatch(c.id, true) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let c = app.kubeClusterStore.connector { app.kubeClusterEngine.setWatch(c.id, false) }
                window = nil
            }
        }
    }

    /// The sidebar row's ⋯ / right-click verbs.
    static func perform(_ id: UUID, _ action: KubeRowAction) {
        guard let app else { return }
        let engine = app.kubeClusterEngine
        switch action {
        case .start: engine.startConnector(id)
        case .stop: Task { await engine.stopConnector(id) }
        case .restart: engine.restartConnector(id)
        case .delete: confirmDelete(id)
        case .access: show()
        }
    }

    static func confirmDelete(_ id: UUID) {
        guard let app else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Remove the Signal / WhatsApp connector?", comment: "connector delete")
        alert.informativeText = NSLocalizedString("Its machine and everything on it goes — including the linked accounts. Bromure can no longer reach your phone until you set it up again. (A device linked to your own account also stays listed on your phone until you remove it there.)", comment: "connector delete")
        alert.addButton(withTitle: NSLocalizedString("Remove", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await app.kubeClusterEngine.deleteConnector(id) }
    }
}

// MARK: - Main view

struct ConnectorView: View {
    let store: KubeClusterStore
    let engine: KubeClusterEngine
    @State private var setup: ConnectorChannel.Kind?
    @State private var testNote: String?
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let c = store.connector {
                    machine(c)
                    let up = store.status(c.id).phase == .running
                    channelCard(.signal, c.signal, up: up)
                    channelCard(.whatsapp, c.whatsapp, up: up)
                    if let testNote {
                        Text(testNote).font(.callout).foregroundStyle(.secondary)
                    }
                    logSection(c)
                } else {
                    intro
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
        .sheet(item: $setup) { kind in
            Group {
                switch kind {
                case .signal: SignalSetupView(engine: engine, onDone: { setup = nil })
                case .whatsapp: WhatsAppSetupView(engine: engine, onDone: { setup = nil })
                }
            }
            .frame(width: 520)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Signal / WhatsApp Connector", comment: "connector window"))
                    .font(.title2.weight(.semibold))
                Text(NSLocalizedString("Chat with Bromure about your sessions from your phone.", comment: "connector window"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Ask what's going on, answer a blocked session, or start new work — from Signal or WhatsApp. The connector is a small machine of its own on this Mac: your messaging keys live on it and nowhere else.", comment: "connector intro"))
                .fixedSize(horizontal: false, vertical: true)
            Button(NSLocalizedString("Set Up the Connector", comment: "connector intro")) {
                engine.ensureConnector()
                if let c = store.connector { engine.setWatch(c.id, true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func machine(_ c: MessagingConnector) -> some View {
        let st = store.status(c.id)
        return HStack(spacing: 10) {
            Circle().fill(dot(st.phase)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseLine(st)).font(.callout.weight(.medium))
                Text(NSLocalizedString("Runs isolated on this Mac", comment: "connector machine"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if st.phase.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Toggle(NSLocalizedString("Start with Bromure", comment: "connector machine"),
                   isOn: Binding(get: { c.autoStart }, set: { engine.setConnectorAutoStart(c.id, $0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            if st.phase.isUp {
                Button(NSLocalizedString("Stop", comment: "")) { Task { await engine.stopConnector(c.id) } }
            } else if !st.phase.isBusy {
                Button(NSLocalizedString("Start", comment: "")) { engine.startConnector(c.id) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private func dot(_ p: KubeClusterPhase) -> Color {
        switch p {
        case .running: return .green
        case .error: return .red
        case .stopped: return Color.secondary.opacity(0.4)
        default: return .orange
        }
    }

    private func phaseLine(_ st: KubeClusterStatus) -> String {
        switch st.phase {
        case .running:
            return st.message ?? NSLocalizedString("Running", comment: "connector machine")
        case .creating, .starting:
            return st.step ?? st.phase.displayName
        case .error:
            return st.message ?? st.phase.displayName
        default:
            return st.phase.displayName
        }
    }

    private func channelCard(_ kind: ConnectorChannel.Kind, _ ch: ConnectorChannel?, up: Bool) -> some View {
        let name = kind == .signal ? "Signal" : "WhatsApp"
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .signal ? "bubble.left.and.bubble.right.fill" : "phone.bubble.fill")
                .font(.system(size: 18))
                .foregroundStyle(kind == .signal ? Color.blue : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                if let ch, ch.connected {
                    Text(ch.mode == .ownNumber
                         ? String(format: NSLocalizedString("Bromure is a contact%@", comment: "connector card"),
                                  ch.account.map { " · " + Self.masked($0) } ?? "")
                         : String(format: NSLocalizedString("You chat in “%@”", comment: "connector card"),
                                  kind == .signal
                                      ? NSLocalizedString("Note to Self", comment: "Signal's own self-chat, as Signal names it")
                                      : NSLocalizedString("Message yourself", comment: "WhatsApp's own self-chat, as WhatsApp names it")))
                        .font(.callout).foregroundStyle(.secondary)
                    if ch.mode == .linked {
                        Text(NSLocalizedString("Replies don't notify you — open that chat to see them.", comment: "connector card"))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(NSLocalizedString("Not connected", comment: "connector card"))
                        .font(.callout).foregroundStyle(.secondary)
                    if kind == .whatsapp {
                        Text(NSLocalizedString("WhatsApp doesn't officially support this kind of link, and may disconnect it.", comment: "connector card"))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let ch, ch.connected {
                    Button(NSLocalizedString("Send Test Message", comment: "connector card")) {
                        Task {
                            let ok = await engine.sendToUser("Hi, I'm your Bromure Switchboard. Ask me what's going on.", via: kind)
                            testNote = ok ? String(format: NSLocalizedString("Test message sent on %@.", comment: ""), name)
                                          : String(format: NSLocalizedString("The test message didn't go out on %@ — see the log.", comment: ""), name)
                        }
                    }
                    Button(NSLocalizedString("Disconnect…", comment: "connector card"), role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(format: NSLocalizedString("Disconnect %@?", comment: "connector disconnect"), name)
                        alert.informativeText = NSLocalizedString("Bromure won't hear from you on it until you connect again (a new QR scan or code).", comment: "connector disconnect")
                        alert.addButton(withTitle: NSLocalizedString("Disconnect", comment: ""))
                        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                        alert.buttons.first?.hasDestructiveAction = true
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Task { await engine.disconnect(kind) }
                    }
                } else {
                    Button(NSLocalizedString("Connect…", comment: "connector card")) { setup = kind }
                        .disabled(!up)
                        .help(up ? "" : NSLocalizedString("Waiting for the connector to start", comment: ""))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }

    private func logSection(_ c: MessagingConnector) -> some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollView {
                Text(store.status(c.id).log.suffix(120).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
        } label: {
            Text(NSLocalizedString("Log", comment: "connector window")).font(.caption)
        }
    }

    /// "+1•••4567" — enough to recognize, not to read off a screenshot.
    static func masked(_ s: String) -> String {
        let d = KubeClusterEngine.digits(s)
        guard d.count > 4 else { return s }
        return "+" + String(d.prefix(1)) + "•••" + String(d.suffix(4))
    }
}

extension ConnectorChannel.Kind: Identifiable {
    public var id: String { rawValue }
}

// MARK: - QR

enum QRImage {
    static func make(_ text: String, size: CGFloat = 220) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width,
                                                           y: size / out.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Signal setup

struct SignalSetupView: View {
    let engine: KubeClusterEngine
    let onDone: () -> Void

    enum Step { case choose, number, code, link, done }
    @State private var step: Step = .choose
    @State private var botNumber = ""
    @State private var userNumber = ""
    @State private var code = ""
    @State private var captcha = ""
    @State private var needsCaptcha = false
    @State private var smsTried = false
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var linkURI: String?
    @State private var linkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("Connect Signal", comment: "signal setup")).font(.title3.weight(.semibold))
            switch step {
            case .choose: choose
            case .number: numberStep
            case .code: codeStep
            case .link: linkStep
            case .done: doneStep
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(step == .done ? NSLocalizedString("Done", comment: "") : NSLocalizedString("Cancel", comment: "")) {
                    linkTask?.cancel()
                    onDone()
                }
                .keyboardShortcut(step == .done ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Where do you want to chat with Bromure?", comment: "signal setup"))
            ModeCard(icon: "person.fill.questionmark",
                     title: NSLocalizedString("Chat with yourself", comment: "signal setup"),
                     detail: NSLocalizedString("Talk to Bromure in your own “Note to Self” chat. Nothing to set up — but replies don't notify you.", comment: "signal setup")) {
                step = .link
                startLink()
            }
            ModeCard(icon: "person.crop.circle.badge.checkmark",
                     title: NSLocalizedString("Chat with a Bromure contact", comment: "signal setup"),
                     detail: NSLocalizedString("Bromure gets its own number and shows up like a person; its replies notify you. Needs a spare phone number that can receive one text or call.", comment: "signal setup")) {
                step = .number
            }
        }
    }

    private var numberStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Bromure's number — the spare one (international format)", comment: "signal setup")).font(.callout)
            TextField("+1 555 123 4567", text: $botNumber).textFieldStyle(.roundedBorder)
            if needsCaptcha {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Signal wants proof you're a person. Open its captcha page, solve it, then right-click “Open Signal” and copy the link — paste it here.", comment: "signal setup"))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Link(NSLocalizedString("Open Signal's captcha page", comment: "signal setup"),
                         destination: URL(string: "https://signalcaptchas.org/registration/generate.html")!)
                        .font(.caption)
                    TextField("signalcaptcha://…", text: $captcha).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button(NSLocalizedString("Text Me a Code", comment: "signal setup")) { register(voice: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || e164(botNumber) == nil)
                Button(NSLocalizedString("Call Me Instead", comment: "signal setup")) { register(voice: true) }
                    .disabled(busy || e164(botNumber) == nil || !smsTried)
                    .help(smsTried ? NSLocalizedString("A voice call reads the code out", comment: "")
                                   : NSLocalizedString("Signal only calls a number it has tried to text first — try the text, then the call if it doesn't arrive (lines without SMS)", comment: ""))
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if smsTried {
                Button(NSLocalizedString("I Have the Code", comment: "signal setup")) { step = .code }
                    .buttonStyle(.link)
            }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: NSLocalizedString("The code Signal sent to %@", comment: "signal setup"), botNumber)).font(.callout)
            TextField("123-456", text: $code).textFieldStyle(.roundedBorder)
            Text(NSLocalizedString("Your own number — the only one Bromure will answer", comment: "signal setup")).font(.callout)
            TextField("+1 555 765 4321", text: $userNumber).textFieldStyle(.roundedBorder)
            HStack {
                Button(NSLocalizedString("Verify", comment: "signal setup")) { verify() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || code.filter(\.isNumber).count < 6 || e164(userNumber) == nil)
                Button(NSLocalizedString("Back", comment: "")) { step = .number }
            }
        }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("On your phone: Signal › Settings › Linked devices › Link new device, then scan:", comment: "signal setup"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let uri = linkURI, let img = QRImage.make(uri) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                } else {
                    ProgressView().frame(width: 220, height: 220)
                }
                Spacer()
            }
            Text(NSLocalizedString("Then chat with Bromure in your “Note to Self”.", comment: "signal setup"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("Signal is connected.", comment: "signal setup"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button(NSLocalizedString("Send a Test Message", comment: "signal setup")) {
                Task {
                    let ok = await engine.sendToUser("Hi, I'm your Bromure Switchboard. Ask me what's going on.", via: .signal)
                    note = ok ? NSLocalizedString("Sent — check your phone.", comment: "")
                              : NSLocalizedString("It didn't go out — see the connector's log.", comment: "")
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// "+15551234567" from what the user typed, or nil.
    private func e164(_ s: String) -> String? {
        let d = s.filter(\.isNumber)
        guard d.count >= 8, d.count <= 15 else { return nil }
        return "+" + d
    }

    private func register(voice: Bool) {
        guard let n = e164(botNumber) else { return }
        busy = true; error = nil
        Task {
            let r = await engine.signalRegister(number: n, voice: voice,
                                                captcha: needsCaptcha ? captcha.trimmingCharacters(in: .whitespaces) : nil)
            busy = false
            if r.ok {
                smsTried = true
                note = voice ? NSLocalizedString("Signal is calling that number — the code is read out.", comment: "")
                             : NSLocalizedString("Code sent by text. No text after a minute? Use Call Me Instead.", comment: "")
                step = .code
            } else if r.captchaRequired {
                needsCaptcha = true
                error = NSLocalizedString("Signal asks for a captcha first — see above.", comment: "")
            } else {
                // A voice attempt Signal refused still counts the SMS as tried.
                if !voice { smsTried = true }
                error = r.message
            }
        }
    }

    private func verify() {
        guard let bot = e164(botNumber), let user = e164(userNumber) else { return }
        busy = true; error = nil
        Task {
            let r = await engine.signalVerify(number: bot, code: code, userNumber: user)
            busy = false
            if r.ok { step = .done } else { error = r.message }
        }
    }

    private func startLink() {
        busy = true; error = nil
        linkTask = Task {
            let r = await engine.signalLinkURI()
            busy = false
            guard r.ok, let uri = r.value else { error = r.message; return }
            linkURI = uri
            // The scan finishes the link on Signal's side; the account then
            // shows up in the connector.
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                let f = await engine.signalFinishLink()
                if f.ok { step = .done; return }
            }
            error = NSLocalizedString("The link wasn't completed. Close and try again.", comment: "")
        }
    }
}

// MARK: - WhatsApp setup

struct WhatsAppSetupView: View {
    let engine: KubeClusterEngine
    let onDone: () -> Void

    enum Step { case choose, contactPrep, link, done }
    @State private var step: Step = .choose
    @State private var mode: ConnectorChannel.Mode = .linked
    @State private var userPhone = ""
    @State private var useCode = false
    @State private var accountPhone = ""
    @State private var pairCode: String?
    @State private var qr: NSImage?
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("Connect WhatsApp", comment: "whatsapp setup")).font(.title3.weight(.semibold))
            switch step {
            case .choose: choose
            case .contactPrep: contactPrep
            case .link: linkStep
            case .done: doneStep
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(step == .done ? NSLocalizedString("Done", comment: "") : NSLocalizedString("Cancel", comment: "")) {
                    pollTask?.cancel()
                    onDone()
                }
                .keyboardShortcut(step == .done ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Where do you want to chat with Bromure?", comment: "whatsapp setup"))
            ModeCard(icon: "person.fill.questionmark",
                     title: NSLocalizedString("Chat with yourself", comment: "whatsapp setup"),
                     detail: NSLocalizedString("Talk to Bromure in your own “Message yourself” chat. Nothing to set up — but replies don't notify you.", comment: "whatsapp setup")) {
                mode = .linked
                step = .link
                startLink()
            }
            ModeCard(icon: "person.crop.circle.badge.checkmark",
                     title: NSLocalizedString("Chat with a Bromure contact", comment: "whatsapp setup"),
                     detail: NSLocalizedString("Bromure shows up like a person in your chats, and its replies notify you. Needs a second WhatsApp account — we'll show you how.", comment: "whatsapp setup")) {
                error = nil
                step = .contactPrep
            }
        }
    }

    /// What "a Bromure contact" takes on WhatsApp — Bromure can't create a
    /// WhatsApp account, only link to one that exists.
    private var contactPrep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Before you start", comment: "whatsapp setup")).font(.headline)
            Text(NSLocalizedString("Bromure can't create a WhatsApp account — it links to one you set up for it. That account is who you'll be chatting with.", comment: "whatsapp setup"))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                PrepStep(n: 1, text: NSLocalizedString("Get a spare number: a second SIM or eSIM, or a landline (WhatsApp can verify it with a voice call).", comment: "whatsapp setup"))
                PrepStep(n: 2, text: NSLocalizedString("Install WhatsApp Business — it runs next to your regular WhatsApp on the same phone — and register it with that spare number.", comment: "whatsapp setup"))
                PrepStep(n: 3, text: NSLocalizedString("Come back here: you'll scan a QR code with WhatsApp Business (Settings › Linked devices).", comment: "whatsapp setup"))
            }
            Divider()
            Text(NSLocalizedString("Your personal WhatsApp number", comment: "whatsapp setup")).font(.callout.weight(.medium))
            TextField("+1 555 765 4321", text: $userPhone).textFieldStyle(.roundedBorder)
            Text(NSLocalizedString("Bromure answers messages from this number only — anyone else who writes to Bromure's account is ignored.", comment: "whatsapp setup"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(NSLocalizedString("I Have the Second Account — Continue", comment: "whatsapp setup")) {
                    mode = .ownNumber
                    step = .link
                    startLink()
                }
                .buttonStyle(.borderedProminent)
                .disabled(e164(userPhone) == nil)
                Button(NSLocalizedString("Back", comment: "")) { step = .choose }
            }
        }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .linked
                 ? NSLocalizedString("On your phone: WhatsApp › Settings › Linked devices › Link a device, then scan:", comment: "whatsapp setup")
                 : NSLocalizedString("On the phone with Bromure's WhatsApp account: Settings › Linked devices › Link a device, then scan:", comment: "whatsapp setup"))
                .fixedSize(horizontal: false, vertical: true)
            if useCode {
                HStack {
                    TextField(NSLocalizedString("The number of the account you're linking", comment: "whatsapp setup"),
                              text: $accountPhone).textFieldStyle(.roundedBorder)
                    Button(NSLocalizedString("Get Code", comment: "whatsapp setup")) { pair() }
                        .disabled(busy || e164(accountPhone) == nil)
                }
                if let pairCode {
                    Text(pairCode).font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(NSLocalizedString("Linked devices › Link a device › Link with phone number instead — type this code.", comment: "whatsapp setup"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    if let qr {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                    } else {
                        ProgressView().frame(width: 220, height: 220)
                    }
                    Spacer()
                }
            }
            Button(useCode ? NSLocalizedString("Scan a QR code instead", comment: "whatsapp setup")
                           : NSLocalizedString("Use a pairing code instead", comment: "whatsapp setup")) {
                useCode.toggle()
            }
            .buttonStyle(.link)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("WhatsApp is connected.", comment: "whatsapp setup"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button(NSLocalizedString("Send a Test Message", comment: "whatsapp setup")) {
                Task {
                    let ok = await engine.sendToUser("Hi, I'm your Bromure Switchboard. Ask me what's going on.", via: .whatsapp)
                    note = ok ? NSLocalizedString("Sent — check your phone.", comment: "")
                              : NSLocalizedString("It didn't go out — see the connector's log.", comment: "")
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func e164(_ s: String) -> String? {
        let d = s.filter(\.isNumber)
        guard d.count >= 8, d.count <= 15 else { return nil }
        return "+" + d
    }

    /// Fetch a fresh QR (they expire every ~30 s) and poll for the login.
    private func startLink() {
        error = nil
        pollTask?.cancel()
        pollTask = Task {
            var lastQR = Date.distantPast
            for _ in 0..<200 {
                if Task.isCancelled { return }
                if !useCode, Date().timeIntervalSince(lastQR) > 25 {
                    let r = await engine.whatsappQR()
                    if let png = r.data { qr = NSImage(data: png); lastQR = Date() }
                }
                let f = await engine.whatsappFinishLink(mode: mode, userPhone: e164(userPhone))
                if f.ok { step = .done; return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            error = NSLocalizedString("The link wasn't completed. Close and try again.", comment: "")
        }
    }

    private func pair() {
        guard let n = e164(accountPhone) else { return }
        busy = true; error = nil
        Task {
            let r = await engine.whatsappPairingCode(phone: n)
            busy = false
            if r.ok { pairCode = r.value } else { error = r.message }
        }
    }
}

// MARK: - Shared

/// "1  Get a spare number…" — a numbered preparation step.
struct PrepStep: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A big choice button: icon, title, one line of what it means.
struct ModeCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
