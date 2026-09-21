import SwiftUI
import SandboxEngine

/// First-run / maintenance window: image download, local bake, warm-up and
/// error states. Only shown while the browser engine isn't ready — once
/// the pool is warm the app opens browser windows directly (profiles are
/// picked from the tab-bar chip or the File menu), so there is no
/// launcher any more.
struct MainView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(width: 440, height: 420)
        }
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Bromure")
                .font(.title.bold())

            Text("Secure, ephemeral browsing in a disposable VM")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.blue.gradient.opacity(0.04))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .checking:
            ProgressView()
                .padding()

        case .needsSetup:
            setupView

        case .initializing(let status, let progress):
            initializingView(status: status, progress: progress)

        case .warmingUp, .ready:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting browser engine...")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text("First launch is slower, subsequent ones will be faster.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding()

        case .error(let message):
            errorView(message: message)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("First-Time Setup")
                    .font(.headline)
                Text("Downloads the browser image (Linux + Chromium)\nand personalizes it for your Mac. This only needs to happen once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                state.startInit()
            } label: {
                Label("Get Started", systemImage: "arrow.down.circle")
                    .frame(width: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Initializing

    private func initializingView(status: String, progress: Double?) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.initSteps) { step in
                    HStack(spacing: 8) {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.body)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(LocalizedStringKey(step.name))
                            .font(.subheadline)
                            .foregroundStyle(step.done ? .secondary : .primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)

            if let progress {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 40)
            }

            Text(LocalizedStringKey(status))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !state.consoleLog.isEmpty {
                DisclosureGroup("Console Output") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(state.consoleLog)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("console-bottom")
                        }
                        .frame(height: 100)
                        .onChange(of: state.consoleLog) {
                            proxy.scrollTo("console-bottom", anchor: .bottom)
                        }
                    }
                }
                .font(.caption)
                .padding(.horizontal, 40)
            }
        }
        .padding()
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") {
                state.checkState()
            }
            .controlSize(.regular)
        }
        .padding()
    }
}
