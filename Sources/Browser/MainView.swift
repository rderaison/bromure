import SwiftUI
import SandboxEngine

/// First-run / maintenance window: image download, local bake, warm-up and
/// error states. Only shown while the browser engine isn't ready — once
/// the pool is warm the app opens browser windows directly (profiles are
/// picked from the tab-bar chip or the File menu), so there is no
/// launcher any more.
///
/// Two layouts: a compact "starting" panel for a normal launch, and the
/// setup layout (brand rail with the install stages on the left, the
/// current step on the right) for first run, rebuilds, refreshes and
/// errors. Once the setup layout has been shown it stays up through the
/// warm-up, so the window doesn't collapse to the compact panel moments
/// before the first browser window replaces it.
struct MainView: View {
    @Bindable var state: AppState

    @State private var showsSetupLayout = false
    /// Stage the install was in when it failed, so the rail can mark it.
    @State private var lastStage: SetupStage?

    static let setupSize = CGSize(width: 720, height: 460)

    var body: some View {
        Group {
            if showsSetupLayout || Self.needsSetupLayout(state.phase) {
                setupLayout
            } else {
                StartingPanel()
            }
        }
        .onAppear {
            noteLayout()
            lastStage = stage
        }
        .onChange(of: state.phase) {
            noteLayout()
            if let stage { lastStage = stage }
        }
    }

    private static func needsSetupLayout(_ phase: AppState.Phase) -> Bool {
        switch phase {
        case .needsSetup, .initializing, .error: return true
        case .checking, .warmingUp, .ready: return false
        }
    }

    private func noteLayout() {
        if Self.needsSetupLayout(state.phase) { showsSetupLayout = true }
    }

    // MARK: - Stages

    /// The stage currently running, derived from the install's one
    /// continuous progress fraction (see `BrowserInstallProgress` for the
    /// weights). The local-bake fallback and package installs report no
    /// fraction, so they sit in Install.
    private var stage: SetupStage? {
        switch state.phase {
        case .initializing(_, let progress):
            if state.installReason == .update { return .install }
            guard let progress else { return state.initSteps.isEmpty ? .download : .install }
            if progress < 0.55 { return .download }
            if progress < 0.78 { return .install }
            return .personalize
        case .warmingUp, .ready:
            return .launch
        case .checking, .needsSetup, .error:
            return nil
        }
    }

    private var isError: Bool {
        if case .error = state.phase { return true }
        return false
    }

    private func stageState(_ s: SetupStage) -> SetupRail.StepState {
        if isError, let lastStage {
            if s == lastStage { return .failed }
            return s.rawValue < lastStage.rawValue ? .done : .upcoming
        }
        guard let current = stage else { return .upcoming }
        if s == current { return .current }
        return s.rawValue < current.rawValue ? .done : .upcoming
    }

    // MARK: - Setup layout

    private var setupLayout: some View {
        HStack(spacing: 0) {
            SetupRail(steps: SetupStage.allCases.map { ($0.label, stageState($0)) })
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background)
        }
        .frame(width: Self.setupSize.width, height: Self.setupSize.height)
        .tint(Brand.blue)
    }

    @ViewBuilder
    private var pane: some View {
        switch state.phase {
        case .needsSetup:
            WelcomePane { state.startInit() }
        case .initializing(let status, let progress):
            ProgressPane(reason: state.installReason,
                         status: status, progress: progress,
                         steps: state.initSteps, consoleLog: state.consoleLog)
        case .warmingUp, .ready, .checking:
            ProgressPane(reason: state.installReason,
                         status: NSLocalizedString("Starting the browser engine…", comment: "Setup window status once the image is installed"),
                         progress: 1, launching: true,
                         steps: state.initSteps, consoleLog: state.consoleLog)
        case .error(let message):
            ErrorPane(message: message, consoleLog: state.consoleLog) {
                state.checkState()
            }
        }
    }
}

// MARK: - Brand

enum Brand {
    static let blue = Color(red: 0x58 / 255, green: 0x66 / 255, blue: 0xFE / 255)
    static let sky = Color(red: 0x93 / 255, green: 0xAE / 255, blue: 0xFF / 255)
    static let navy = Color(red: 0x33 / 255, green: 0x49 / 255, blue: 0x7B / 255)
    static let ink = Color(red: 0x1C / 255, green: 0x27 / 255, blue: 0x4C / 255)
    /// Brand blue for text and glyphs: the lighter sky tone in dark mode,
    /// where the full-strength blue reads too dim on the window background.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0x93 / 255, green: 0xAE / 255, blue: 1, alpha: 1)
            : NSColor(red: 0x58 / 255, green: 0x66 / 255, blue: 0xFE / 255, alpha: 1)
    })

    /// Fill behind the brand-colour surfaces (setup rail, starting splash):
    /// brand blue by day, navy by night.
    static func backdrop(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark ? [navy, ink] : [blue, Color(red: 0.29, green: 0.34, blue: 0.93)],
            startPoint: .top, endPoint: .bottom)
    }
}

/// The Bromure product symbol, drawn as a shape so it stays crisp at any
/// size and takes any fill (the app icon can't: on macOS 26
/// `applicationIconImage` comes back on a system plate). Generated from
/// "Product Symbol 01.svg", normalised to the mark's own bounds.
struct BromureMark: Shape {
    static let aspectRatio: CGFloat = 1.2626

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.7183, 0.5597))
        path.addLine(to: p(0.7183, 0.5602))
        path.addCurve(to: p(0.7059, 0.5651), control1: p(0.714, 0.5609), control2: p(0.7098, 0.5625))
        path.addCurve(to: p(0.5483, 0.7808), control1: p(0.6357, 0.6121), control2: p(0.5799, 0.688))
        path.addLine(to: p(0.4517, 0.7808))
        path.addCurve(to: p(0.2941, 0.5651), control1: p(0.42, 0.688), control2: p(0.3642, 0.6121))
        path.addCurve(to: p(0.2817, 0.5602), control1: p(0.2902, 0.5625), control2: p(0.286, 0.5609))
        path.addLine(to: p(0.2817, 0.5597))
        path.addLine(to: p(0, 0.5597))
        path.addLine(to: p(0, 0.9101))
        path.addCurve(to: p(0.0712, 1), control1: p(0, 0.9597), control2: p(0.0319, 1))
        path.addLine(to: p(0.9287, 1))
        path.addCurve(to: p(1, 0.9101), control1: p(0.9681, 1), control2: p(1, 0.9597))
        path.addLine(to: p(1, 0.5597))
        path.addLine(to: p(0.7183, 0.5597))
        path.closeSubpath()
        path.move(to: p(0.0712, 0))
        path.addCurve(to: p(0, 0.0899), control1: p(0.0319, 0), control2: p(0, 0.0403))
        path.addLine(to: p(0, 0.4168))
        path.addLine(to: p(0.292, 0.4168))
        path.addCurve(to: p(0.3114, 0.4102), control1: p(0.2988, 0.4168), control2: p(0.3056, 0.4146))
        path.addCurve(to: p(0.4473, 0.2192), control1: p(0.3704, 0.365), control2: p(0.4179, 0.2988))
        path.addLine(to: p(0.5527, 0.2192))
        path.addCurve(to: p(0.6886, 0.4102), control1: p(0.5821, 0.2988), control2: p(0.6296, 0.365))
        path.addCurve(to: p(0.708, 0.4168), control1: p(0.6944, 0.4146), control2: p(0.7011, 0.4168))
        path.addLine(to: p(1, 0.4168))
        path.addLine(to: p(1, 0.0899))
        path.addCurve(to: p(0.9288, 0), control1: p(1, 0.0403), control2: p(0.9681, 0))
        path.addLine(to: p(0.0712, 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Stages

enum SetupStage: Int, CaseIterable {
    case download, install, personalize, launch

    var label: String {
        switch self {
        case .download:    NSLocalizedString("Download", comment: "Setup stage")
        case .install:     NSLocalizedString("Install", comment: "Setup stage")
        case .personalize: NSLocalizedString("Personalize", comment: "Setup stage")
        case .launch:      NSLocalizedString("Launch", comment: "Setup stage")
        }
    }
}

// MARK: - Rail

/// Brand-colour rail: wordmark, the install stages joined by a track, and
/// the boundary rings from the brand artwork drawn behind them.
private struct SetupRail: View {
    enum StepState { case done, current, upcoming, failed }

    let steps: [(label: String, state: StepState)]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BromureMark()
                    .fill(.white)
                    .frame(width: 24, height: 24 / BromureMark.aspectRatio)
                Text(verbatim: "Bromure")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 34)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepRow(step.label, step.state, isLast: index == steps.count - 1)
            }

            Spacer(minLength: 0)

            Label {
                Text("Every window runs in its own disposable VM.")
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        }
        // Clears the traffic lights: the content runs under the titlebar.
        .padding(.top, 52)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .frame(width: 216, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { background }
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            Brand.backdrop(scheme)
            Canvas { ctx, size in
                // Three ring pairs (solid outer, dashed inner) stacked down
                // the rail, as in the brand artwork.
                let w = size.width * 1.9
                let h = w * 0.62
                for i in 0..<3 {
                    let cy = size.height * (0.84 + 0.2 * CGFloat(i))
                    let outer = CGRect(x: (size.width - w) / 2, y: cy - h / 2, width: w, height: h)
                    ctx.stroke(Path(ellipseIn: outer), with: .color(.white.opacity(0.16)), lineWidth: 1.2)
                    let inner = outer.insetBy(dx: w * 0.14, dy: h * 0.2)
                    ctx.stroke(Path(ellipseIn: inner), with: .color(.white.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                }
            }
        }
    }

    private func stepRow(_ label: String, _ state: StepState, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                indicator(state)
                if !isLast {
                    Rectangle()
                        .fill(.white.opacity(state == .done ? 0.7 : 0.22))
                        .frame(width: 1.5, height: 22)
                }
            }
            Text(label)
                .font(.system(size: 13, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(.white.opacity(state == .upcoming ? 0.55 : 1))
                .padding(.top, 1)
        }
        .animation(.easeInOut(duration: 0.3), value: state)
    }

    @ViewBuilder
    private func indicator(_ state: StepState) -> some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(.white)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Brand.blue)
            case .current:
                Circle().stroke(.white, lineWidth: 1.5)
                PulsingDot()
            case .upcoming:
                Circle().stroke(.white.opacity(0.4), lineWidth: 1.5)
            case .failed:
                Circle().fill(.white)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 8, height: 8)
            .scaleEffect(on ? 1 : 0.6)
            .opacity(on ? 1 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true }
            }
    }
}

// MARK: - Panes

/// Eyebrow + title + subtitle, shared so every pane lines up.
private struct PaneHeader: View {
    let eyebrow: String
    var eyebrowColor: Color = Brand.accent
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(eyebrowColor)
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePane: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(
                eyebrow: NSLocalizedString("Welcome", comment: "Setup window eyebrow"),
                title: NSLocalizedString("Browse without leaving a trace", comment: "Setup window welcome title"),
                subtitle: NSLocalizedString("Bromure opens every window in its own throwaway Linux VM. Close it, and everything it touched is gone.", comment: "Setup window welcome subtitle"))
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 16) {
                feature("square.stack.3d.up.fill",
                        NSLocalizedString("Isolated by design", comment: "Setup feature title"),
                        NSLocalizedString("Sites run in a separate VM, never on your Mac.", comment: "Setup feature detail"))
                feature("sparkles",
                        NSLocalizedString("Fresh every time", comment: "Setup feature title"),
                        NSLocalizedString("Each session starts from a clean image — or keep a profile when you want one.", comment: "Setup feature detail"))
                feature("bolt.fill",
                        NSLocalizedString("Ready in a second", comment: "Setup feature title"),
                        NSLocalizedString("A VM is always warmed up, so new windows open instantly.", comment: "Setup feature detail"))
            }

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                Text("One-time download, personalized for this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onStart) {
                    Text("Get Started").padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 28)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 32, height: 32)
                .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProgressPane: View {
    let reason: AppState.InstallReason
    let status: String
    let progress: Double?
    var launching = false
    let steps: [AppState.InitStep]
    let consoleLog: String

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(eyebrow: eyebrow, title: title, subtitle: subtitle)
                .padding(.bottom, 28)

            if let progress, !launching {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: "\(Int(progress * 100))")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress))
                        .animation(.snappy, value: Int(progress * 100))
                    Text(verbatim: "%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)
            }

            BrandProgressBar(value: launching ? nil : progress)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                if launching || progress == nil {
                    ProgressView().controlSize(.mini)
                }
                Text(LocalizedStringKey(status))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            if showsDetails {
                DetailsBox(steps: steps, consoleLog: consoleLog)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 12)
            }

            HStack {
                Button {
                    withAnimation(.snappy) { showsDetails.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        Text(showsDetails ? "Hide Details" : "Show Details")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(steps.isEmpty && consoleLog.isEmpty)

                Spacer()

                Text("A browser window opens as soon as it's ready.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 24)
    }

    private var eyebrow: String {
        switch reason {
        case .firstRun: NSLocalizedString("First-time setup", comment: "Setup window eyebrow")
        case .rebuild:  NSLocalizedString("Rebuilding", comment: "Setup window eyebrow")
        case .refresh:  NSLocalizedString("Updating", comment: "Setup window eyebrow")
        case .update:   NSLocalizedString("Updating", comment: "Setup window eyebrow")
        }
    }

    private var title: String {
        if launching {
            return NSLocalizedString("Almost there", comment: "Setup window title while the engine starts")
        }
        switch reason {
        case .firstRun: return NSLocalizedString("Setting up Bromure", comment: "Setup window title")
        case .rebuild:  return NSLocalizedString("Rebuilding your browser image", comment: "Setup window title")
        case .refresh:  return NSLocalizedString("Updating your browser image", comment: "Setup window title")
        case .update:   return NSLocalizedString("Updating your browser image", comment: "Setup window title")
        }
    }

    private var subtitle: String {
        if launching {
            return NSLocalizedString("The image is ready. Warming up the first VM so your browser opens instantly.", comment: "Setup window subtitle while the engine starts")
        }
        switch reason {
        case .firstRun:
            return NSLocalizedString("Downloading the Linux + Chromium image and personalizing it for this Mac. This only happens once.", comment: "Setup window subtitle")
        case .rebuild:
            return NSLocalizedString("The old image was removed. A fresh copy is being downloaded and personalized for this Mac.", comment: "Setup window subtitle")
        case .refresh:
            return NSLocalizedString("Fetching the latest image, with current Linux and browser security updates.", comment: "Setup window subtitle")
        case .update:
            return NSLocalizedString("Bringing your browser image up to date with this version of Bromure.", comment: "Setup window subtitle")
        }
    }
}

private struct ErrorPane: View {
    let message: String
    let consoleLog: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(
                eyebrow: NSLocalizedString("Setup stopped", comment: "Setup window eyebrow on error"),
                eyebrowColor: .red,
                title: NSLocalizedString("Something went wrong", comment: "Setup window error title"),
                subtitle: NSLocalizedString("The browser image couldn't be installed. Check your connection and try again.", comment: "Setup window error subtitle"))
                .padding(.bottom, 22)

            ScrollView {
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.red.opacity(0.18)))

            Spacer(minLength: 0)

            HStack {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        consoleLog.isEmpty ? message : message + "\n\n" + consoleLog,
                        forType: .string)
                }
                .controlSize(.large)
                Spacer()
                Button(action: onRetry) {
                    Text("Try Again").padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 28)
    }
}

/// Collapsible step checklist + console tail.
private struct DetailsBox: View {
    let steps: [AppState.InitStep]
    let consoleLog: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps.suffix(4)) { step in
                        HStack(spacing: 7) {
                            if step.done {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Text(LocalizedStringKey(step.name))
                                .foregroundStyle(step.done ? .secondary : .primary)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            if !consoleLog.isEmpty {
                ZStack(alignment: .topTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(consoleLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(8)
                                .id("console-bottom")
                        }
                        .onChange(of: consoleLog) {
                            proxy.scrollTo("console-bottom", anchor: .bottom)
                        }
                        .onAppear { proxy.scrollTo("console-bottom", anchor: .bottom) }
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(consoleLog, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the console output")
                    .padding(6)
                }
                .frame(height: 96)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// Capsule progress bar in the brand gradient. `nil` animates a sweeping
/// segment for work that reports no fraction.
private struct BrandProgressBar: View {
    let value: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if let value {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                        .animation(.easeOut(duration: 0.4), value: value)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                        let w = geo.size.width * 0.3
                        Capsule()
                            .fill(fill)
                            .frame(width: w)
                            .offset(x: -w + (geo.size.width + w) * phase)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: height)
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [Brand.sky, Brand.blue], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Starting panel

/// Normal launch: a small splash that the first browser window replaces
/// within seconds. Deliberately not the setup layout, so it never reads
/// as a launcher. Rings ripple out from the mark while the pool's first
/// VM boots.
private struct StartingPanel: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Brand.backdrop(scheme)
                TimelineView(.animation) { context in
                    Canvas { ctx, size in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        for i in 0..<4 {
                            // Each ring grows from behind the mark and fades
                            // as it nears the edges; solid and dashed
                            // alternate, as in the brand artwork.
                            let p = CGFloat((t / 3.6 + Double(i) / 4).truncatingRemainder(dividingBy: 1))
                            let w = 90 + p * size.width * 1.05
                            let h = w * 0.62
                            let ring = Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - h / 2,
                                                              width: w, height: h))
                            let color = GraphicsContext.Shading.color(.white.opacity(0.32 * (1 - p)))
                            if i.isMultiple(of: 2) {
                                ctx.stroke(ring, with: color, lineWidth: 1.2)
                            } else {
                                ctx.stroke(ring, with: color,
                                           style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                            }
                        }
                    }
                }
                BromureMark()
                    .fill(.white)
                    .frame(width: 54, height: 54 / BromureMark.aspectRatio)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
            .frame(height: 150)
            .clipped()

            VStack(spacing: 6) {
                Text("Starting Bromure")
                    .font(.system(size: 15, weight: .semibold))
                Text("Warming up a fresh VM. The first window after launch takes a few seconds longer.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                BrandProgressBar(value: nil, height: 4)
                    .frame(width: 120)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .frame(width: 360)
        .background(.background)
    }
}

// MARK: - Debug preview

extension AppState {
    /// `BROMURE_DEBUG_SETUP_UI=<kind>` puts the setup window in a canned
    /// state so it can be reviewed without deleting the base image:
    /// welcome, download, personalize, bake, rebuild, launch, error,
    /// starting. Returns false for an unknown kind.
    func applySetupPreview(_ kind: String) -> Bool {
        let steps = [InitStep(name: "Fetching image catalog", done: true),
                     InitStep(name: "Downloading image", done: true),
                     InitStep(name: "Personalizing image", done: false)]
        let log = "[browser-postinstall] mounting installed system\n[browser-postinstall] personalising: keyboard=us locale=en_US\n[browser-postinstall] copied 213 macOS font files\n"
        switch kind {
        case "welcome":
            phase = .needsSetup
        case "download":
            installReason = .firstRun
            initSteps = Array(steps.prefix(2)); initSteps[1].done = false
            phase = .initializing(status: "Downloading Ubuntu 24.04 + Chromium image (1.5 GB)…", progress: 0.37)
        case "personalize":
            installReason = .firstRun
            initSteps = steps; consoleLog = log
            phase = .initializing(status: "Personalizing (keyboard, language, fonts)…", progress: 0.86)
        case "bake":
            installReason = .firstRun
            initSteps = steps; consoleLog = log
            phase = .initializing(status: "Installing packages...", progress: nil)
        case "rebuild":
            installReason = .rebuild
            initSteps = Array(steps.prefix(2)); initSteps[1].done = false
            phase = .initializing(status: "Downloading Ubuntu 24.04 + Chromium image (1.5 GB)…", progress: 0.21)
        case "launch":
            installReason = .rebuild
            initSteps = steps.map { var s = $0; s.done = true; return s }; consoleLog = log
            phase = .initializing(status: "Finalizing…", progress: 0.99)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.phase = .warmingUp }
        case "error":
            initSteps = steps; consoleLog = log
            phase = .initializing(status: "Downloading…", progress: 0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.phase = .error("The network connection was lost. (NSURLErrorDomain -1005)")
            }
        case "starting":
            phase = .warmingUp
        default:
            return false
        }
        return true
    }
}
