import Foundation
import SandboxEngine
import Virtualization

private let paDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_PHISHING"] != nil

/// Bridges phishing analysis requests from the guest VM phishing-guard extension
/// to a local HTTP analysis server powered by an LLM.
///
/// Protocol: newline-delimited JSON on vsock port 5950.
///
/// Flow: guest extension detects suspicious page → extracts structured signals →
/// sends via native messaging → phishing-agent.py relays over vsock → this bridge
/// forwards to the analysis server HTTP endpoint → relays verdict back.
@MainActor
public final class PhishingAnalysisBridge: NSObject, @unchecked Sendable {
    private static let phishingPort: UInt32 = 5950

    /// Max pending data from guest (256 KB — analysis payloads are small).
    private static let maxPendingData = 262_144

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: PhishingListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?

    /// Default server base URL.
    public nonisolated static let defaultServerBaseURL = URL(string: "https://bromure.io/api")!

    /// UserDefaults key for overriding the server URL.
    public nonisolated static let serverURLKey = "phishingAnalysis.serverURL"

    /// Base URL of the phishing analysis server (without path).
    public var serverBaseURL: URL

    /// Whether the bridge is enabled. When false, analysis requests are ignored.
    public var enabled: Bool = true

    /// Whether the guest agent is connected.
    public var isConnected: Bool { connection != nil }

    public init(socketDevice: VZVirtioSocketDevice, serverBaseURL: URL? = nil) {
        if let explicit = serverBaseURL {
            self.serverBaseURL = explicit
        } else if let saved = UserDefaults.standard.string(forKey: Self.serverURLKey),
                  let url = URL(string: saved) {
            self.serverBaseURL = url
        } else {
            self.serverBaseURL = Self.defaultServerBaseURL
        }
        super.init()

        if paDebug { print("[PhishingAnalysis] init: setting up vsock listener on port \(Self.phishingPort)") }

        let delegate = PhishingListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.phishingPort)
    }

    public func stop() {
        if paDebug { print("[PhishingAnalysis] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.phishingPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if paDebug { print("[PhishingAnalysis] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if paDebug { print("[PhishingAnalysis] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            if pendingData.count > Self.maxPendingData {
                if paDebug { print("[PhishingAnalysis] buffer overflow — disconnecting") }
                pendingData.removeAll()
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])
                if !lineData.isEmpty {
                    self.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            self?.readSource = nil
            self?.connection = nil
        }

        source.resume()
        readSource = source
    }

    private func handleMessage(_ jsonData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String,
              let requestId = json["requestId"] as? String else {
            if paDebug { print("[PhishingAnalysis] invalid message") }
            return
        }

        switch type {
        case "register":
            Task { await self.handleRegister(requestId: requestId) }

        case "registerSolve":
            let challengeId = json["challengeId"] as? String ?? ""
            let nonce = json["nonce"]
            Task { await self.handleRegisterSolve(requestId: requestId, challengeId: challengeId, nonce: nonce) }

        case "analyze":
            guard enabled else {
                sendError(requestId: requestId, error: "disabled")
                return
            }
            let token = json["token"] as? String
            guard let payload = json["payload"] as? [String: Any] else {
                sendError(requestId: requestId, error: "missing_payload")
                return
            }
            if paDebug {
                let domain = payload["domain"] as? String ?? "?"
                print("[PhishingAnalysis] analyzing domain: \(domain) requestId=\(requestId)")
            }
            Task { await self.forwardAnalysis(requestId: requestId, token: token, payload: payload) }

        default:
            if paDebug { print("[PhishingAnalysis] unknown type: \(type)") }
            sendError(requestId: requestId, error: "unknown_type")
        }
    }

    // MARK: - Registration forwarding

    private func handleRegister(requestId: String) async {
        let url = serverBaseURL.appendingPathComponent("v1/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendResponse(["type": "registerResult", "requestId": requestId, "error": "server_error"])
                return
            }

            var resp: [String: Any] = ["type": "registerResult", "requestId": requestId]
            resp["challenge"] = result["challenge"]
            resp["challengeId"] = result["challengeId"]
            resp["difficulty"] = result["difficulty"]
            sendResponse(resp)
        } catch {
            if paDebug { print("[PhishingAnalysis] register error: \(error.localizedDescription)") }
            sendResponse(["type": "registerResult", "requestId": requestId, "error": "network_error"])
        }
    }

    private func handleRegisterSolve(requestId: String, challengeId: String, nonce: Any?) async {
        let url = serverBaseURL.appendingPathComponent("v1/register/solve")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = ["challengeId": challengeId, "nonce": nonce ?? ""]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            sendResponse(["type": "registerResult", "requestId": requestId, "error": "serialization_error"])
            return
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = result["token"] as? String else {
                let errData = try? JSONSerialization.jsonObject(with: (response as? HTTPURLResponse).flatMap { _ in data } ?? Data()) as? [String: Any]
                let errMsg = (errData?["error"] as? String) ?? "solve_failed"
                sendResponse(["type": "registerResult", "requestId": requestId, "error": errMsg])
                return
            }

            sendResponse(["type": "registerResult", "requestId": requestId, "token": token])
        } catch {
            if paDebug { print("[PhishingAnalysis] registerSolve error: \(error.localizedDescription)") }
            sendResponse(["type": "registerResult", "requestId": requestId, "error": "network_error"])
        }
    }

    // MARK: - Analysis forwarding

    private func forwardAnalysis(requestId: String, token: String?, payload: [String: Any]) async {
        let url = serverBaseURL.appendingPathComponent("v1/analyze")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            sendError(requestId: requestId, error: "serialization_error")
            return
        }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                sendError(requestId: requestId, error: "invalid_response")
                return
            }

            // Parse the response body regardless of status code
            let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            switch httpResponse.statusCode {
            case 200:
                guard let verdict = result["verdict"] as? String else {
                    sendError(requestId: requestId, error: "invalid_server_response")
                    return
                }
                let confidence = result["confidence"] as? Double ?? 0
                let reason = result["reason"] as? String ?? ""
                if paDebug { print("[PhishingAnalysis] verdict: \(verdict) confidence: \(confidence)") }
                sendResponse([
                    "type": "analysisResult",
                    "requestId": requestId,
                    "verdict": verdict,
                    "confidence": confidence,
                    "reason": reason,
                ])

            case 429:
                // Per-token daily limit
                sendResponse([
                    "type": "analysisResult",
                    "requestId": requestId,
                    "error": "token_limit",
                    "reason": result["reason"] as? String ?? "Daily limit reached.",
                ])

            case 401:
                // Token rejected — tell extension to re-register
                sendResponse([
                    "type": "analysisResult",
                    "requestId": requestId,
                    "error": "invalid_token",
                ])

            case 503:
                // Global degraded mode
                sendResponse([
                    "type": "analysisResult",
                    "requestId": requestId,
                    "error": "degraded",
                    "reason": result["reason"] as? String ?? "Service in degraded mode.",
                ])

            default:
                if paDebug { print("[PhishingAnalysis] server returned \(httpResponse.statusCode)") }
                sendError(requestId: requestId, error: "server_error_\(httpResponse.statusCode)")
            }
        } catch {
            if paDebug { print("[PhishingAnalysis] HTTP error: \(error.localizedDescription)") }
            sendError(requestId: requestId, error: "network_error")
        }
    }

    // MARK: - Response sending

    private func sendResponse(_ envelope: [String: Any]) {
        guard let conn = connection else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var frame = jsonData
        frame.append(UInt8(ascii: "\n"))

        let fd = conn.fileDescriptor
        frame.withUnsafeBytes { ptr in
            var offset = 0
            while offset < frame.count {
                let written = Darwin.write(fd, ptr.baseAddress! + offset, frame.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func sendError(requestId: String, error: String) {
        sendResponse([
            "type": "analysisResult",
            "requestId": requestId,
            "verdict": "error",
            "error": error,
        ])
    }
}

// MARK: - VZVirtioSocketListenerDelegate

private final class PhishingListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if paDebug { print("[PhishingAnalysis] accepting connection from port \(connection.sourcePort)") }
        onConnection(connection)
        return true
    }
}
