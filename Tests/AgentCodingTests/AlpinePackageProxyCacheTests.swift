import Foundation
import Testing
@testable import bromure_ac

@Suite("Package proxy immutable-artifact cache")
struct AlpinePackageProxyCacheTests {

    @Test("Immutable artifacts are cacheable")
    func cacheable() {
        let immutable = [
            // apt content-addressed index (the big apt-get update payload)
            "https://ports.ubuntu.com/ubuntu-ports/dists/noble/universe/binary-arm64/by-hash/SHA256/0f2a1b3c4d5e6f708192a3b4c5d6e7f80f2a1b3c4d5e6f708192a3b4c5d6e7f8",
            // Debian pool artifacts — version is in the filename
            "https://ports.ubuntu.com/ubuntu-ports/pool/universe/x/xclip/xclip_0.13-3_arm64.deb",
            "https://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/linux-libc-dev_6.8.0-1_arm64.udeb",
            // Alpine versioned packages + pinned release artifacts
            "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/e2fsprogs-1.47.1-r1.apk",
            "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/netboot-3.22.3/modloop-virt",
        ]
        for url in immutable {
            let key = AlpinePackageProxy.cacheKey(for: URL(string: url)!)
            #expect(key != nil, "expected cacheable: \(url)")
            #expect(key?.count == 64)
            #expect(key?.allSatisfy(\.isHexDigit) == true)
        }
    }

    @Test("Mutable metadata is never cached")
    func mutable() {
        let mutable = [
            // Signed release metadata — freshness IS the point.
            "https://ports.ubuntu.com/ubuntu-ports/dists/noble/InRelease",
            "https://ports.ubuntu.com/ubuntu-ports/dists/noble-updates/Release",
            // Non-by-hash index name: rewritten on every archive publish.
            "https://ports.ubuntu.com/ubuntu-ports/dists/noble/universe/binary-arm64/Packages.xz",
            // Alpine channel index: mutates within v3.22 as packages land.
            "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/APKINDEX.tar.gz",
            // Unversioned vendor tarball (mutable under a stable URL).
            "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-arm.tar.gz",
        ]
        for url in mutable {
            #expect(AlpinePackageProxy.cacheKey(for: URL(string: url)!) == nil,
                    "expected uncacheable: \(url)")
        }
    }

    @Test("Keys are deterministic and collision-free across URLs")
    func keys() {
        let a = URL(string: "https://ports.ubuntu.com/ubuntu-ports/pool/universe/x/xclip/xclip_0.13-3_arm64.deb")!
        let b = URL(string: "https://mirror.example.com/ubuntu-ports/pool/universe/x/xclip/xclip_0.13-3_arm64.deb")!
        #expect(AlpinePackageProxy.cacheKey(for: a) == AlpinePackageProxy.cacheKey(for: a))
        // Same file on a different mirror gets its own entry — the key
        // covers the whole URL, not just the basename.
        #expect(AlpinePackageProxy.cacheKey(for: a) != AlpinePackageProxy.cacheKey(for: b))
    }

    @Test("by-hash URLs carry their own body digest, others don't")
    func byHashDigest() {
        let digest = String(repeating: "ab", count: 32)
        let byHash = URL(string: "https://ports.ubuntu.com/ubuntu-ports/dists/noble/main/binary-arm64/by-hash/SHA256/\(digest)")!
        #expect(AlpinePackageProxy.byHashDigest(of: byHash) == digest)
        // MD5Sum by-hash exists in the wild — only SHA256 paths qualify.
        let md5 = URL(string: "https://ports.ubuntu.com/x/by-hash/MD5Sum/d41d8cd98f00b204e9800998ecf8427e")!
        #expect(AlpinePackageProxy.byHashDigest(of: md5) == nil)
        // Malformed digest component → no verification contract.
        let short = URL(string: "https://ports.ubuntu.com/x/by-hash/SHA256/abc123")!
        #expect(AlpinePackageProxy.byHashDigest(of: short) == nil)
        #expect(AlpinePackageProxy.byHashDigest(of: URL(string: "https://ports.ubuntu.com/pool/a.deb")!) == nil)
        #expect(AlpinePackageProxy.byHashDigest(of: nil) == nil)
    }
}
