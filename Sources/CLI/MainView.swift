import SwiftUI
import SandboxEngine

struct MainView: View {
    @Bindable var state: AppState
    var onNewBrowser: @MainActor () -> Void
    @State private var buttonCooldown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440, height: 420)
        .background(.background)
        .onAppear {
            state.checkState()
        }
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

        case .warmingUp:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting browser engine...")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .padding()

        case .ready:
            readyView

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
                Text("Downloads Alpine Linux (~50 MB) and installs\nChromium. This only needs to happen once.")
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
                        Text(step.name)
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

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 16) {
            Button {
                onNewBrowser()
                buttonCooldown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    buttonCooldown = false
                }
            } label: {
                Label("New Browser", systemImage: "plus.rectangle")
                    .frame(width: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n")
            .disabled(buttonCooldown)

            HStack(spacing: 20) {
                Label {
                    Text(state.poolReady ? "Ready" : "Warming up...")
                        .font(.caption)
                } icon: {
                    Image(systemName: state.poolReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(state.poolReady ? .green : .orange)
                        .font(.caption)
                }

                if state.sessionCount > 0 {
                    Label {
                        Text("\(state.sessionCount) open")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "macwindow")
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 60)

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Each window runs in an isolated, disposable VM")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
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
