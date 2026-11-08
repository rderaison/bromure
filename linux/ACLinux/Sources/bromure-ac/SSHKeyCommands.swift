import ACLinux
import ArgumentParser
import Foundation

/// `ssh-key`: a workspace's imported SSH keys (macOS: the editor's
/// Credentials pane; a server has none). Keys stay on the host: the
/// guest signs through its workspace's agent.
// @port-skip linux-only: the editor's imported-key actions as a CLI
struct SSHKey: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-key",
        abstract: "A workspace's imported SSH keys (they load at its next boot; the guest signs through the host).",
        subcommands: [Ls.self, Import.self, AddAgent.self, Approve.self, Rm.self], defaultSubcommand: Ls.self)

    // @port-skip linux-only: CLI plumbing
    static func path(_ workspace: String, _ rest: String = "") -> String {
        "/profiles/\(ControlClient.encodeSegment(workspace))/ssh-keys" + (rest.isEmpty ? "" : "/" + ControlClient.encodeSegment(rest))
    }

    // @port-skip linux-only: CLI plumbing
    static func show(_ j: JSONValue) {
        guard case .array(let keys)? = j["keys"], !keys.isEmpty else { print("no imported keys"); return }
        for k in keys {
            var tags: [String] = []
            if k["requireApproval"] == .bool(true) { tags.append("asks before use") }
            if k["hasPassphrase"] == .bool(true) { tags.append("passphrase in the vault") }
            if let s = k["hostAgentSocket"]?.stringValue { tags.append("host agent \(s.isEmpty ? "$SSH_AUTH_SOCK" : s)") }
            let pub = k["publicKey"]?.stringValue ?? ""
            print("\(k["id"]?.stringValue ?? "?")  \(k["label"]?.stringValue ?? "")  \(pub.split(separator: " ").first ?? "")"
                  + (tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"))
        }
    }

    struct Ls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a workspace's imported keys.")
        @Argument(help: "Workspace (id or name).") var workspace: String
        @Flag(help: "JSON output.") var json = false
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("GET", SSHKey.path(workspace))
            try check(r, "ssh-key ls")
            if json { print(r.json) } else { SSHKey.show(r.json) }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a private key file on this server (copied into the workspace's host-only agent dir).")
        @Argument(help: "Workspace (id or name).") var workspace: String
        @Argument(help: "The private key file.") var file: String
        @Option(help: "Display name (default: the file's name).") var label: String?
        @Flag(name: .customLong("passphrase-stdin"), help: "Read the key's passphrase from stdin (it's kept in the encrypted vault).")
        var passphraseStdin = false
        @Flag(help: "Ask before each signature with this key.") var approve = false
        // @port-skip linux-only: CLI
        func run() async throws {
            // Read here, as the calling user: a shared server's daemon can't
            // see this account's /home.
            let path = VM.Run.absoluteHostPath(file)
            guard let bytes = FileManager.default.contents(atPath: path) else { throw ValidationError("can't read \(path)") }
            var body: [String: JSONValue] = ["path": .string(path), "keyData": .string(bytes.base64EncodedString()),
                                             "requireApproval": .bool(approve)]
            for pub in [path + ".pub", (path as NSString).deletingPathExtension + ".pub"] {
                if let text = try? String(contentsOfFile: pub, encoding: .utf8) { body["publicKey"] = .string(text); break }
            }
            if let label { body["label"] = .string(label) }
            if passphraseStdin {
                let pass = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                if !pass.isEmpty { body["passphrase"] = .string(pass) }
            }
            let r = try client().request("POST", SSHKey.path(workspace), body: .object(body))
            try check(r, "ssh-key import")
            SSHKey.show(r.json)
        }
    }

    struct AddAgent: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-agent",
            abstract: "Add keys from a host ssh-agent (a hardware key's): nothing is copied, signing goes back to that agent.")
        @Argument(help: "Workspace (id or name).") var workspace: String
        @Option(help: "The agent's socket (default: the daemon's SSH_AUTH_SOCK).") var socket: String = ""
        @Option(name: .customLong("public-key"), help: "Only this key (its OpenSSH public key line); default: every key the agent holds.")
        var publicKey: String?
        @Flag(help: "List the agent's keys instead.") var list = false
        @Flag(help: "Ask before each signature with these keys.") var approve = false
        // @port-skip linux-only: CLI
        func run() async throws {
            if list {
                let r = try client().request("POST", SSHKey.path(workspace, "host-agent"), body: ["socket": .string(socket)])
                try check(r, "ssh-key add-agent --list")
                if case .array(let keys)? = r.json["keys"] { for k in keys { print(k["publicKey"]?.stringValue ?? "") } }
                return
            }
            var body: [String: JSONValue] = ["hostAgentSocket": .string(socket), "requireApproval": .bool(approve)]
            if let publicKey { body["publicKey"] = .string(publicKey) }
            let r = try client().request("POST", SSHKey.path(workspace), body: .object(body))
            try check(r, "ssh-key add-agent")
            SSHKey.show(r.json)
        }
    }

    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set whether a key asks before each signature (applies at once).")
        @Argument(help: "Workspace (id or name).") var workspace: String
        @Argument(help: "The key's id (ssh-key ls).") var key: String
        @Flag(inversion: .prefixedNo, help: "Ask before use.") var ask = true
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", SSHKey.path(workspace, key), body: ["requireApproval": .bool(ask)])
            try check(r, "ssh-key approve")
            SSHKey.show(r.json)
        }
    }

    struct Rm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an imported key (its file and vault passphrase go).")
        @Argument(help: "Workspace (id or name).") var workspace: String
        @Argument(help: "The key's id (ssh-key ls).") var key: String
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("DELETE", SSHKey.path(workspace, key))
            try check(r, "ssh-key rm")
            SSHKey.show(r.json)
        }
    }
}
