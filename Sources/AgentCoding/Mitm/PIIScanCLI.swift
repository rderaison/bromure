import Foundation

/// `bromure-ac __pii-scan <file>… [--min 0.6] [--quiet]` — run the PII
/// detector over plain files or Claude Code transcripts (.jsonl: every string
/// in each line is scanned, the way the proxy scans a request) and report
/// what it found and how long it took.
enum PIIScanCLI {
    static func run(_ args: [String]) {
        var files: [String] = []
        var minScore = PIIDetector.defaultMinScore
        var quiet = false
        var planned = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--min": i += 1; minScore = Double(args[i]) ?? minScore
            case "--quiet": quiet = true
            case "--plan": planned = true
            default: files.append(args[i])
            }
            i += 1
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await scan(files, minScore: minScore, quiet: quiet, planned: planned)
            done.signal()
        }
        done.wait()
    }

    private static func strings(in file: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        guard file.hasSuffix(".jsonl") else { return [String(decoding: data, as: UTF8.self)] }
        var out: [String] = []
        func walk(_ v: Any, key: String?) {
            if let s = v as? String {
                if let key, PIIRewriter.skipKeys.contains(key) { return }
                if s.utf16.count >= 3 { out.append(s) }
            } else if let a = v as? [Any] {
                a.forEach { walk($0, key: key) }
            } else if let d = v as? [String: Any] {
                d.forEach { walk($0.value, key: $0.key) }
            }
        }
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let msg = obj["message"] else { continue }
            walk(msg, key: nil)
        }
        return out
    }

    private static func scan(_ files: [String], minScore: Double, quiet: Bool, planned: Bool) async {
        let available = await PIIDetector.shared.modelAvailable
        print("model: \(available ? "loaded" : "MISSING (recognizers only)")  minScore: \(minScore)")
        var byLabel: [PIILabel: Int] = [:]
        var examples: [PIILabel: [String: Int]] = [:]
        var totalUnits = 0
        var nStrings = 0
        let t0 = Date()
        var slowest: (ms: Double, units: Int) = (0, 0)
        for f in files {
            for s in strings(in: f) {
                nStrings += 1
                totalUnits += s.utf16.count
                let t = Date()
                var (spans, _) = await PIIDetector.shared.detect(s, minScore: minScore)
                if planned { spans = PIIRewriter.plan(spans, in: s, policy: PIIPolicy(enabled: true)) }
                let ms = Date().timeIntervalSince(t) * 1000
                if ms > slowest.ms { slowest = (ms, s.utf16.count) }
                let ns = s as NSString
                for sp in spans {
                    byLabel[sp.label, default: 0] += 1
                    let text = ns.substring(with: NSRange(location: sp.start, length: sp.length))
                        .replacingOccurrences(of: "\n", with: "⏎")
                    examples[sp.label, default: [:]][text, default: 0] += 1
                }
            }
        }
        let total = Date().timeIntervalSince(t0) * 1000
        print(String(format: "%d strings, %.1f K chars, %.0f ms total (%.2f ms per 1K chars); slowest %.0f ms for %d chars",
                     nStrings, Double(totalUnits) / 1000, total, total / max(1, Double(totalUnits) / 1000),
                     slowest.ms, slowest.units))
        for (label, n) in byLabel.sorted(by: { $0.value > $1.value }) {
            let top = (examples[label] ?? [:]).sorted { $0.value > $1.value }.prefix(quiet ? 8 : 25)
                .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            print("  \(label.rawValue): \(n)  — \(top)")
        }
    }
}
