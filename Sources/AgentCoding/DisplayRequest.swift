import Foundation

/// What an agent asked to show, read from its tool call.
enum DisplayRequest: Equatable {
    case media(path: String, title: String?, caption: String?)
    case chart(spec: String, title: String?, caption: String?)
    /// A file handed to the user to download (`send_file`).
    case file(path: String, note: String?)

    /// A display-MCP call, whatever the agent calls MCP tools
    /// (`mcp__display__show_chart`, `display__show_chart`, `display.show_chart`…).
    static func parse(name: String, detail: String) -> DisplayRequest? {
        let n = name.lowercased()
        let media = n.hasSuffix("show_media"), chart = n.hasSuffix("show_chart"), send = n.hasSuffix("send_file")
        guard media || chart || send,
              n.contains("display") || n == "show_media" || n == "show_chart" || n == "send_file",
              let d = detail.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        if send {
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            return .file(path: path, note: (input["note"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let title = (input["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let caption = (input["caption"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if media {
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            return .media(path: path, title: title, caption: caption)
        }
        // The spec may come as an object or as a JSON string.
        var spec: Any? = input["spec"]
        if let s = spec as? String, let d = s.data(using: .utf8) { spec = try? JSONSerialization.jsonObject(with: d) }
        guard let obj = spec as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return .chart(spec: text, title: title, caption: caption)
    }

    var title: String? {
        switch self {
        case .media(_, let t, _), .chart(_, let t, _): return t
        case .file(let path, _): return (path as NSString).lastPathComponent
        }
    }
    var caption: String? {
        switch self {
        case .media(_, _, let c), .chart(_, _, let c): return c
        case .file(_, let note): return note
        }
    }
}
