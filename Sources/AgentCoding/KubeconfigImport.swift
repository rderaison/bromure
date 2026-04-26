import Foundation
import Yams

/// Parses a kubectl kubeconfig YAML into one `KubeconfigEntry` per
/// context found. `current-context` is preserved by listing it first
/// in the returned array (mostly cosmetic — the editor shows them in
/// order).
public enum KubeconfigImport {
    public enum ImportError: LocalizedError {
        case yamlParseFailed(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .yamlParseFailed(let why): return "Couldn't parse the YAML: \(why)"
            case .malformed(let why):       return "Kubeconfig looks malformed: \(why)"
            }
        }
    }

    /// Parse `yamlText` and return one entry per context. Throws
    /// `ImportError` on parse failure or if the file isn't a kubeconfig.
    public static func parse(_ yamlText: String) throws -> [KubeconfigEntry] {
        let root: Any
        do {
            guard let decoded = try Yams.load(yaml: yamlText) else {
                throw ImportError.malformed("file is empty")
            }
            root = decoded
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.yamlParseFailed(error.localizedDescription)
        }
        guard let top = root as? [String: Any] else {
            throw ImportError.malformed("top level isn't a mapping")
        }

        let clustersByName  = indexNamedList(top["clusters"],  inner: "cluster")
        let usersByName     = indexNamedList(top["users"],     inner: "user")
        let contexts        = (top["contexts"] as? [Any]) ?? []
        let currentContext  = top["current-context"] as? String

        var entries: [KubeconfigEntry] = []
        for ctxAny in contexts {
            guard let ctxMap = ctxAny as? [String: Any],
                  let name   = ctxMap["name"] as? String,
                  let inner  = ctxMap["context"] as? [String: Any]
            else { continue }

            let clusterName = inner["cluster"] as? String ?? ""
            let userName    = inner["user"] as? String ?? ""
            let namespace   = inner["namespace"] as? String ?? ""
            let cluster     = clustersByName[clusterName] ?? [:]
            let user        = usersByName[userName] ?? [:]

            let server = cluster["server"] as? String ?? ""
            let caPEM  = decodeBase64Field(cluster["certificate-authority-data"])
                      ?? readFileField(cluster["certificate-authority"])
                      ?? ""

            let auth = parseAuth(user)

            entries.append(KubeconfigEntry(
                name: name,
                serverURL: server,
                caCertPEM: caPEM,
                namespace: namespace,
                auth: auth
            ))
        }

        if let current = currentContext,
           let idx = entries.firstIndex(where: { $0.name == current }), idx != 0 {
            let item = entries.remove(at: idx)
            entries.insert(item, at: 0)
        }

        return entries
    }

    // MARK: - helpers

    /// Turn `[{name: foo, <inner>: {...}}, ...]` into `[foo: {inner}]`.
    private static func indexNamedList(_ raw: Any?, inner: String) -> [String: [String: Any]] {
        guard let arr = raw as? [Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for item in arr {
            guard let map = item as? [String: Any],
                  let name = map["name"] as? String,
                  let body = map[inner] as? [String: Any]
            else { continue }
            out[name] = body
        }
        return out
    }

    private static func parseAuth(_ user: [String: Any]) -> KubeconfigEntry.Auth {
        if let token = user["token"] as? String, !token.isEmpty {
            return .bearerToken(token)
        }
        let certPEM = decodeBase64Field(user["client-certificate-data"])
                   ?? readFileField(user["client-certificate"])
        let keyPEM  = decodeBase64Field(user["client-key-data"])
                   ?? readFileField(user["client-key"])
        if let c = certPEM, let k = keyPEM, !c.isEmpty, !k.isEmpty {
            return .clientCert(certPEM: c, keyPEM: k)
        }
        if let exec = user["exec"] as? [String: Any],
           let cmd  = exec["command"] as? String, !cmd.isEmpty {
            let args = (exec["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .execPlugin(command: cmd, args: args, refreshSeconds: 600)
        }
        // Fall back to an empty bearer-token entry — user can fix it
        // in the row editor.
        return .bearerToken("")
    }

    /// Base64 fields hold the PEM bytes directly; we just decode and
    /// re-stringify as UTF-8.
    private static func decodeBase64Field(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty,
              let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
              let pem = String(data: data, encoding: .utf8)
        else { return nil }
        return pem
    }

    /// File-path fields point at on-disk PEMs (kubectl's default for
    /// `gcloud`/`aws`-managed contexts). Read them eagerly so we never
    /// rely on the host file system at session-launch time.
    private static func readFileField(_ raw: Any?) -> String? {
        guard let path = raw as? String, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return try? String(contentsOfFile: expanded, encoding: .utf8)
    }
}
