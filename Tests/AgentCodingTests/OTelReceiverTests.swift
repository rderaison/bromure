import Foundation
import Testing
@testable import bromure_ac

/// Tests for the host-side OTel receiver: the HTTP request reader —
/// notably `Transfer-Encoding: chunked` bodies, which Claude Code's
/// OTLP exporter sends with no Content-Length — and the OTLP/JSON →
/// `BACCloudEvent.eventData` mapping.
@Suite("OTel receiver")
struct OTelReceiverTests {

    /// Serve `data` in tiny slices so header/chunk boundaries land
    /// mid-read — the realistic vsock case.
    private func makeReader(_ data: Data, sliceSize: Int = 7) -> OTelHTTPReader {
        var offset = 0
        return OTelHTTPReader { max in
            guard offset < data.count else { return Data() }
            let n = Swift.min(sliceSize, Swift.min(max, data.count - offset))
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }
    }

    // MARK: chunked bodies

    @Test("Chunked body with no Content-Length is de-chunked")
    func chunkedBody() throws {
        let raw =
            "POST /v1/metrics HTTP/1.1\r\n" +
            "Host: 127.0.0.1:4318\r\n" +
            "Content-Type: application/json\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "6\r\n{\"hell\r\n" +
            "A\r\no\":\"world\"\r\n" +
            "8\r\n,\"n\":42}\r\n" +
            "0\r\n\r\n"
        var reader = makeReader(Data(raw.utf8))
        let request = try #require(try reader.nextRequest())
        #expect(request.method == "POST")
        #expect(request.path == "/v1/metrics")
        #expect(request.headers["transfer-encoding"] == "chunked")
        #expect(request.headers["content-length"] == nil)
        #expect(String(data: request.body, encoding: .utf8) == "{\"hello\":\"world\",\"n\":42}")
        // Clean EOF at the request boundary.
        #expect(try reader.nextRequest() == nil)
    }

    @Test("Chunk extensions and trailer headers are skipped")
    func chunkExtensionsAndTrailers() throws {
        let raw =
            "POST /v1/logs HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "4;chunk-ext=zero\r\nabcd\r\n" +
            "0\r\n" +
            "X-Streaming-Checksum: abc123\r\n" +
            "\r\n"
        var reader = makeReader(Data(raw.utf8))
        let request = try #require(try reader.nextRequest())
        #expect(String(data: request.body, encoding: .utf8) == "abcd")
        #expect(try reader.nextRequest() == nil)
    }

    @Test("Keep-alive: chunked request then Content-Length request on one stream")
    func pipelinedRequests() throws {
        let raw =
            "POST /v1/metrics HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "2\r\n{}\r\n" +
            "0\r\n\r\n" +
            "POST /v1/logs HTTP/1.1\r\n" +
            "Content-Length: 9\r\n" +
            "\r\n" +
            "{\"a\":true}".dropLast()   // 9 bytes: {"a":true
        var reader = makeReader(Data(raw.utf8), sliceSize: 3)
        let first = try #require(try reader.nextRequest())
        #expect(first.path == "/v1/metrics")
        #expect(String(data: first.body, encoding: .utf8) == "{}")
        let second = try #require(try reader.nextRequest())
        #expect(second.path == "/v1/logs")
        #expect(second.body.count == 9)
        #expect(try reader.nextRequest() == nil)
    }

    @Test("Truncated chunked body throws instead of returning a partial request")
    func truncatedChunkedBody() {
        let raw =
            "POST /v1/metrics HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "FF\r\ntoo short"
        var reader = makeReader(Data(raw.utf8))
        #expect(throws: OTelHTTPError.self) { _ = try reader.nextRequest() }
    }

    @Test("Bogus chunk-size line throws")
    func malformedChunkSize() {
        let raw =
            "POST /v1/metrics HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "zz\r\nabcd\r\n0\r\n\r\n"
        var reader = makeReader(Data(raw.utf8))
        #expect(throws: OTelHTTPError.self) { _ = try reader.nextRequest() }
    }

    @Test("Read source survives EAGAIN on a non-blocking fd (VZ vsock behavior)")
    func nonBlockingFD() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let readFD = fds[0]
        let writeFD = fds[1]
        defer { close(readFD) }
        // VZ hands the listener delegate a non-blocking fd; reproduce that.
        let flags = fcntl(readFD, F_GETFL)
        #expect(fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0)

        let raw =
            "POST /v1/metrics HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "2\r\n{}\r\n" +
            "0\r\n\r\n"
        // Trickle bytes from another thread so reads hit EAGAIN mid-request.
        let writer = Thread {
            for byte in Array(raw.utf8) {
                var b = byte
                _ = write(writeFD, &b, 1)
                usleep(500)
            }
            close(writeFD)
        }
        writer.start()

        var reader = OTelHTTPReader(readSource: otelFDReadSource(fd: readFD))
        let request = try #require(try reader.nextRequest())
        #expect(request.path == "/v1/metrics")
        #expect(String(data: request.body, encoding: .utf8) == "{}")
        // EOF (write end closed) surfaces as a clean nil, not a throw.
        #expect(try reader.nextRequest() == nil)
    }

    // MARK: OTLP metrics mapping

    private let metricsJSON = """
    {"resourceMetrics":[{
      "resource":{"attributes":[
        {"key":"service.name","value":{"stringValue":"claude-code"}},
        {"key":"session.id","value":{"stringValue":"abc-123"}}]},
      "scopeMetrics":[{
        "scope":{"name":"com.anthropic.claude_code"},
        "metrics":[
          {"name":"claude_code.token.usage","unit":"tokens","sum":{
            "aggregationTemporality":1,"isMonotonic":true,
            "dataPoints":[
              {"attributes":[
                 {"key":"type","value":{"stringValue":"input"}},
                 {"key":"model","value":{"stringValue":"claude-fable-5"}}],
               "timeUnixNano":"1751800000000000000","asInt":"1234"},
              {"attributes":[{"key":"type","value":{"stringValue":"output"}}],
               "timeUnixNano":"1751800000000000000","asDouble":56}]}},
          {"name":"claude_code.cost.usage","unit":"USD","sum":{
            "dataPoints":[{"asDouble":0.42,"timeUnixNano":"1"}]}}]}]}]}
    """

    @Test("Metrics: one event per data point, int64-as-string values decoded")
    func metricsMapping() throws {
        let events = OTelEventMapper.events(fromMetricsJSON: Data(metricsJSON.utf8))
        #expect(events.count == 3)

        let first = try #require(events.first)
        #expect(first["name"]?.testString == "claude_code.token.usage")
        #expect(first["unit"]?.testString == "tokens")
        #expect(first["value"]?.testDouble == 1234)
        #expect(first["time_unix_nano"]?.testString == "1751800000000000000")
        let attrs = try #require(first["attributes"]?.testObject)
        #expect(attrs["type"]?.testString == "input")
        #expect(attrs["model"]?.testString == "claude-fable-5")
        let resource = try #require(first["resource"]?.testObject)
        #expect(resource["session.id"]?.testString == "abc-123")

        #expect(events[1]["value"]?.testDouble == 56)
        #expect(events[2]["name"]?.testString == "claude_code.cost.usage")
        #expect(events[2]["value"]?.testDouble == 0.42)
    }

    @Test("Metrics: snake_case field names are accepted")
    func metricsSnakeCase() {
        let json = """
        {"resource_metrics":[{"scope_metrics":[{"metrics":[
          {"name":"m","sum":{"data_points":[
            {"as_int":"7","time_unix_nano":"1"}]}}]}]}]}
        """
        let events = OTelEventMapper.events(fromMetricsJSON: Data(json.utf8))
        #expect(events.count == 1)
        #expect(events.first?["value"]?.testDouble == 7)
    }

    @Test("Metrics: histograms summarize to count/sum/min/max")
    func histogramMapping() throws {
        let json = """
        {"resourceMetrics":[{"scopeMetrics":[{"metrics":[
          {"name":"h","unit":"s","histogram":{"dataPoints":[
            {"count":"5","sum":12.5,"min":1,"max":4,"timeUnixNano":"1"}]}}]}]}]}
        """
        let events = OTelEventMapper.events(fromMetricsJSON: Data(json.utf8))
        #expect(events.count == 1)
        let value = try #require(events.first?["value"]?.testObject)
        #expect(value["count"]?.testInt == 5)
        #expect(value["sum"]?.testDouble == 12.5)
        #expect(value["min"]?.testDouble == 1)
        #expect(value["max"]?.testDouble == 4)
    }

    @Test("Metrics: garbage input maps to zero events, no crash")
    func metricsGarbage() {
        #expect(OTelEventMapper.events(fromMetricsJSON: Data("not json".utf8)).isEmpty)
        #expect(OTelEventMapper.events(fromMetricsJSON: Data("[1,2,3]".utf8)).isEmpty)
        #expect(OTelEventMapper.events(fromMetricsJSON: Data()).isEmpty)
    }

    // MARK: OTLP logs mapping

    private let logsJSON = """
    {"resourceLogs":[{
      "resource":{"attributes":[
        {"key":"service.name","value":{"stringValue":"claude-code"}}]},
      "scopeLogs":[{"logRecords":[
        {"timeUnixNano":"1751800000000000000",
         "severityText":"INFO",
         "body":{"stringValue":"claude_code.api_request"},
         "attributes":[
           {"key":"event.name","value":{"stringValue":"claude_code.api_request"}},
           {"key":"model","value":{"stringValue":"claude-fable-5"}},
           {"key":"input_tokens","value":{"intValue":"100"}},
           {"key":"cost_usd","value":{"doubleValue":0.01}},
           {"key":"streaming","value":{"boolValue":true}}]}]}]}]}
    """

    @Test("Logs: event name from event.name attribute, typed attribute values")
    func logsMapping() throws {
        let events = OTelEventMapper.events(fromLogsJSON: Data(logsJSON.utf8))
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event["name"]?.testString == "claude_code.api_request")
        #expect(event["severity"]?.testString == "INFO")
        #expect(event["time_unix_nano"]?.testString == "1751800000000000000")
        let attrs = try #require(event["attributes"]?.testObject)
        #expect(attrs["model"]?.testString == "claude-fable-5")
        #expect(attrs["input_tokens"]?.testInt == 100)
        #expect(attrs["cost_usd"]?.testDouble == 0.01)
        if case .bool(let b)? = attrs["streaming"] { #expect(b) } else {
            Issue.record("streaming attribute not mapped as bool")
        }
        let resource = try #require(event["resource"]?.testObject)
        #expect(resource["service.name"]?.testString == "claude-code")
    }

    @Test("Logs: body string is the fallback event name")
    func logsBodyFallbackName() {
        let json = """
        {"resourceLogs":[{"scopeLogs":[{"logRecords":[
          {"body":{"stringValue":"claude_code.user_prompt"},"attributes":[]}]}]}]}
        """
        let events = OTelEventMapper.events(fromLogsJSON: Data(json.utf8))
        #expect(events.first?["name"]?.testString == "claude_code.user_prompt")
    }

    // MARK: gzip

    @Test("gzip request bodies inflate")
    func gunzip() throws {
        // `printf '{"resourceMetrics":[]}' | gzip -n`
        let hex = "1f8b0800000000000003ab562a4a2dce2f2d4a4ef54d2d29ca4c2e56b28a8ead0500346f15ad16000000"
        var gz = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            gz.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        let inflated = try #require(otelGunzip(gz))
        #expect(String(data: inflated, encoding: .utf8) == "{\"resourceMetrics\":[]}")
        // Truncated / non-gzip input fails cleanly.
        #expect(otelGunzip(gz.prefix(10)) == nil)
        #expect(otelGunzip(Data("plain".utf8)) == nil)
    }
}

// MARK: - AnyJSON accessors for assertions

private extension AnyJSON {
    var testString: String? { if case .string(let v) = self { return v } else { return nil } }
    var testInt: Int? { if case .int(let v) = self { return v } else { return nil } }
    var testDouble: Double? { if case .double(let v) = self { return v } else { return nil } }
    var testObject: [String: AnyJSON]? { if case .object(let v) = self { return v } else { return nil } }
}
