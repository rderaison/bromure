import Foundation

/// The control-socket client the shared remote menu (RemoteMenu.swift)
/// drives: macOS's ControlClient interface (Foundation JSON documents) over
/// this daemon's ControlClient. Its socket is this user's daemon's
/// (DaemonConfig: BROMURE_AC_CONTROL_SOCKET, else $XDG_RUNTIME_DIR/bromure-ac).
// @port-skip linux-only: macOS's menu uses the CLI's ControlClient (typealias RemoteMenuClient)
struct RemoteMenuClient {
    let control: ControlClient

    struct Response { let status: Int; let json: [String: Any] }

    // @port-skip linux-only: the socket from this daemon's config
    init(socketPath: String? = nil) {
        control = ControlClient(socketPath: socketPath ?? DaemonConfig.fromEnvironment().controlSocketPath)
    }

    // @port ControlClient.request(_: String, _: String, body: [String:Any]?, recvTimeoutSeconds: Int, extraHeaders: [(String,String)]) h=31fec0f632bad9d4 @1b984d09
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Response {
        let r = try control.request(method, path, body: body.flatMap { JSONValue(foundation: $0) })
        return Response(status: r.status, json: r.json.foundationObject as? [String: Any] ?? [:])
    }

    // @port-skip linux-only: forwards to ControlClient.isAgentRunning (claimed there)
    func isAgentRunning() -> Bool { control.isAgentRunning() }

    /// macOS starts a headless agent; here the daemon is a systemd service,
    /// and the SSH server this menu runs under lives in it.
    // partial: doesn't start the daemon (a systemd service); says how
    // @port ControlClient.ensureAgentRunning(timeout: TimeInterval) h=de095f5726837b0f @1b984d09
    func ensureAgentRunning(timeout: TimeInterval = 40) throws {
        if isAgentRunning() { return }
        throw ControlClient.ClientError.protocolError(
            "the bromure-ac daemon isn't running (start it: systemctl --user start bromure-ac)")
    }
}
