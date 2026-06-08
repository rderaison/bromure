import Foundation
import Compression

/// npm-registry-specific transforms applied to upstream responses
/// before they reach the agent.
///
/// Two distinct transforms:
///   - `filterMetadata` — rewrite the JSON manifest npm fetches from
///     `GET registry.npmjs.org/<pkg>` to drop too-fresh versions and
///     to scrub `dist.integrity` / `dist.shasum` (we strip the tarball
///     downstream so the original hash would fail npm's verification).
///   - `stripScriptsFromTarball` — gunzip the `.tgz` body, locate the
///     `package/package.json` tar entry, remove install-script
///     keys, re-checksum that entry's tar header, gzip the result.
///
/// Both transforms accept the **full HTTP response bytes** (status
/// line + headers + body) the proxy collected and return the new
/// HTTP response bytes, ready to be written to the TLS-server
/// stream. They keep all original headers except `Content-Length`,
/// which they recompute against the modified body.
public enum NPMRegistryTransforms {

    // MARK: - Metadata filter (age gate)

    /// Filter an upstream `GET registry.npmjs.org/<pkg>` response.
    /// `now` is the cutoff anchor; versions whose `time[version]`
    /// is newer than `now - days * 86400 s` are removed (unless the
    /// package itself is on the allowlist, in which case the
    /// response is forwarded untouched). `dist-tags.*` are rewritten
    /// to point at the newest remaining version that's not above
    /// the originally tagged one.
    ///
    /// If `stripIntegrity` is true, every surviving version's
    /// `dist.integrity` / `dist.shasum` are removed so npm computes
    /// the hash itself from the (potentially script-stripped) tarball
    /// we'll serve next.
    public static func filterMetadata(rawResponse: Data,
                                       packageName: String,
                                       allowedAfter cutoff: Date,
                                       allowlistedPackage: Bool,
                                       stripIntegrity: Bool,
                                       publishTimes: inout [(String, Date)]) -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts

        // If allowlisted, we still need to strip dist.integrity when
        // we plan to rewrite tarballs — but no age filtering.
        if allowlistedPackage && !stripIntegrity {
            return rawResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return rawResponse
        }
        var manifest = json

        // 1. Identify versions to drop. Also record every per-version
        //    timestamp so the artifact-fetch backstop can look them
        //    up without re-fetching metadata.
        let timeMap = (manifest["time"] as? [String: String]) ?? [:]
        var droppedVersions = Set<String>()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        for (version, dateStr) in timeMap {
            if version == "created" || version == "modified" { continue }
            let date = iso.date(from: dateStr) ?? isoNoFraction.date(from: dateStr)
            guard let d = date else { continue }
            publishTimes.append((version, d))
            if !allowlistedPackage && d > cutoff {
                droppedVersions.insert(version)
            }
        }

        // 2. Drop them from `versions{}` + `time{}`.
        if var versions = manifest["versions"] as? [String: Any] {
            for v in droppedVersions { versions.removeValue(forKey: v) }
            if stripIntegrity {
                for (k, v) in versions {
                    guard var ver = v as? [String: Any] else { continue }
                    if var dist = ver["dist"] as? [String: Any] {
                        dist.removeValue(forKey: "integrity")
                        dist.removeValue(forKey: "shasum")
                        ver["dist"] = dist
                    }
                    versions[k] = ver
                }
            }
            manifest["versions"] = versions
        }
        if var times = manifest["time"] as? [String: String] {
            for v in droppedVersions { times.removeValue(forKey: v) }
            manifest["time"] = times
        }

        // 3. Rewrite dist-tags. Any tag pointing at a dropped version
        // gets re-aimed at the newest remaining version that's
        // semver-comparable AND not above the original tag's version.
        // We don't try to preserve semver-range semantics for tags
        // like `beta` — just point at the highest non-dropped
        // version. That's the behaviour the user asked for.
        if var distTags = manifest["dist-tags"] as? [String: String] {
            let remaining: [String] = Array(
                (manifest["versions"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
            let newest = remaining.max(by: compareSemver) ?? ""
            for (tag, version) in distTags {
                if droppedVersions.contains(version) {
                    distTags[tag] = newest
                }
            }
            manifest["dist-tags"] = distTags
        }

        // 4. Re-serialize + rebuild HTTP response.
        guard let newBody = try? JSONSerialization.data(withJSONObject: manifest,
                                                        options: [.sortedKeys]) else {
            return rawResponse
        }
        return rebuildHTTPResponse(originalHead: head, newBody: newBody)
    }

    // MARK: - Tarball: strip install scripts

    /// Walk a `.tgz` HTTP response body, find `package/package.json`,
    /// remove `scripts.preinstall` / `scripts.install` /
    /// `scripts.postinstall` / `scripts.prepare`, re-emit the
    /// tarball. Returns the rewritten full HTTP response bytes.
    ///
    /// Falls back to the original response on any parse failure —
    /// silent fallthrough is the right move here because supply-
    /// chain transforms shouldn't be able to brick an install of a
    /// well-formed package.
    public static func stripScriptsFromTarball(rawResponse: Data) -> (data: Data, didStrip: Bool) {
        guard let parts = splitHTTPResponse(rawResponse) else { return (rawResponse, false) }
        let (head, body) = parts

        guard let unzipped = gunzip(body) else { return (rawResponse, false) }
        guard let (newTar, didStrip) = rewriteTarStripScripts(unzipped) else {
            return (rawResponse, false)
        }
        if didStrip {
            guard let regz = gzip(newTar) else { return (rawResponse, false) }
            return (rebuildHTTPResponse(originalHead: head, newBody: regz), true)
        }
        // We *inspected* the tarball but found no install scripts to
        // strip — tag the response so the log window / debugging
        // sees "proxy considered this package" without paying the
        // cost of a needless gzip round-trip on the body.
        return (tagInspected(rawResponse: rawResponse), false)
    }

    // MARK: - Tar walker

    /// POSIX-tar walker that locates `package/package.json`, parses it
    /// as JSON, removes the four script keys, recomputes the entry's
    /// tar header checksum + size, and re-emits the archive. Other
    /// entries are byte-identical pass-through.
    ///
    /// Returns nil if the input isn't well-formed POSIX tar (we never
    /// rewrite something we don't understand).
    private static func rewriteTarStripScripts(_ tar: Data) -> (Data, Bool)? {
        var out = Data()
        var i = 0
        let blockSize = 512
        var didStrip = false

        while i + blockSize <= tar.count {
            let header = tar.subdata(in: i..<(i + blockSize))
            // Zero block = EOF marker. Tar archives end with two
            // zeroed blocks. Once we hit one, copy the rest and stop.
            if header.allSatisfy({ $0 == 0 }) {
                out.append(tar.subdata(in: i..<tar.count))
                return (out, didStrip)
            }

            // ustar magic at offset 257 — relaxed: we accept any
            // POSIX-ish tar, but we need to confirm we're aligned.
            // The minimal thing we need: read size + name + type.
            guard let nameWithPrefix = readTarName(header) else { return nil }
            guard let size = readTarSize(header) else { return nil }
            let typeflag = header[i_off: 156]

            // Round file size up to next 512-byte block.
            let dataBlocks = (size + blockSize - 1) / blockSize
            let dataBytes = dataBlocks * blockSize
            let dataStart = i + blockSize
            let dataEnd   = dataStart + dataBytes
            guard dataEnd <= tar.count else { return nil }

            // Target: `package/package.json` (note: the directory
            // prefix is conventionally `package/`, but some tools
            // emit non-`package/` prefixes — we accept anything that
            // ends with `/package.json` AND is a regular file).
            let isPackageJSON = (typeflag == 0x30 || typeflag == 0)
                && (nameWithPrefix == "package/package.json"
                    || nameWithPrefix.hasSuffix("/package.json"))
                && !nameWithPrefix.contains("node_modules/")
                && {
                    // Don't rewrite vendored sub-package.json files
                    // — only the *top-level* one (one slash exactly).
                    let comp = nameWithPrefix.split(separator: "/").count
                    return comp == 2
                }()

            if isPackageJSON, size > 0 {
                let jsonBytes = tar.subdata(in: dataStart..<(dataStart + size))
                if let (newJSON, stripped) = stripPackageJSONScripts(jsonBytes), stripped {
                    didStrip = true
                    let newSize = newJSON.count
                    // Build a new header with updated size + checksum.
                    let newHeader = updateTarHeader(header,
                                                    newSize: newSize)
                    out.append(newHeader)
                    out.append(newJSON)
                    // Pad to 512-byte boundary.
                    let pad = (blockSize - (newSize % blockSize)) % blockSize
                    if pad > 0 { out.append(Data(repeating: 0, count: pad)) }
                } else {
                    // Couldn't parse — pass through unmodified.
                    out.append(tar.subdata(in: i..<dataEnd))
                }
            } else {
                out.append(tar.subdata(in: i..<dataEnd))
            }
            i = dataEnd
        }

        // Reached end of data without a zero-block terminator — tar
        // archives normally have two 512-byte zero blocks at the
        // tail. Append the rest verbatim.
        out.append(tar.subdata(in: i..<tar.count))
        return (out, didStrip)
    }

    /// Modify package.json bytes to remove install scripts. Returns
    /// the new bytes + a `didStrip` flag (false if there was nothing
    /// to remove).
    private static func stripPackageJSONScripts(_ raw: Data) -> (Data, Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        var pkg = json
        guard var scripts = pkg["scripts"] as? [String: Any] else {
            return (raw, false)   // No scripts → nothing to do.
        }
        let toRemove = ["preinstall", "install", "postinstall", "prepare"]
        var didStrip = false
        for key in toRemove where scripts[key] != nil {
            scripts.removeValue(forKey: key)
            didStrip = true
        }
        if !didStrip { return (raw, false) }
        if scripts.isEmpty {
            pkg.removeValue(forKey: "scripts")
        } else {
            pkg["scripts"] = scripts
        }
        // Round-trip via JSONSerialization to get a stable encoding.
        // .sortedKeys keeps the rewritten file deterministic so
        // re-runs over the same upstream are byte-identical.
        guard let out = try? JSONSerialization.data(withJSONObject: pkg,
                                                     options: [.sortedKeys]) else {
            return nil
        }
        return (out, true)
    }

    // MARK: - tar header parsing helpers

    private static func readTarName(_ header: Data) -> String? {
        // POSIX-ustar: name is bytes 0..100, prefix is bytes 345..500
        // (when prefix is non-empty, full path is `prefix + "/" + name`).
        let name = header.cString(from: 0, length: 100) ?? ""
        let prefix = header.cString(from: 345, length: 155) ?? ""
        if name.isEmpty { return nil }
        return prefix.isEmpty ? name : "\(prefix)/\(name)"
    }
    private static func readTarSize(_ header: Data) -> Int? {
        // Size at offset 124..136 (12 bytes, octal, NUL- or space-padded).
        guard let octal = header.cString(from: 124, length: 12) else { return nil }
        // tar size fields may be 0-padded or space-padded; ignore non-digits.
        let digits = octal.unicodeScalars.filter { ("0"..."7").contains(Character($0)) }
        guard !digits.isEmpty else { return 0 }
        return Int(String(String.UnicodeScalarView(digits)), radix: 8)
    }
    /// Update the size field at 124..136 and recompute the checksum
    /// at 148..156. All other fields are preserved bit-identical.
    private static func updateTarHeader(_ original: Data, newSize: Int) -> Data {
        var h = original
        // Size: 11 octal digits + NUL.
        let sizeStr = String(format: "%011o", newSize) + "\0"
        let sizeBytes = Array(sizeStr.utf8)
        for (idx, byte) in sizeBytes.prefix(12).enumerated() {
            h[124 + idx] = byte
        }
        // Zero the checksum field (148..156) then sum every byte of the
        // header as unsigned. Treat the checksum field as 8 spaces
        // for sum purposes (POSIX rule).
        for j in 148..<156 { h[j] = 0x20 }   // 8 spaces
        var sum = 0
        for j in 0..<512 { sum += Int(h[j]) }
        // 6 octal digits + NUL + space.
        let cks = String(format: "%06o", sum) + "\0 "
        let cksBytes = Array(cks.utf8)
        for (idx, byte) in cksBytes.prefix(8).enumerated() {
            h[148 + idx] = byte
        }
        return h
    }

    // MARK: - HTTP response splitter / rebuilder

    private static func splitHTTPResponse(_ raw: Data) -> (head: String, body: Data)? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = raw.subdata(in: 0..<sep.lowerBound)
        let body     = raw.subdata(in: sep.upperBound..<raw.count)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        return (head, body)
    }

    private static func rebuildHTTPResponse(originalHead: String, newBody: Data) -> Data {
        // Strip any existing Content-Length / Transfer-Encoding lines
        // and append a fresh Content-Length matching the new body.
        var lines = originalHead.components(separatedBy: "\r\n")
        lines.removeAll { line in
            let lower = line.lowercased()
            return lower.hasPrefix("content-length:")
                || lower.hasPrefix("transfer-encoding:")
                || lower.hasPrefix("content-encoding:")
        }
        // Insert the marker right after the HTTP/1.1 status line so
        // it's visible in the first ~100 bytes of any header dump
        // (npm and PyPI both pile on dozens of CDN / cache headers,
        // pushing an appended marker past common truncation limits).
        if !lines.isEmpty {
            lines.insert("X-Bromure-Rewritten: supply-chain", at: 1)
        } else {
            lines.append("X-Bromure-Rewritten: supply-chain")
        }
        lines.append("Content-Length: \(newBody.count)")
        var head = lines.joined(separator: "\r\n")
        head += "\r\n\r\n"
        var out = Data(head.utf8)
        out.append(newBody)
        return out
    }

    /// Inject the `X-Bromure-Rewritten` marker into the response head
    /// without touching the body. Used when we *inspected* the
    /// payload but didn't need to rewrite anything (e.g. tarball had
    /// no install scripts to strip) — re-encoding the body would
    /// burn CPU for zero behavior change, but the user still wants
    /// to see "the proxy considered this" in the log window.
    static func tagInspected(rawResponse: Data) -> Data {
        guard let parts = splitHTTPResponse(rawResponse) else { return rawResponse }
        let (head, body) = parts
        var lines = head.components(separatedBy: "\r\n")
        if !lines.isEmpty {
            lines.insert("X-Bromure-Rewritten: supply-chain", at: 1)
        } else {
            lines.append("X-Bromure-Rewritten: supply-chain")
        }
        var newHead = lines.joined(separator: "\r\n")
        newHead += "\r\n\r\n"
        var out = Data(newHead.utf8)
        out.append(body)
        return out
    }

    // MARK: - gzip / gunzip

    private static func gunzip(_ data: Data) -> Data? {
        // Compression.framework's `decompress` expects raw deflate
        // when run with .zlib, and zlib (with adler) for .zlib.
        // Neither directly decodes the gzip wrapper, so we strip the
        // gzip header (10-byte minimum) + footer (8 bytes) ourselves
        // and feed the deflate payload to the raw decoder.
        guard data.count > 18,
              data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else { return nil }
        var offset = 10
        let flags = data[3]
        // FEXTRA
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else { return nil }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }
        // 8-byte footer (crc32 + isize).
        let payloadEnd = data.count - 8
        guard offset < payloadEnd else { return nil }
        let payload = data.subdata(in: offset..<payloadEnd)
        // Grow until the decompressor consumes everything.
        var out = Data(count: max(payload.count * 6, 1024 * 1024))
        let count: Int = out.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dst.count,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB)
            }
        }
        guard count > 0 else { return nil }
        return out.prefix(count)
    }

    private static func gzip(_ data: Data) -> Data? {
        // Encode raw deflate via Compression.framework, then prepend
        // a minimal 10-byte gzip header + append CRC32 + ISIZE.
        var out = Data(count: max(data.count + 64, 4096))
        let deflated: Data
        let count: Int = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    dst.count,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB)
            }
        }
        if count <= 0 {
            // Buffer too small — try once with a bigger one.
            out = Data(count: max(data.count * 2, 16 * 1024 * 1024))
            let c2: Int = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_encode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        dst.count,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB)
                }
            }
            guard c2 > 0 else { return nil }
            deflated = out.prefix(c2)
        } else {
            deflated = out.prefix(count)
        }

        // Build gzip wrapper.
        var gz = Data()
        gz.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00,
                                0x00, 0x00, 0x00, 0x00,   // mtime = 0
                                0x00, 0xff])              // xfl, OS=unknown
        gz.append(deflated)
        let crc = crc32(data)
        gz.append(UInt8(crc & 0xff))
        gz.append(UInt8((crc >> 8) & 0xff))
        gz.append(UInt8((crc >> 16) & 0xff))
        gz.append(UInt8((crc >> 24) & 0xff))
        let isize = UInt32(data.count & 0xFFFFFFFF)
        gz.append(UInt8(isize & 0xff))
        gz.append(UInt8((isize >> 8) & 0xff))
        gz.append(UInt8((isize >> 16) & 0xff))
        gz.append(UInt8((isize >> 24) & 0xff))
        return gz
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (UInt32(0xEDB88320) & UInt32(0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Semver-ish compare (newest-first)

    /// Best-effort version compare. Real semver tooling would handle
    /// pre-release tags + build metadata; we just need to pick the
    /// "newest" version for dist-tag rewrites where the tag's
    /// original target was filtered out.
    private static func compareSemver(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<min(pa.count, pb.count) {
            if pa[i] != pb[i] { return pa[i] < pb[i] }
        }
        return pa.count < pb.count
    }
}

// MARK: - Data helpers

private extension Data {
    /// Read a NUL- (or NUL-or-space-) terminated C string at
    /// (offset, length).
    func cString(from offset: Int, length: Int) -> String? {
        guard offset + length <= count else { return nil }
        let slice = subdata(in: offset..<(offset + length))
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(data: slice[slice.startIndex..<end], encoding: .ascii)
    }

    /// Byte at offset (panics if OOB — only call with bounds-checked
    /// offsets).
    subscript(i_off offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
