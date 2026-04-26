import CommonCrypto
import Foundation
import SandboxEngine

/// Status of a VirusTotal scan.
public enum ScanStatus: Equatable, Sendable {
    case pending
    case scanning
    case clean
    case threat(positives: Int, total: Int)
}

/// Result of a VirusTotal file scan or hash lookup.
public struct VirusTotalResult: Sendable {
    public let sha256: String
    public let positives: Int
    public let total: Int
    public let scanDate: Date?
    public let permalink: String?
    public let status: ScanStatus
}

/// Errors specific to VirusTotal API operations.
public enum VirusTotalError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case notFound
    case uploadFailed(statusCode: Int)
    case fileTooLarge(sizeMB: Int)
    case analysisError(String)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "VirusTotal API key is not configured."
        case .invalidAPIKey:
            return "The VirusTotal API key is invalid. Sign up for a free key at https://www.virustotal.com/gui/join-us"
        case .rateLimited:
            return "VirusTotal rate limit exceeded. Please wait before retrying."
        case .notFound:
            return "File not found in VirusTotal database."
        case .uploadFailed(let code):
            return "VirusTotal upload failed with status code \(code)."
        case .fileTooLarge(let sizeMB):
            return "File too large for VirusTotal upload (\(sizeMB) MB). Hash lookup returned no results."
        case .analysisError(let msg):
            return "VirusTotal analysis error: \(msg)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

/// Client for the VirusTotal v3 API.
///
/// Supports file hash lookups, file uploads, and analysis polling.
/// Rate-limited to 4 requests per minute (free tier).
public final class VirusTotalClient: @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = "https://www.virustotal.com/api/v3"

    /// Minimum interval between requests (4 req/min = 15 seconds).
    private let requestInterval: TimeInterval = 15.0
    private let rateLimiter = RateLimiter(interval: 15.0)

    public init(apiKey: String) throws {
        guard !apiKey.isEmpty else { throw VirusTotalError.missingAPIKey }
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
    }

    /// Validate an API key by hitting GET /users/me.
    /// Throws `invalidAPIKey` for 401/403, or a network error on failure.
    public static func validateAPIKey(_ key: String) async throws {
        guard !key.isEmpty else { throw VirusTotalError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/users/me")!)
        request.setValue(key, forHTTPHeaderField: "x-apikey")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VirusTotalError.networkError(
                NSError(domain: "VirusTotal", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            )
        }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw VirusTotalError.invalidAPIKey
        case 429: throw VirusTotalError.rateLimited
        default: throw VirusTotalError.uploadFailed(statusCode: http.statusCode)
        }
    }

    // MARK: - Public API

    /// Look up a file by SHA-256 hash without uploading.
    ///
    /// Returns a result if the file is already known to VirusTotal,
    /// or throws `VirusTotalError.notFound` if it has never been scanned.
    public func lookupHash(_ sha256: String) async throws -> VirusTotalResult {
        let url = URL(string: "\(baseURL)/files/\(sha256)")!
        let data = try await performRequest(URLRequest(url: url))
        return try parseFileReport(data, sha256: sha256)
    }

    /// Upload a file to VirusTotal for scanning.
    ///
    /// Returns the analysis ID that can be polled with `checkAnalysis(_:)`.
    public func uploadFile(data fileData: Data, filename: String) async throws -> String {
        let url = URL(string: "\(baseURL)/files")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let responseData = try await performRequest(request)
        return try parseUploadResponse(responseData)
    }

    /// Check the status of a pending analysis.
    public func checkAnalysis(_ analysisID: String) async throws -> VirusTotalResult {
        let url = URL(string: "\(baseURL)/analyses/\(analysisID)")!
        let data = try await performRequest(URLRequest(url: url))
        return try parseAnalysisResponse(data)
    }

    /// Scan a file end-to-end: check hash first, upload if unknown, poll until done.
    ///
    /// This is the main entry point for scanning a downloaded file.
    /// Maximum file size for upload (32 MB, VirusTotal free tier limit).
    private static let maxUploadSize = 32 * 1024 * 1024

    public func scanFile(at fileURL: URL) async throws -> VirusTotalResult {
        let fileData = try Data(contentsOf: fileURL)
        let hash = Self.sha256(of: fileData)

        // Try hash lookup first to avoid unnecessary upload
        do {
            let result = try await lookupHash(hash)
            if result.status != .pending && result.status != .scanning {
                return result
            }
        } catch VirusTotalError.notFound {
            // Not in database — need to upload (if small enough)
        }

        // Skip upload for files exceeding VirusTotal's size limit
        guard fileData.count <= Self.maxUploadSize else {
            throw VirusTotalError.fileTooLarge(sizeMB: fileData.count / (1024 * 1024))
        }

        // Upload the file
        let filename = fileURL.lastPathComponent
        let analysisID = try await uploadFile(data: fileData, filename: filename)

        // Poll for results (max ~5 minutes)
        for _ in 0..<20 {
            let result = try await checkAnalysis(analysisID)
            switch result.status {
            case .pending, .scanning:
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                continue
            default:
                return result
            }
        }

        // Timed out waiting — return last known state
        return try await checkAnalysis(analysisID)
    }

    // MARK: - SHA-256

    /// Compute the SHA-256 hash of in-memory data.
    public static func sha256(of data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Request Execution

    /// Perform a request with rate limiting and API key header.
    private func performRequest(_ request: URLRequest) async throws -> Data {
        await enforceRateLimit()

        var req = request
        req.setValue(apiKey, forHTTPHeaderField: "x-apikey")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw VirusTotalError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw VirusTotalError.networkError(
                NSError(domain: "VirusTotal", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response type",
                ])
            )
        }

        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw VirusTotalError.notFound
        case 429:
            throw VirusTotalError.rateLimited
        default:
            throw VirusTotalError.uploadFailed(statusCode: http.statusCode)
        }
    }

    /// Wait if needed to respect the rate limit.
    private func enforceRateLimit() async {
        let delay = await rateLimiter.nextDelay()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    // MARK: - Response Parsing

    /// Parse a file report from GET /files/{sha256}.
    private func parseFileReport(_ data: Data, sha256: String) throws -> VirusTotalResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attrs = (json["data"] as? [String: Any])?["attributes"] as? [String: Any]
        else {
            throw VirusTotalError.analysisError("Invalid file report response")
        }

        let stats = attrs["last_analysis_stats"] as? [String: Int] ?? [:]
        let malicious = stats["malicious"] ?? 0
        let suspicious = stats["suspicious"] ?? 0
        let positives = malicious + suspicious
        let total = stats.values.reduce(0, +)
        let scanDateEpoch = attrs["last_analysis_date"] as? TimeInterval
        let scanDate = scanDateEpoch.map { Date(timeIntervalSince1970: $0) }
        let link = (json["data"] as? [String: Any])?["links"] as? [String: Any]
        let permalink = link?["self"] as? String

        let status: ScanStatus = positives > 0
            ? .threat(positives: positives, total: total)
            : .clean

        return VirusTotalResult(
            sha256: sha256,
            positives: positives,
            total: total,
            scanDate: scanDate,
            permalink: permalink,
            status: status
        )
    }

    /// Parse the upload response to extract the analysis ID.
    private func parseUploadResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let analysisID = dataObj["id"] as? String
        else {
            throw VirusTotalError.analysisError("Invalid upload response")
        }
        return analysisID
    }

    /// Parse an analysis response from GET /analyses/{id}.
    private func parseAnalysisResponse(_ data: Data) throws -> VirusTotalResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let attrs = dataObj["attributes"] as? [String: Any]
        else {
            throw VirusTotalError.analysisError("Invalid analysis response")
        }

        let vtStatus = attrs["status"] as? String ?? ""
        let stats = attrs["stats"] as? [String: Int] ?? [:]
        let malicious = stats["malicious"] ?? 0
        let suspicious = stats["suspicious"] ?? 0
        let positives = malicious + suspicious
        let total = stats.values.reduce(0, +)

        // Extract SHA-256 from meta or results
        let meta = json["meta"] as? [String: Any]
        let fileInfo = meta?["file_info"] as? [String: Any]
        let sha256 = fileInfo?["sha256"] as? String ?? ""

        let scanDateEpoch = attrs["date"] as? TimeInterval
        let scanDate = scanDateEpoch.map { Date(timeIntervalSince1970: $0) }
        let links = dataObj["links"] as? [String: Any]
        let permalink = links?["self"] as? String

        let status: ScanStatus
        switch vtStatus {
        case "queued":
            status = .pending
        case "in-progress":
            status = .scanning
        default:
            status = positives > 0
                ? .threat(positives: positives, total: total)
                : .clean
        }

        return VirusTotalResult(
            sha256: sha256,
            positives: positives,
            total: total,
            scanDate: scanDate,
            permalink: permalink,
            status: status
        )
    }
}

// MARK: - Rate Limiter

/// Actor-isolated rate limiter safe for use in async contexts.
private actor RateLimiter {
    private let interval: TimeInterval
    private var lastRequestTime: Date = .distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func nextDelay() -> TimeInterval {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let delay = elapsed < interval ? interval - elapsed : 0
        lastRequestTime = Date().addingTimeInterval(delay)
        return delay
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
