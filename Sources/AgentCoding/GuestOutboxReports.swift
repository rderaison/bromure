import Foundation

// MARK: - docker `--format '{{json .}}'` line shapes

/// One line of `docker ps -a --format '{{json .}}'`. Field names match docker's
/// JSON keys exactly. `State` is absent on very old docker, so it's optional and
/// we fall back to the `Status` text.
fileprivate struct DockerPSJSON: Decodable {
    let ID: String
    let Names: String
    let Image: String
    let Status: String
    let Ports: String?
    let RunningFor: String?
    let Mounts: String?
    private let StateRaw: String?
    var State: String { StateRaw ?? (Status.hasPrefix("Up") ? "running" : "exited") }
    enum CodingKeys: String, CodingKey { case ID, Names, Image, Status, Ports, RunningFor, Mounts, StateRaw = "State" }
}

fileprivate struct DockerStatsJSON: Decodable {
    let ID: String
    let CPUPerc: String?
    let MemUsage: String?
}

fileprivate struct DockerImageJSON: Decodable {
    let ID: String
    let Repository: String
    let Tag: String
    let Size: String?
    let CreatedSince: String?
}

/// One line of the guest's docker-volumes.txt — `docker volume inspect` fields
/// plus the Size the agent merges in from its `docker system df -v` probe.
fileprivate struct DockerVolumeJSON: Decodable {
    let Name: String
    let Driver: String?
    let Mountpoint: String?
    let CreatedAt: String?
    let Size: String?
}

/// What the guest's outbox reports, as the host reads it (macOS:
/// UbuntuSandboxVM's outbox poll; the Linux daemon's /vms entries): the
/// listening ports and the docker loops' files, each a raw file in, the
/// session models out.
enum GuestOutboxReports {
    /// Parse `ss -tuln` output (one socket per line: netid, state, queues,
    /// local, peer, and — under sudo `-p` — the users:(("name",pid,fd))
    /// process column) into listening ports. Header-tolerant and
    /// column-count-tolerant so the same parser serves the guest's ports loop
    /// and the CLI's on-demand query. De-dupes identical entries.
    static func listeningPorts(_ raw: String) -> [ListeningPort] {
        var out: [ListeningPort] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5 else { continue }
            let proto = String(f[0])
            guard proto == "tcp" || proto == "udp" else { continue }   // skips headers
            guard let (addr, port) = splitLocalAddress(f[4]) else { continue }
            // Distinct process names from the users:(…) column, when present —
            // e.g. users:(("nginx",pid=91,fd=6),("nginx",pid=92,fd=6)) → nginx.
            var names: [String] = []
            if let usersRange = line.range(of: "users:") {
                var rest = line[usersRange.upperBound...]
                while let open = rest.firstIndex(of: "\"") {
                    let after = rest.index(after: open)
                    guard let close = rest[after...].firstIndex(of: "\"") else { break }
                    let name = String(rest[after..<close])
                    if !names.contains(name) { names.append(name) }
                    rest = rest[rest.index(after: close)...]
                }
            }
            let p = ListeningPort(proto: proto, addr: addr, port: port,
                                  process: names.joined(separator: ", "))
            if !out.contains(p) { out.append(p) }
        }
        return out.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    /// "0.0.0.0:22" / "[::]:80" / "127.0.0.53%lo:53" / "*:8080" → (addr, port).
    /// Strips the %scope/iface suffix; normalizes `*` to 0.0.0.0.
    static func splitLocalAddress(_ s: Substring) -> (addr: String, port: Int)? {
        guard let colon = s.lastIndex(of: ":"),
              let port = Int(s[s.index(after: colon)...]) else { return nil }
        var addr = String(s[..<colon])
            .replacingOccurrences(of: #"%[^\]]*"#, with: "", options: .regularExpression)
        if addr == "*" { addr = "0.0.0.0" }
        return (addr, port)
    }

    /// docker.txt: `docker ps -a --format '{{json .}}'`, one JSON object per
    /// line (running and stopped).
    static func dockerContainers(_ raw: String) -> [DockerContainer] {
        var containers: [DockerContainer] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let ps = try? JSONDecoder().decode(DockerPSJSON.self, from: data)
            else { continue }
            containers.append(DockerContainer(
                id: ps.ID, name: ps.Names, image: ps.Image,
                status: ps.Status, state: ps.State.lowercased(),
                ports: ps.Ports ?? "", runningFor: ps.RunningFor ?? "",
                mounts: ps.Mounts ?? ""))
        }
        return containers
    }

    /// docker-stats.txt: `docker stats --no-stream` NDJSON.
    static func dockerStats(_ raw: String) -> [(id: String, cpu: String, mem: String)] {
        var stats: [(id: String, cpu: String, mem: String)] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let s = try? JSONDecoder().decode(DockerStatsJSON.self, from: data)
            else { continue }
            stats.append((id: s.ID, cpu: s.CPUPerc ?? "", mem: s.MemUsage ?? ""))
        }
        return stats
    }

    /// docker-images.txt: `docker images` NDJSON.
    static func dockerImages(_ raw: String) -> [DockerImage] {
        var images: [DockerImage] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let im = try? JSONDecoder().decode(DockerImageJSON.self, from: data)
            else { continue }
            images.append(DockerImage(
                id: im.ID, repository: im.Repository, tag: im.Tag,
                size: im.Size ?? "", created: im.CreatedSince ?? ""))
        }
        return images
    }

    /// docker-volumes.txt: `docker volume inspect` NDJSON (+ merged Size).
    static func dockerVolumes(_ raw: String) -> [DockerVolume] {
        var volumes: [DockerVolume] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let vol = try? JSONDecoder().decode(DockerVolumeJSON.self, from: data)
            else { continue }
            volumes.append(DockerVolume(
                name: vol.Name, driver: vol.Driver ?? "",
                mountpoint: vol.Mountpoint ?? "",
                createdAt: vol.CreatedAt ?? "", size: vol.Size ?? ""))
        }
        return volumes
    }

    /// docker-binfmt.txt: space-separated qemu arch suffixes emulated.
    static func dockerBinfmt(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
    }

    /// docker-arch.txt: "id<TAB>arch" per running container.
    static func dockerArch(_ raw: String) -> [(id: String, arch: String)] {
        var out: [(id: String, arch: String)] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 2 else { continue }
            out.append((id: String(cols[0]).trimmingCharacters(in: .whitespaces),
                        arch: String(cols[1]).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}
