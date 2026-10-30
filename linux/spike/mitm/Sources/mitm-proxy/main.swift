import Foundation
import MitmCore
import NIOCore
import NIOPosix
import NIOSSL

// mitm-proxy --listen IP:PORT --ca-dir DIR [--upstream-ca PEM] [--route-all IP:PORT]
// The CA is loaded from DIR/ca.pem + DIR/ca-key.pem, or created there.
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func hostPort(_ s: String) -> (String, Int) {
    let c = s.lastIndex(of: ":")!
    return (String(s[..<c]), Int(s[s.index(after: c)...])!)
}
let (lh, lp) = hostPort(opt("--listen") ?? "127.0.0.1:8443")
let caDir = opt("--ca-dir") ?? "./mitm-ca"
try FileManager.default.createDirectory(atPath: caDir, withIntermediateDirectories: true)
let ca: CertificateAuthority
if let c = try? String(contentsOfFile: caDir + "/ca.pem", encoding: .utf8),
   let k = try? String(contentsOfFile: caDir + "/ca-key.pem", encoding: .utf8) {
    ca = try CertificateAuthority.load(certPEM: c, keyPEM: k)
} else {
    ca = try CertificateAuthority.generate()
    try ca.certificatePEM.write(toFile: caDir + "/ca.pem", atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: caDir + "/ca-key.pem", contents: Data(ca.keyPEM.utf8),
                                   attributes: [.posixPermissions: 0o600])
}
var cfg = InterceptingProxy.Config(ca: ca)
if let extra = opt("--upstream-ca") { cfg.extraTrustRoots = try NIOSSLCertificate.fromPEMFile(extra) }
if let r = opt("--route-all") { cfg.routeAllTo = hostPort(r) }
let proxy = InterceptingProxy(config: cfg)
let ch = try proxy.listen(host: lh, port: lp)
print("mitm-proxy listening on \(ch.localAddress!) CA \(caDir)/ca.pem")
fflush(stdout)
// Stats on SIGUSR1-free polling: one line every 5 s when something changed.
var last = ""
while true {
    sleep(5)
    let s = proxy.snapshot
    let line = "accepted \(s.accepted) intercepted \(s.intercepted) (h2 \(s.h2), http/1.1 \(s.http1)) failed \(s.failed) minted \(ca.minted) cache-hits \(ca.cacheHits)"
    if line != last { print(line); fflush(stdout); last = line }
}
