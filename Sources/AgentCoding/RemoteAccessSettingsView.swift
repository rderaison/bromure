import SwiftUI

/// Preferences → Remote Access. App-global settings for the optional SSH front
/// door. Talks to the app delegate via the injected closures (each returns a
/// status dict; an `error` key means it failed).
struct RemoteAccessSettingsView: View {
    let status: () -> [String: Any]
    let apply: ([String: Any]) -> [String: Any]
    let addKey: (String) -> [String: Any]
    let removeKey: (String) -> [String: Any]

    @State private var enabled = false
    @State private var running = false
    @State private var port = "2222"
    @State private var bindAddress = "0.0.0.0"
    @State private var passwordAuth = true
    @State private var pubkeyAuth = true
    @State private var fingerprint = ""
    @State private var connect = ""
    @State private var keys: [[String: Any]] = []
    @State private var newKey = ""
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                authSection
                Divider()
                hostKeySection
                Divider()
                keysSection
                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.callout)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 520)
        .onAppear(perform: refresh)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { enabled }, set: { setEnabled($0) })) {
                Text("Enable remote access over SSH").font(.headline)
            }
            Text("Runs an app-owned instance of the system SSH server — no need to turn on macOS Remote Login, and no admin rights. Disabled by default. Every login lands in the bromure-ac menu; a raw shell is never reachable.")
                .font(.callout).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Circle().fill(running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(running ? "sshd running" : "sshd stopped").font(.caption).foregroundColor(.secondary)
            }
            if enabled {
                HStack {
                    Text(connect).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        let pb = NSPasteboard.general; pb.clearContents(); pb.setString(connect, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Listener").font(.headline)
            HStack {
                Text("Bind IP").frame(width: 70, alignment: .leading)
                TextField("0.0.0.0", text: $bindAddress, onCommit: applyConfig)
                    .frame(width: 160)
                Text("Port").frame(width: 40, alignment: .trailing)
                TextField("2222", text: $port, onCommit: applyConfig)
                    .frame(width: 80)
            }
            Text("0.0.0.0 = reachable from any interface. Use a specific IP or 127.0.0.1 to restrict. Port must be ≥ 1024.")
                .font(.caption).foregroundColor(.secondary)

            Text("Authentication").font(.headline).padding(.top, 4)
            Toggle("macOS account password", isOn: Binding(get: { passwordAuth }, set: { passwordAuth = $0; applyConfig() }))
            Toggle("Public key", isOn: Binding(get: { pubkeyAuth }, set: { pubkeyAuth = $0; applyConfig() }))
            Text("Verified against \(NSUserName()) — the user running bromure-ac.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var hostKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server host key").font(.headline)
            Text(fingerprint.isEmpty ? "(generated on first enable)" : fingerprint)
                .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authorized public keys").font(.headline)
            if keys.isEmpty {
                Text("No keys enrolled.").font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(Array(keys.enumerated()), id: \.offset) { idx, k in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(k["fingerprint"] as? String ?? "?")
                                .font(.system(.caption, design: .monospaced))
                            if let c = k["comment"] as? String, !c.isEmpty {
                                Text(c).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            handle(removeKey(String(idx + 1)))
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Paste an SSH public key (ssh-ed25519 …)", text: $newKey)
                Button("Add") {
                    let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let r = addKey(trimmed)
                    if r["error"] == nil { newKey = "" }
                    handle(r)
                }
            }
        }
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        enabled = on
        handle(apply(["enabled": on,
                      "port": Int(port) ?? 2222,
                      "bindAddress": bindAddress,
                      "passwordAuth": passwordAuth,
                      "pubkeyAuth": pubkeyAuth]))
    }

    private func applyConfig() {
        var spec: [String: Any] = ["bindAddress": bindAddress,
                                   "passwordAuth": passwordAuth,
                                   "pubkeyAuth": pubkeyAuth]
        if let p = Int(port) { spec["port"] = p }
        handle(apply(spec))
    }

    private func refresh() { handle(status(), clearError: false) }

    /// Fold a status/result dict back into the view state.
    private func handle(_ result: [String: Any], clearError: Bool = true) {
        if let err = result["error"] as? String { errorText = err; return }
        if clearError { errorText = nil }
        // A bare {ok:true} (key add/remove) → re-pull full status.
        let s = result["enabled"] == nil ? status() : result
        enabled = s["enabled"] as? Bool ?? enabled
        running = s["running"] as? Bool ?? running
        if let p = s["port"] as? Int { port = String(p) }
        bindAddress = s["bindAddress"] as? String ?? bindAddress
        passwordAuth = s["passwordAuth"] as? Bool ?? passwordAuth
        pubkeyAuth = s["pubkeyAuth"] as? Bool ?? pubkeyAuth
        fingerprint = s["fingerprint"] as? String ?? fingerprint
        connect = s["connect"] as? String ?? connect
        keys = s["authorizedKeys"] as? [[String: Any]] ?? keys
    }
}
