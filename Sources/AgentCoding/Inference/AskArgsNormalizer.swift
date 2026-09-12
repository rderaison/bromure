import Foundation

/// Normalizes a local model's call to omp's native `ask` tool so omp's
/// (arktype) validator accepts it.
///
/// omp's `ask` schema (verified against @oh-my-pi/pi-coding-agent v18's
/// `cli.js`): each QUESTION requires `id` (a string — its answer references
/// `questionId`) plus `question`, with `header?`, `options[]`, `multi?` and
/// `recommended?` (an option INDEX). Each OPTION is `{label, description?,
/// preview?}` and is keyed by its LABEL — omp derives option ids itself, so an
/// option must NOT carry an `id`.
///
/// Local quantized models routinely invert this: they put an `id` on each
/// OPTION and omit it on each QUESTION (and sometimes use Claude's `multiSelect`
/// key). omp then strips the option ids and rejects the call for the missing
/// question id ("questions[0].id must be question id (was missing)"). We fix the
/// call in flight — only for a tool literally named `ask`, so Claude Code's
/// `AskUserQuestion` and every other tool are untouched.
enum AskArgsNormalizer {

    /// Reshape one parsed `ask` arguments object to omp's schema.
    static func normalize(_ args: [String: Any]) -> [String: Any] {
        guard var questions = args["questions"] as? [[String: Any]] else { return args }
        for i in questions.indices {
            var q = questions[i]

            // 1. Every question needs a non-empty string id.
            if (q["id"] as? String).map({ $0.isEmpty }) ?? true {
                q["id"] = questionID(q, index: i)
            }
            // 2. Claude's `multiSelect` → omp's `multi`.
            if q["multi"] == nil, let ms = q["multiSelect"] {
                q["multi"] = ms
            }
            q["multiSelect"] = nil
            // 3. Options carry only label/description/preview — no id (omp keys
            //    them by label and derives ids itself).
            if let options = q["options"] as? [[String: Any]] {
                q["options"] = options.map { o in
                    var clean: [String: Any] = [:]
                    if let l = o["label"] { clean["label"] = l }
                    if let d = o["description"] { clean["description"] = d }
                    if let p = o["preview"] { clean["preview"] = p }
                    return clean
                }
            }
            questions[i] = q
        }
        var out = args
        out["questions"] = questions
        return out
    }

    /// Apply `normalize` to every `ask` tool call in an OpenAI chat/completions
    /// response (the shape omp uses — provider `openai-completions`). Returns the
    /// message unchanged when there's nothing to fix.
    static func normalizeChatMessage(_ message: [String: Any]) -> [String: Any] {
        guard var choices = message["choices"] as? [[String: Any]] else { return message }
        var changed = false
        for ci in choices.indices {
            guard var msg = choices[ci]["message"] as? [String: Any],
                  var calls = msg["tool_calls"] as? [[String: Any]] else { continue }
            var touched = false
            for ti in calls.indices {
                guard var fn = calls[ti]["function"] as? [String: Any],
                      (fn["name"] as? String) == "ask",
                      let argStr = fn["arguments"] as? String,
                      let data = argStr.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let normalized = normalize(args)
                guard let outData = try? JSONSerialization.data(withJSONObject: normalized),
                      let outStr = String(data: outData, encoding: .utf8) else { continue }
                fn["arguments"] = outStr
                calls[ti]["function"] = fn
                touched = true
            }
            if touched {
                msg["tool_calls"] = calls
                choices[ci]["message"] = msg
                changed = true
            }
        }
        guard changed else { return message }
        var out = message
        out["choices"] = choices
        return out
    }

    /// A stable, valid question id from the header (else the question text, else
    /// the 1-based index). Slugged to `[a-z0-9_]`; omp only needs a non-empty
    /// string that's unique enough to key the answer.
    private static func questionID(_ q: [String: Any], index: Int) -> String {
        let source = (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (q["question"] as? String) ?? ""
        var slug = String(source.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
        while slug.contains("__") { slug = slug.replacingOccurrences(of: "__", with: "_") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "q\(index + 1)" : slug
    }
}
