import Compression
import Foundation
import Virtualization

/// Ingests Claude Code's OpenTelemetry export from the guest and streams
/// it to the cloud as `BACCloudEvent`s.
///
/// Claude Code (configured via `proxy.env`, see `SessionDisk`) posts
/// OTLP/JSON to `127.0.0.1:4318` inside the VM; `bromure-vm-bridge.py`
/// splices that TCP port to vsock 8448 where this listener accepts it.
/// Each `POST /v1/metrics` / `POST /v1/logs` body is decoded and every
/// data point / log record becomes one `otel.metric` / `otel.event`
/// cloud event through `BACEventEmitter.shared` — which is the
/// enrollment gate: not enrolled (or private-mode profile) → dropped.
///
/// The exporter sends `Transfer-Encoding: chunked` with no
/// Content-Length, so the request reader de-chunks; `HTTPProxy`'s
/// header-only parser can't be reused here.
@MainActor
final class OTelReceiver {
    /// Vsock port the in-VM bridge splices the OTLP TCP port to.
    static let otelVsockPort: UInt32 = 8448
    /// Standard OTLP/HTTP collector port the exporter posts to in-guest.
    static let guestTCPPort: UInt16 = 4318

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: OTelListenerDelegate?
    private var listener: VZVirtioSocketListener?

    init(socketDevice: VZVirtioSocketDevice, profileID: UUID) {
        self.socketDevice = socketDevice
        let delegate = OTelListenerDelegate(profileID: profileID)
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        self.listener = listener
        socketDevice.setSocketListener(listener, forPort: Self.otelVsockPort)
        BACDebug.log("[ac/otel]", "listening on vsock \(Self.otelVsockPort) profile=\(profileID)")
    }

    func stop() {
        socketDevice?.removeSocketListener(forPort: Self.otelVsockPort)
        listenerDelegate = nil
        listener = nil
    }
}

private final class OTelListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let profileID: UUID

    init(profileID: UUID) {
        self.profileID = profileID
    }

    func listener(_ listener: VZVirtioSocketListener,
                  shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        // Same lifetime rule as the MITM listeners: dup the fd so the
        // connection object can go away while we serve the socket.
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { return false }
        BACDebug.log("[ac/otel]", "guest connected fd=\(fd)")
        let pid = profileID
        Task.detached(priority: .utility) {
            await OTelConnection(fd: fd, profileID: pid).run()
        }
        return true
    }
}

// MARK: - Connection loop

/// Serves one guest connection: a keep-alive sequence of OTLP/HTTP
/// POSTs. Blocking reads on the dup'd fd, like `HTTPMitmConnection`.
private struct OTelConnection {
    let fd: Int32
    let profileID: UUID

    /// Events per request beyond this are dropped — matches the
    /// server-side batch cap and keeps a hostile guest from flooding
    /// the uploader through this port.
    static let maxEventsPerRequest = 500

    func run() async {
        defer { close(fd) }
        var reader = OTelHTTPReader(readSource: otelFDReadSource(fd: fd))
        while true {
            let request: OTelHTTPRequest?
            do {
                request = try reader.nextRequest()
            } catch {
                BACDebug.log("[ac/otel]", "connection dropped: \(error)")
                return
            }
            guard let request else { return }   // clean EOF between requests
            await handle(request)
            respond(status: responseStatus(for: request))
        }
    }

    private func responseStatus(for request: OTelHTTPRequest) -> String {
        guard request.method == "POST" else { return "405 Method Not Allowed" }
        switch request.path {
        case "/v1/metrics", "/v1/logs", "/v1/traces": return "200 OK"
        default: return "404 Not Found"
        }
    }

    private func handle(_ request: OTelHTTPRequest) async {
        guard request.method == "POST" else { return }
        // Enrollment mirror — skip the decode entirely when there's
        // nowhere to send. `emit()` still applies the authoritative
        // enrollment + private-mode gates per event.
        guard BACEventEmitter.shared.isStreamingEnabled else {
            BACDebug.log("[ac/otel]", "drop (not enrolled) \(request.path) \(request.body.count)B")
            return
        }
        var body = request.body
        if request.headers["content-encoding"]?.contains("gzip") == true {
            guard let inflated = otelGunzip(body) else {
                BACDebug.log("[ac/otel]", "drop (bad gzip) \(request.path)")
                return
            }
            body = inflated
        }
        let eventType: String
        let events: [[String: AnyJSON]]
        switch request.path {
        case "/v1/metrics":
            eventType = "otel.metric"
            events = OTelEventMapper.events(fromMetricsJSON: body)
        case "/v1/logs":
            eventType = "otel.event"
            events = OTelEventMapper.events(fromLogsJSON: body)
        default:
            return   // /v1/traces accepted-and-dropped; exporter stays happy
        }
        if events.count > Self.maxEventsPerRequest {
            BACDebug.log("[ac/otel]",
                         "truncating \(events.count) → \(Self.maxEventsPerRequest) events")
        }
        for eventData in events.prefix(Self.maxEventsPerRequest) {
            await BACEventEmitter.shared.emit(profileID: profileID,
                                              eventType: eventType,
                                              eventData: eventData)
        }
    }

    /// Every response carries the empty OTLP partial-success object —
    /// a valid `Export*ServiceResponse` — so the exporter never retries.
    private func respond(status: String) {
        let payload = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: 2\r\n" +
            "Connection: keep-alive\r\n\r\n{}"
        let data = [UInt8](payload.utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, -1)
                continue
            }
            if n <= 0 { return }
            offset += n
        }
    }
}

/// Pull-based byte source over the dup'd vsock fd. VZ hands out
/// NON-BLOCKING fds (the dup shares that flag with VZ's own copy, so
/// it must stay set) — an `EAGAIN` here means "no export due yet",
/// which for a keep-alive connection that goes quiet for 60 s between
/// batches is the steady state, not an error. Park in poll(2) until
/// readable. Empty Data = EOF.
func otelFDReadSource(fd: Int32) -> (Int) throws -> Data {
    return { max in
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = read(fd, &buf, max)
            if n > 0 { return Data(buf.prefix(n)) }
            if n == 0 { return Data() }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, -1)
                continue
            }
            throw OTelHTTPError.ioFailed(errno)
        }
    }
}

// MARK: - HTTP request reader

enum OTelHTTPError: Error {
    case malformedRequest
    case headerTooLarge
    case bodyTooLarge
    case unexpectedEOF
    case ioFailed(Int32)
}

struct OTelHTTPRequest {
    let method: String
    let path: String
    /// Keys lowercased.
    let headers: [String: String]
    let body: Data
}

/// Incremental HTTP/1.1 request reader over a pull-based byte source.
/// Handles `Content-Length` bodies AND `Transfer-Encoding: chunked` —
/// Claude Code's OTLP exporter sends chunked with no Content-Length.
/// Keep-alive aware: bytes past one request stay buffered for the next.
struct OTelHTTPReader {
    /// Pull up to `max` bytes; empty Data means EOF.
    let readSource: (Int) throws -> Data
    private var buffer = Data()

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024
    private static let readChunk = 16 * 1024

    init(readSource: @escaping (Int) throws -> Data) {
        self.readSource = readSource
    }

    /// Returns the next complete request, or nil on a clean EOF at a
    /// request boundary. Throws on truncated/malformed input.
    mutating func nextRequest() throws -> OTelHTTPRequest? {
        // Headers.
        let crlfcrlf = Data("\r\n\r\n".utf8)
        var headerEnd = buffer.range(of: crlfcrlf)
        while headerEnd == nil {
            if buffer.count > Self.maxHeaderBytes { throw OTelHTTPError.headerTooLarge }
            let got = try readSource(Self.readChunk)
            if got.isEmpty {
                if buffer.isEmpty { return nil }
                throw OTelHTTPError.unexpectedEOF
            }
            buffer.append(got)
            headerEnd = buffer.range(of: crlfcrlf)
        }
        let headerData = buffer.prefix(upTo: headerEnd!.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<headerEnd!.upperBound)

        guard let headerText = String(data: headerData, encoding: .ascii) else {
            throw OTelHTTPError.malformedRequest
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw OTelHTTPError.malformedRequest }
        let requestParts = lines.removeFirst().split(separator: " ")
        guard requestParts.count >= 2 else { throw OTelHTTPError.malformedRequest }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Body.
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try readChunkedBody()
        } else if let cl = headers["content-length"].flatMap({ Int($0) }) {
            guard cl >= 0, cl <= Self.maxBodyBytes else { throw OTelHTTPError.bodyTooLarge }
            body = try consume(exactly: cl)
        } else {
            body = Data()
        }
        return OTelHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// RFC 9112 §7.1: `hex-size[;ext]\r\n data \r\n` … `0\r\n [trailers] \r\n`.
    private mutating func readChunkedBody() throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try consumeLine()
            let hex = sizeLine.split(separator: ";", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(hex, radix: 16), size >= 0 else {
                throw OTelHTTPError.malformedRequest
            }
            if size == 0 {
                // Trailer section: lines until the terminating empty one.
                while try !consumeLine().isEmpty {}
                return body
            }
            guard body.count + size <= Self.maxBodyBytes else {
                throw OTelHTTPError.bodyTooLarge
            }
            body.append(try consume(exactly: size))
            guard try consume(exactly: 2) == Data("\r\n".utf8) else {
                throw OTelHTTPError.malformedRequest
            }
        }
    }

    private mutating func consumeLine() throws -> String {
        let crlf = Data("\r\n".utf8)
        var range = buffer.range(of: crlf)
        while range == nil {
            if buffer.count > Self.maxHeaderBytes { throw OTelHTTPError.malformedRequest }
            let got = try readSource(Self.readChunk)
            if got.isEmpty { throw OTelHTTPError.unexpectedEOF }
            buffer.append(got)
            range = buffer.range(of: crlf)
        }
        let line = buffer.prefix(upTo: range!.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range!.upperBound)
        guard let s = String(data: line, encoding: .ascii) else {
            throw OTelHTTPError.malformedRequest
        }
        return s
    }

    private mutating func consume(exactly n: Int) throws -> Data {
        while buffer.count < n {
            let got = try readSource(Self.readChunk)
            if got.isEmpty { throw OTelHTTPError.unexpectedEOF }
            buffer.append(got)
        }
        let out = buffer.prefix(n)
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + n))
        return Data(out)
    }
}

// MARK: - OTLP/JSON → event mapping

/// Maps OTLP/HTTP JSON export payloads to `BACCloudEvent.eventData`
/// dictionaries. Field names follow the proto3 JSON mapping the JS
/// exporter emits (camelCase); snake_case aliases are accepted per
/// the OTLP spec. int64 values arrive as JSON strings.
enum OTelEventMapper {
    /// `ExportMetricsServiceRequest` → one eventData per data point.
    static func events(fromMetricsJSON data: Data) -> [[String: AnyJSON]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var out: [[String: AnyJSON]] = []
        for rm in dicts(root, "resourceMetrics") {
            let resource = attributes(field(rm, "resource") as? [String: Any])
            for sm in dicts(rm, "scopeMetrics") {
                for metric in dicts(sm, "metrics") {
                    guard let name = field(metric, "name") as? String else { continue }
                    out.append(contentsOf: dataPointEvents(
                        metric: metric, name: name, resource: resource))
                }
            }
        }
        return out
    }

    /// `ExportLogsServiceRequest` → one eventData per log record.
    /// Claude Code emits its events (`claude_code.user_prompt`, …) as
    /// log records carrying an `event.name` attribute.
    static func events(fromLogsJSON data: Data) -> [[String: AnyJSON]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var out: [[String: AnyJSON]] = []
        for rl in dicts(root, "resourceLogs") {
            let resource = attributes(field(rl, "resource") as? [String: Any])
            for sl in dicts(rl, "scopeLogs") {
                for record in dicts(sl, "logRecords") {
                    let attrs = attributes(record)
                    var event: [String: AnyJSON] = [:]
                    let bodyValue = (field(record, "body") as? [String: Any]).map(anyValue)
                    if case .string(let n)? = attrs["event.name"] {
                        event["name"] = .string(n)
                    } else if case .string(let n)? = bodyValue {
                        event["name"] = .string(n)
                    } else {
                        event["name"] = .string("log")
                    }
                    if let body = bodyValue { event["body"] = body }
                    if let sev = field(record, "severityText") as? String {
                        event["severity"] = .string(sev)
                    }
                    if let ts = field(record, "timeUnixNano") {
                        event["time_unix_nano"] = .string("\(ts)")
                    }
                    event["attributes"] = .object(attrs)
                    if !resource.isEmpty { event["resource"] = .object(resource) }
                    out.append(event)
                }
            }
        }
        return out
    }

    // MARK: metric data points

    private static func dataPointEvents(metric: [String: Any], name: String,
                                        resource: [String: AnyJSON]) -> [[String: AnyJSON]] {
        var out: [[String: AnyJSON]] = []
        let unit = field(metric, "unit") as? String

        func base(_ dp: [String: Any]) -> [String: AnyJSON] {
            var event: [String: AnyJSON] = ["name": .string(name)]
            if let unit, !unit.isEmpty { event["unit"] = .string(unit) }
            let attrs = attributes(dp)
            if !attrs.isEmpty { event["attributes"] = .object(attrs) }
            if !resource.isEmpty { event["resource"] = .object(resource) }
            if let ts = field(dp, "timeUnixNano") {
                event["time_unix_nano"] = .string("\(ts)")
            }
            return event
        }

        // Counters and gauges: single numeric value per point.
        for container in ["sum", "gauge"] {
            guard let c = field(metric, container) as? [String: Any] else { continue }
            for dp in dicts(c, "dataPoints") {
                var event = base(dp)
                if let v = numericValue(dp) { event["value"] = .double(v) }
                out.append(event)
            }
        }
        // Histograms: summarized — the admin console charts totals,
        // not bucket shapes.
        if let h = field(metric, "histogram") as? [String: Any] {
            for dp in dicts(h, "dataPoints") {
                var event = base(dp)
                var summary: [String: AnyJSON] = [:]
                if let count = int64(field(dp, "count")) { summary["count"] = .int(count) }
                for k in ["sum", "min", "max"] {
                    if let v = double(field(dp, k)) { summary[k] = .double(v) }
                }
                event["value"] = .object(summary)
                out.append(event)
            }
        }
        return out
    }

    /// Numeric point value: `asDouble` is a JSON number, `asInt` is an
    /// int64-as-string per proto3 JSON.
    private static func numericValue(_ dp: [String: Any]) -> Double? {
        if let d = double(field(dp, "asDouble")) { return d }
        if let i = int64(field(dp, "asInt")) { return Double(i) }
        return nil
    }

    // MARK: OTLP scaffolding

    /// Attribute list (`[{key, value: {stringValue: …}}, …]`) from a
    /// `resource`, data point, or log record → flat dictionary.
    private static func attributes(_ node: [String: Any]?) -> [String: AnyJSON] {
        guard let node, let list = field(node, "attributes") as? [Any] else { return [:] }
        var out: [String: AnyJSON] = [:]
        for entry in list {
            guard let kv = entry as? [String: Any],
                  let key = kv["key"] as? String,
                  let value = kv["value"] as? [String: Any] else { continue }
            out[key] = anyValue(value)
        }
        return out
    }

    /// OTLP `AnyValue` → `AnyJSON`.
    private static func anyValue(_ v: [String: Any]) -> AnyJSON {
        if let s = field(v, "stringValue") as? String { return .string(s) }
        if let b = field(v, "boolValue") as? Bool { return .bool(b) }
        if let i = int64(field(v, "intValue")) { return .int(i) }
        if let d = double(field(v, "doubleValue")) { return .double(d) }
        if let arr = field(v, "arrayValue") as? [String: Any],
           let values = field(arr, "values") as? [Any] {
            return .array(values.compactMap { ($0 as? [String: Any]).map(anyValue) })
        }
        if let kvlist = field(v, "kvlistValue") as? [String: Any] {
            return .object(attributes(["attributes": field(kvlist, "values") ?? []]))
        }
        if let bytes = field(v, "bytesValue") as? String { return .string(bytes) }
        return .null
    }

    /// Look up `camelCase` key with its `snake_case` alias.
    private static func field(_ dict: [String: Any], _ camel: String) -> Any? {
        if let v = dict[camel] { return v }
        let snake = camel.reduce(into: "") { acc, ch in
            if ch.isUppercase {
                acc.append("_")
                acc.append(Character(ch.lowercased()))
            } else {
                acc.append(ch)
            }
        }
        return dict[snake]
    }

    private static func dicts(_ dict: [String: Any], _ key: String) -> [[String: Any]] {
        (field(dict, key) as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// int64 arrives as a string in proto3 JSON, but tolerate numbers.
    private static func int64(_ v: Any?) -> Int? {
        if let s = v as? String { return Int(s) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - gzip

/// Minimal gzip (RFC 1952) inflate: parse the member header, then
/// raw-deflate the payload via Compression.framework. The exporter
/// only compresses when `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` is set,
/// but decoding it here means flipping that on can't silently break
/// telemetry. Output capped at 64 MiB against compression bombs.
func otelGunzip(_ data: Data) -> Data? {
    guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else {
        return nil
    }
    let flags = data[3]
    var offset = 10
    if flags & 0x04 != 0 {   // FEXTRA
        guard data.count >= offset + 2 else { return nil }
        let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2 + xlen
    }
    for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }   // FHCRC
    guard offset < data.count - 8 else { return nil }
    let deflated = data.subdata(in: offset..<(data.count - 8))

    let outCap = 64 * 1024 * 1024
    let chunkSize = 64 * 1024
    var out = Data()
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE,
                                  COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
        return nil
    }
    defer { compression_stream_destroy(stream) }
    let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { dstBuf.deallocate() }
    return deflated.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
        guard let srcBase = src.baseAddress else { return nil }
        stream.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = deflated.count
        stream.pointee.dst_ptr = dstBuf
        stream.pointee.dst_size = chunkSize
        while true {
            let status = compression_stream_process(
                stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = chunkSize - stream.pointee.dst_size
                out.append(dstBuf, count: produced)
                if out.count > outCap { return nil }
                if status == COMPRESSION_STATUS_END { return out }
                stream.pointee.dst_ptr = dstBuf
                stream.pointee.dst_size = chunkSize
            default:
                return nil
            }
        }
    }
}
