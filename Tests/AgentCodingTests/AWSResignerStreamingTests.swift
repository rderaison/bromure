import Foundation
import Testing
@testable import bromure_ac

/// S3 uploads with a checksum go out aws-chunked. The SDKs' default,
/// `STREAMING-UNSIGNED-PAYLOAD-TRAILER`, signs only the seed request, so
/// the host re-signs it with the body untouched; the signed streaming
/// modes chain each chunk off the guest's signature and are refused.
@Suite("AWS re-signer: aws-chunked uploads")
struct AWSResignerStreamingTests {
    private static let chunked = "1a\r\nabcdefghijklmnopqrstuvwxyz\r\n0\r\nx-amz-checksum-crc32:4ZRP3A==\r\n\r\n"

    private static func upload(_ contentSHA: String) -> Data {
        let head = "PUT /bucket/key.txt HTTP/1.1\r\nHost: s3.us-east-1.amazonaws.com\r\n"
            + "Authorization: AWS4-HMAC-SHA256 Credential=AKIAPRIMARY/20261105/us-east-1/s3/aws4_request, "
            + "SignedHeaders=content-encoding;host;x-amz-content-sha256;x-amz-date;x-amz-decoded-content-length;x-amz-trailer, Signature=00\r\n"
            + "X-Amz-Date: 20261105T000000Z\r\n"
            + "X-Amz-Content-SHA256: \(contentSHA)\r\n"
            + "Content-Encoding: aws-chunked\r\n"
            + "X-Amz-Trailer: x-amz-checksum-crc32\r\n"
            + "X-Amz-Decoded-Content-Length: 26\r\n"
            + "Content-Length: \(chunked.utf8.count)\r\n\r\n"
        return Data((head + chunked).utf8)
    }

    private static func resigner() -> (AWSResigner, UUID) {
        let server = AWSCredentialServer(consent: ConsentBroker()), pid = UUID()
        server.setCredentials(AWSCredentials(accessKeyID: "AKIAPRIMARY", secretAccessKey: "primarySecret", region: "us-east-1"), for: pid)
        return (AWSResigner(credServer: server), pid)
    }

    @Test("an unsigned-trailer upload is re-signed with its sentinel, its body and chunk headers untouched")
    func unsignedTrailer() async throws {
        let (resigner, pid) = Self.resigner()
        guard case .resigned(let bytes) = await resigner.resign(
            rawRequest: Self.upload("STREAMING-UNSIGNED-PAYLOAD-TRAILER"),
            host: "s3.us-east-1.amazonaws.com", profileID: pid) else {
            Issue.record("not resigned"); return
        }
        let out = String(decoding: bytes, as: UTF8.self)
        let parts = out.components(separatedBy: "\r\n\r\n")
        let head = parts[0], body = parts.dropFirst().joined(separator: "\r\n\r\n")
        #expect(body == Self.chunked)
        let lines = head.components(separatedBy: "\r\n").dropFirst()
        var headers: [(String, String)] = []
        var auth = ""
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            let (n, v) = (String(l[..<c]), l[l.index(after: c)...].trimmingCharacters(in: .whitespaces))
            if n.lowercased() == "authorization" { auth = v } else { headers.append((n, v)) }
        }
        func value(_ n: String) -> String? { headers.first { $0.0.lowercased() == n }?.1 }
        #expect(value("x-amz-content-sha256") == "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
        #expect(value("content-encoding") == "aws-chunked")
        #expect(value("x-amz-trailer") == "x-amz-checksum-crc32")
        #expect(value("x-amz-decoded-content-length") == "26")
        #expect(auth.contains("Credential=AKIAPRIMARY/"))
        #expect(auth.contains("content-encoding;") && auth.contains("x-amz-decoded-content-length;x-amz-trailer"))

        // The signature covers exactly what goes on the wire: recomputed
        // over those headers (and the Host the resigner signs), it matches.
        let amzDate = try #require(value("x-amz-date"))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let date = try #require(f.date(from: amzDate))
        let expected = SigV4Signer.sign(
            request: SigV4Signer.Request(method: "PUT", path: "/bucket/key.txt", query: "",
                                         headers: headers + [("Host", "s3.us-east-1.amazonaws.com")],
                                         body: Data(Self.chunked.utf8)),
            credentials: SigV4Signer.Credentials(accessKeyID: "AKIAPRIMARY", secretAccessKey: "primarySecret"),
            scope: SigV4Signer.Scope(date: String(amzDate.prefix(8)), region: "us-east-1", service: "s3"),
            date: date, payloadHash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
        #expect(auth == expected.authorization)
    }

    @Test("the signed streaming modes are refused with a 501, never re-signed over their chunk framing")
    func signedStreamingRefused() async {
        let (resigner, pid) = Self.resigner()
        for mode in ["STREAMING-AWS4-HMAC-SHA256-PAYLOAD", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
                     "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD", "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD-TRAILER"] {
            guard case .failed(_, let resp) = await resigner.resign(
                rawRequest: Self.upload(mode), host: "s3.us-east-1.amazonaws.com", profileID: pid) else {
                Issue.record("\(mode) not refused"); continue
            }
            #expect(String(decoding: resp, as: UTF8.self).hasPrefix("HTTP/1.1 501"), "\(mode)")
        }
    }

    @Test("the signer takes a payload sentinel as given")
    func signerSentinel() {
        let req = SigV4Signer.Request(method: "PUT", path: "/", query: "",
                                      headers: [("Host", "s3.amazonaws.com")], body: Data("x".utf8))
        let creds = SigV4Signer.Credentials(accessKeyID: "AKID", secretAccessKey: "s")
        let scope = SigV4Signer.Scope(date: "20261105", region: "us-east-1", service: "s3")
        let date = Date(timeIntervalSince1970: 1_793_836_800)
        let t = SigV4Signer.sign(request: req, credentials: creds, scope: scope, date: date,
                                 payloadHash: "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
        let u = SigV4Signer.sign(request: req, credentials: creds, scope: scope, date: date, unsignedPayload: true)
        #expect(t.payloadHash == "STREAMING-UNSIGNED-PAYLOAD-TRAILER")
        #expect(t.authorization != u.authorization)
    }
}
