import NIOCore
import NIOPosix
import NIOSSH
import NIOSSL
import Crypto
import _CryptoExtras
import X509
import Foundation

final class Echo: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
}
final class Collect: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let done: EventLoopPromise<String>
    init(_ p: EventLoopPromise<String>) { done = p }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var b = unwrapInboundIn(data); done.succeed(b.readString(length: b.readableBytes) ?? "")
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
let server = try ServerBootstrap(group: group)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
    .bind(host: "127.0.0.1", port: 0).wait()
let p = group.next().makePromise(of: String.self)
let client = try ClientBootstrap(group: group)
    .channelInitializer { $0.pipeline.addHandler(Collect(p)) }
    .connect(to: server.localAddress!).wait()
try client.writeAndFlush(ByteBuffer(string: "bromure-echo")).wait()
print("NIO echo:", try p.futureResult.wait())

// Touch the rest of the stack so it links.
let key = P256.Signing.PrivateKey()
let name = try DistinguishedName { CommonName("bromure-smoke") }
let now = Date()
let cert = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
    notValidBefore: now, notValidAfter: now + 3600, issuer: name, subject: name,
    signatureAlgorithm: .ecdsaWithSHA256, extensions: .init(), issuerPrivateKey: .init(key))
print("X509 self-signed:", cert.subject)
let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
print("_CryptoExtras RSA bits:", rsa.keySizeInBits)
_ = NIOSSHPrivateKey(ed25519Key: .init())
print("NIOSSH ed25519 key ok; NIOSSL", try NIOSSLContext(configuration: .makeClientConfiguration()) as Any? != nil ? "context ok" : "fail")
try client.close().wait(); try server.close().wait(); try group.syncShutdownGracefully()
