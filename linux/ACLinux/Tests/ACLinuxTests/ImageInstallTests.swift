import Crypto
import Foundation
import FoundationNetworking
import NIOCore
import NIOPosix
import Testing
import SandboxEngine
@testable import ACLinux

/// The prebuilt amd64 image (area H c): its own channel, the transfer, the
/// checksum, the sparse expansion, and which failures fall back to a bake.
@Suite("Image install: the amd64 download path")
struct ImageInstallTests {
    static func catalog() -> ImageCatalog {
        ImageCatalog(formatVersion: 1, image: RemoteBaseImage(
            uuid: "img-1", version: "201", description: "Ubuntu (amd64)",
            disk: .init(path: "images/201/amd64/img-1/base.img.gz", sha256: String(repeating: "a", count: 64),
                        compressedBytes: 10, uncompressedBytes: 20)),
            postinstall: [PostinstallStep(uuid: "s1", seq: 1, description: "A", command: "true")])
    }

    static func signed(_ c: ImageCatalog, magic: String, key: Curve25519.Signing.PrivateKey) throws -> ImageCatalog {
        var c = c
        let at = "2026-11-09T00:00:00Z"
        let payload = try #require(c.signingPayload(signedAt: at, magic: magic))
        c.signature = .init(signedAt: at, edSignature: try key.signature(for: payload).base64EncodedString())
        return c
    }

    /// The same key signs both channels; only the magic differs, so an
    /// arm64 catalog (its image the macOS disk) isn't valid at the amd64
    /// URL, nor the reverse.
    @Test func anArm64CatalogIsntAnAmd64One() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let arm = ImageDistribution.agentCoding(imageVersion: "201"), amd = ImageDistribution.agentCodingAmd64(imageVersion: "201")
        #expect(amd.catalogPrefix == "images/201/amd64" && amd.signingMagic == "bromure-img-catalog-amd64-v1")
        #expect(amd.signingMagic != arm.signingMagic && amd.cacheFileName != arm.cacheFileName)
        let armSigned = try Self.signed(Self.catalog(), magic: arm.signingMagic, key: key)
        #expect(ImageCatalogStore.isSignatureValid(armSigned, magic: arm.signingMagic, publicKeyBase64: pub))
        #expect(!ImageCatalogStore.isSignatureValid(armSigned, magic: amd.signingMagic, publicKeyBase64: pub))
        let amdSigned = try Self.signed(Self.catalog(), magic: amd.signingMagic, key: key)
        #expect(ImageCatalogStore.isSignatureValid(amdSigned, magic: amd.signingMagic, publicKeyBase64: pub))
        #expect(!ImageCatalogStore.isSignatureValid(amdSigned, magic: arm.signingMagic, publicKeyBase64: pub))
    }

    @Test func onlyTheDownloadsOwnFailuresFallBack() {
        #expect(ImageInstall.isDownloadSideFailure(ImageFetchError.catalogUnavailable))
        #expect(ImageInstall.isDownloadSideFailure(ImageFetchError.checksumInvalid("x")))
        #expect(ImageInstall.isDownloadSideFailure(URLError(.notConnectedToInternet)))
        #expect(!ImageInstall.isDownloadSideFailure(CancellationError()))
        #expect(!ImageInstall.isDownloadSideFailure(BakeError.installerReportedFailure("SANDBOX_POSTINSTALL_FAILED: x")))
        #expect(!ImageInstall.isDownloadSideFailure(BakeError.staging("another image install is running")))
    }

    /// The shared transfer on Linux: a download from a loopback server,
    /// its SHA-256 (swift-crypto here, CommonCrypto on macOS), and the
    /// gunzip to a sparse file of the catalog's size.
    @Test func aDownloadIsCheckedAndExpandedSparse() async throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 8 MiB: 4 MiB of zeros (a hole), then data, then zeros.
        var raw = Data(count: 8 << 20)
        raw.replaceSubrange((4 << 20)..<((4 << 20) + 4), with: Data("disk".utf8))
        try raw.write(to: URL(fileURLWithPath: dir + "/disk.raw"))
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-k", dir + "/disk.raw"]
        try gzip.run()
        gzip.waitUntilExit()
        let gz = try Data(contentsOf: URL(fileURLWithPath: dir + "/disk.raw.gz"))
        let up = try BinaryUpstream(body: gz)
        defer { up.stop() }
        try await ImageFetch.download(from: URL(string: "http://127.0.0.1:\(up.port)/base.img.gz")!,
                                      to: URL(fileURLWithPath: dir + "/got.gz")) { _, _ in }
        #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/got.gz")) == gz)
        let want = SHA256.hash(data: gz).map { String(format: "%02x", $0) }.joined()
        #expect(try ImageFetch.sha256Streaming(of: URL(fileURLWithPath: dir + "/got.gz")) == want)
        try ImageFetch.expandGzipSparse(from: URL(fileURLWithPath: dir + "/got.gz"), to: URL(fileURLWithPath: dir + "/disk.img"),
                                        expectedBytes: Int64(raw.count)) { _ in }
        #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/disk.img")) == raw)
        var st = stat()
        #expect(stat(dir + "/disk.img", &st) == 0)
        #expect(Int(st.st_blocks) * 512 < raw.count, "the zeros are holes")
        // A size the catalog doesn't say is refused.
        #expect(throws: ImageFetchError.self) {
            try ImageFetch.expandGzipSparse(from: URL(fileURLWithPath: dir + "/got.gz"), to: URL(fileURLWithPath: dir + "/bad.img"),
                                            expectedBytes: 123) { _ in }
        }
    }
}

/// A loopback HTTP server answering every request with `body`.
final class BinaryUpstream: @unchecked Sendable {
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    init(body: Data) throws {
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(body)) }
            .bind(host: "127.0.0.1", port: 0).wait()
    }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let body: Data
        var head = ""
        var answered = false
        init(_ body: Data) { self.body = body }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            head += b.readString(length: b.readableBytes) ?? ""
            guard !answered, head.contains("\r\n\r\n") else { return }
            answered = true
            var out = context.channel.allocator.buffer(string: "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n")
            out.writeBytes(body)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in context.close(promise: nil) }
        }
    }
}
