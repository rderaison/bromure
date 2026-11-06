import Crypto
import Foundation

/// The SHA-256 each prompt-injection detector file must have: the copies on
/// dl.bromure.io as of 2026-06-10. A download that doesn't match is
/// refused. The classifier checks an installed model as it loads it, off
/// the main thread: a file that doesn't match (changed or damaged on disk)
/// is deleted, never loaded, and so fetched again. `isInstalled` only asks
/// the verdict already known (it never hashes on its caller's thread).
/// Rampart keeps its own pins with its pinned Hugging Face revision
/// (PromptInjectionModels).
enum PromptInjectionModelPins {
    /// By model directory (`PromptInjectionModels.Kind.dirName`), then file.
    static let sha256: [String: [String: String]] = [
        "prompt-injection": [
            "model.onnx": "3ca25030566076c92c19168a64d6e203e4397cd936f55dd0345b4d3c6fbd9744",
            "tokenizer.json": "870798f0e3bb05c636bf62be904b2d8f48ace4785e9c1d71a8a67bd0586c941d",
            "tokenizer_config.json": "e4f86bc439a2cad164a852922ea998031ea5c2417674f9fa269bb9db45a120bb",
            "special_tokens_map.json": "b2f1b2f15f29a6b6d9d6ea4eca1675d2c231a71477f151d48f79cc83a625ba21",
        ],
        "claudemd-guard": [
            "model.onnx": "7048173e4fb0176504448887800856fd34f64204f8cc9a04cb0c6b833ddf545b",
            "tokenizer.json": "ca870c678352403d107496dc78899fa666ed0f56fef63e88ae398fafe5d78c45",
            "tokenizer_config.json": "fb54f027372062b2ca52282efb04d178a8b57167a00cd8f4e816515823a2c016",
            "config.json": "55f0cef0948a2c0c5dfa39d40cfc883302f44ee30b5a88ee357a4baf144033f5",
        ],
    ]

    static func expected(dir: String, file: String) -> String? { sha256[dir]?[file] }

    /// The file's SHA-256, hex, read in 1 MiB chunks (a model is 600 MB).
    static func hex(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Seen { let size: Int; let modified: Date; let want: String; let ok: Bool }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String: Seen] = [:]

    private static func stamp(_ url: URL) -> (size: Int, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? Int, let modified = a[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    /// What's known of the file at `url` against `want`, without hashing it:
    /// nil when it hasn't been hashed as it is now (a cold cache, or it
    /// changed since). Cheap enough for any thread.
    static func cachedVerdict(_ url: URL, sha256 want: String) -> Bool? {
        guard let st = stamp(url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let c = seen[url.path], c.size == st.size, c.modified == st.modified, c.want == want else { return nil }
        return c.ok
    }

    /// Whether the file at `url` hashes to `want`, hashing it unless the
    /// verdict is already known for it as it is now. Blocks (a model is
    /// 600 MB): off the main thread. A missing file doesn't match.
    static func matches(_ url: URL, sha256 want: String) -> Bool {
        if let known = cachedVerdict(url, sha256: want) { return known }
        guard let st = stamp(url) else { return false }
        let ok = (try? hex(of: url)) == want
        record(url, sha256: want, ok: ok, size: st.size, modified: st.modified)
        return ok
    }

    /// A file just checked (a download, hashed before it was moved into
    /// place): its verdict, so its first load doesn't hash it again.
    static func noteVerified(_ url: URL, sha256 want: String) {
        guard let st = stamp(url) else { return }
        record(url, sha256: want, ok: true, size: st.size, modified: st.modified)
    }

    private static func record(_ url: URL, sha256 want: String, ok: Bool, size: Int, modified: Date) {
        lock.lock()
        seen[url.path] = Seen(size: size, modified: modified, want: want, ok: ok)
        lock.unlock()
    }

    /// Hash each pinned file of model `dirName` in `folder` (blocking: off the
    /// main thread) and delete the ones that don't match, so the model reads
    /// as not installed and is fetched again. The names deleted; the caller
    /// doesn't load the model when there are any. A file that isn't there is
    /// the caller's to report, not deleted here.
    static func removeMismatched(dirName: String, in folder: URL) -> [String] {
        var bad: [String] = []
        for (file, want) in (sha256[dirName] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path), !matches(url, sha256: want) else { continue }
            try? FileManager.default.removeItem(at: url)
            lock.lock(); seen[url.path] = nil; lock.unlock()
            bad.append(file)
        }
        return bad
    }
}
