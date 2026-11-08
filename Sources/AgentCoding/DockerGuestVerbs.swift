import Foundation

// The Docker dashboard's guest verbs, host side: the validation and the
// outbox command lines the local dashboard and the fat-client
// `POST /vms/{id}/docker` route send (agentd runs them in the guest).
enum DockerGuestVerbs {
    /// Conservative charset for ids/names interpolated into a guest shell line.
    static let idAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.:@")

    static func sanitizedID(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy(Self.idAllowed.contains) else { return nil }
        return t
    }

    /// docker's volume-name rule: [a-zA-Z0-9][a-zA-Z0-9_.-]* — stricter than
    /// `idAllowed` because create takes a user-typed name.
    static let volumeNameFirst = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    static let volumeNameRest = volumeNameFirst.union(.init(charactersIn: "_.-"))

    static func sanitizedVolumeName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.unicodeScalars.first, Self.volumeNameFirst.contains(first),
              t.unicodeScalars.allSatisfy(Self.volumeNameRest.contains)
        else { return nil }
        return t
    }

    /// User-supplied fields for the "new container" dialog.
    struct RunSpec {
        var image: String
        var name: String = ""
        var ports: [String] = []     // "8080:80"
        var env: [String] = []       // "KEY=val"
        var volumes: [String] = []   // "/host:/container"
        /// Pass the workspace's whole environment (API tokens, etc.) through.
        var inheritEnv: Bool = false
        /// Pass just the HTTP(S) proxy vars (covered by inheritEnv when set).
        var inheritProxy: Bool = false
        /// Run with a TTY (-it) in a fresh tmux tab instead of detached (-d).
        var interactive: Bool = false
    }

    /// Assemble the `docker-run …` outbox verb for a run spec (shared by the
    /// local dashboard and the fat-client `/vms/{id}/docker` route). nil when
    /// the image is missing.
    static func runVerb(spec: RunSpec) -> String? {
        let image = spec.image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { return nil }
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var cmd = spec.interactive ? "docker run -it" : "docker run -d"
        // For interactive runs we need a known container name so the guest can
        // tag the tmux tab and the sidebar can nest it under its container —
        // generate one when the user didn't supply it.
        var name = spec.name.trimmingCharacters(in: .whitespaces)
        if spec.interactive && name.isEmpty {
            name = "bromure-" + UUID().uuidString.prefix(6).lowercased()
        }
        if !name.isEmpty {
            cmd += " --name \(q(name))"
        }
        for p in spec.ports where !p.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -p \(q(p.trimmingCharacters(in: .whitespaces)))"
        }
        for e in spec.env where !e.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -e \(q(e.trimmingCharacters(in: .whitespaces)))"
        }
        for v in spec.volumes where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            cmd += " -v \(q(v.trimmingCharacters(in: .whitespaces)))"
        }
        cmd += " \(q(image))"
        cmd = cmd.replacingOccurrences(of: "\n", with: " ")
        // The guest builds the --env-file by sourcing ONLY the host-injected env
        // files on the metadata share (tokens from api_key.env, proxy from
        // proxy.env) — not the whole shell environment — then runs this command
        // backgrounded so it can't wedge the command loop.
        let mode = spec.inheritEnv
            ? (spec.inheritProxy ? "both" : "env")
            : (spec.inheritProxy ? "proxy" : "none")
        // <mode> <interactive 0|1> <tag> <image> <command>. <tag> is the
        // container name interactive tabs nest under ("-" otherwise); <image> is
        // the bare ref the guest pre-pulls (with progress) for detached runs.
        let tag = (spec.interactive && !name.isEmpty) ? name : "-"
        return "docker-run \(mode) \(spec.interactive ? "1" : "0") \(tag) \(image) \(cmd)"
    }

    /// What a fat-client `POST /vms/{id}/docker` body asks for, validated
    /// host-side exactly like the local dashboard's request* methods.
    enum AutomationAction: Equatable {
        /// An outbox command line for agentd.
        case send(String)
        /// The dashboard's expensive polling on or off (the `.docker-watch` marker).
        case watch(Bool)
        case refused(String)
    }

    static func automationAction(_ doc: [String: Any]) -> AutomationAction {
        let action = (doc["action"] as? String) ?? ""
        switch action {
        case "start", "stop", "remove", "logs":
            guard let cid = sanitizedID(doc["container"] as? String ?? "") else {
                return .refused("bad container id")
            }
            return .send("docker-\(action) \(cid)")
        case "attach":
            guard let cid = sanitizedID(doc["container"] as? String ?? "") else {
                return .refused("bad container id")
            }
            let allowed = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
            let shell = (doc["shell"] as? String ?? "sh").trimmingCharacters(in: .whitespaces)
            let safe = !shell.isEmpty && shell.unicodeScalars.allSatisfy(allowed.contains) ? shell : "sh"
            return .send("docker-attach \(cid) \(safe)")
        case "binfmt":
            return .send("docker-binfmt")
        case "binfmt-off":
            return .send("docker-binfmt-off")
        case "volume-create", "volume-remove":
            guard let name = Self.sanitizedVolumeName(doc["volume"] as? String ?? "") else {
                return .refused("bad volume name")
            }
            return .send("docker-\(action) \(name)")
        case "run":
            var spec = RunSpec(image: doc["image"] as? String ?? "")
            spec.name = doc["name"] as? String ?? ""
            spec.ports = doc["ports"] as? [String] ?? []
            spec.env = doc["env"] as? [String] ?? []
            spec.volumes = doc["volumes"] as? [String] ?? []
            spec.inheritEnv = doc["inheritEnv"] as? Bool ?? false
            spec.inheritProxy = doc["inheritProxy"] as? Bool ?? false
            spec.interactive = doc["interactive"] as? Bool ?? false
            guard let verb = runVerb(spec: spec) else {
                return .refused("missing image")
            }
            return .send(verb)
        case "watch":
            return .watch((doc["on"] as? Bool) ?? false)
        default:
            return .refused("unknown docker action: \(action)")
        }
    }
}
