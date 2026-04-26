import SwiftUI
import SandboxEngine

/// Status of a single vsock service for display in the diagnostic window.
struct VsockServiceStatus: Identifiable {
    let id: String
    let name: String
    let port: UInt32
    let state: State

    enum State {
        /// The host listener is registered but the guest has not connected yet.
        case listening
        /// The guest agent has connected and is active.
        case connected
        /// The service is not enabled for this session.
        case disabled
    }

    var stateLabel: String {
        switch state {
        case .listening: "Listening"
        case .connected: "Connected"
        case .disabled: "Disabled"
        }
    }

    var stateColor: Color {
        switch state {
        case .listening: .orange
        case .connected: .green
        case .disabled: .secondary
        }
    }

    var stateIcon: String {
        switch state {
        case .listening: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .disabled: "minus.circle"
        }
    }
}

/// A snapshot of all vsock services for one browser session.
struct SessionDiagnostic: Identifiable {
    let id: UUID
    let name: String
    var services: [VsockServiceStatus]
}

/// SwiftUI view showing vsock service status for all active VM sessions.
struct VsockDiagnosticView: View {
    @State private var diagnostics: [SessionDiagnostic] = []
    @State private var refreshTimer: Timer?

    let sessionProvider: () -> [SessionDiagnostic]

    var body: some View {
        Group {
            if diagnostics.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(diagnostics) { session in
                            SessionCard(session: session)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear {
            diagnostics = sessionProvider()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    diagnostics = sessionProvider()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
}

private struct SessionCard: View {
    let session: SessionDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.name)
                .font(.headline)

            let enabled = session.services.filter { $0.state != .disabled }
            let disabled = session.services.filter { $0.state == .disabled }

            if !enabled.isEmpty {
                ForEach(enabled) { service in
                    ServiceRow(service: service)
                }
            }

            if !disabled.isEmpty {
                DisclosureGroup {
                    ForEach(disabled) { service in
                        ServiceRow(service: service)
                    }
                } label: {
                    Text("\(disabled.count) disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ServiceRow: View {
    let service: VsockServiceStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: service.stateIcon)
                .foregroundStyle(service.stateColor)
                .frame(width: 16)

            Text(service.name)
                .font(.system(.body, design: .default))

            Spacer()

            Text(verbatim: ":\(service.port)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(service.stateLabel)
                .font(.caption)
                .foregroundStyle(service.stateColor)
                .frame(width: 70, alignment: .trailing)
        }
    }
}
