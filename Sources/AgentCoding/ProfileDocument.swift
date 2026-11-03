import Foundation

/// Profile documents as `workspaces create/edit --from-json` (and the control
/// API's POST/PUT /profiles) send them: possibly partial — only the fields to
/// change. They are overlaid key by key on a base profile's own document
/// (the template for a create, the stored workspace for an edit), so an
/// omitted key keeps its value and an explicit `null` clears an optional one.
enum ProfileDocument {
    /// `doc` overlaid on `base`, decoded. On failure, a message naming the
    /// offending field ("authMode: unknown value \"tokn\"").
    static func merge(_ doc: [String: Any], over base: Profile) -> Result<Profile, ProfileDocumentError> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let baseData = try? encoder.encode(base),
              var merged = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else {
            return .failure(ProfileDocumentError(message: "Internal error encoding the workspace."))
        }
        for (k, v) in doc { merged[k] = v }
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged) else {
            return .failure(ProfileDocumentError(message: "Invalid profile document: not valid JSON."))
        }
        do {
            return .success(try decoder.decode(Profile.self, from: data))
        } catch {
            return .failure(ProfileDocumentError(message: "Invalid profile document: " + describe(error)))
        }
    }

    /// The document an editor session saves back. It started from the full
    /// fetched document, so a top-level key the user deleted means "clear
    /// it": sent as an explicit null (which `merge` treats as a clear —
    /// absent would mean "unchanged", the partial-document rule). Keys only
    /// the editor added go as typed. (Objects are replaced whole by `merge`,
    /// so a key removed inside one is already gone.)
    static func editedDocument(fetched: [String: Any], edited: [String: Any]) -> [String: Any] {
        var out = edited
        for key in fetched.keys where edited[key] == nil {
            out[key] = NSNull()
        }
        return out
    }

    /// "folderPaths[2]: expected a string" — the path and the problem, from a
    /// DecodingError (the generic localizedDescription says neither).
    static func describe(_ error: Error) -> String {
        func path(_ ctx: DecodingError.Context, _ last: CodingKey? = nil) -> String {
            var keys = ctx.codingPath
            if let last { keys.append(last) }
            var out = ""
            for k in keys {
                if let i = k.intValue { out += "[\(i)]" } else { out += (out.isEmpty ? "" : ".") + k.stringValue }
            }
            return out.isEmpty ? "(document)" : out
        }
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "\(path(ctx, key)): required field is missing"
        case .typeMismatch(let type, let ctx):
            return "\(path(ctx)): expected \(typeName(type))"
        case .valueNotFound(let type, let ctx):
            return "\(path(ctx)): expected \(typeName(type)), found null"
        case .dataCorrupted(let ctx):
            let detail = ctx.debugDescription.isEmpty ? "invalid value" : ctx.debugDescription
            return "\(path(ctx)): \(detail)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func typeName(_ t: Any.Type) -> String {
        switch t {
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is Int.Type, is Double.Type, is UInt64.Type, is Int64.Type: return "a number"
        case is [Any].Type: return "an array"
        case is [String: Any].Type: return "an object"
        default: return "\(t)"
        }
    }
}

struct ProfileDocumentError: Error, Equatable {
    let message: String
}
