import Darwin
import Foundation

/// States as things to list, create, clone and remove
/// (BUILD_INSTRUCTIONS.md, "States"). The `state` CLI group is a thin shell over
/// this; nothing here needs the app running.
///
/// A state is a directory: the default one is `ACSupportDir.defaultStateURL`
/// ("work"), every other one a folder under `ACSupportDir.statesRoot`. Its
/// settings are a `UserDefaults` suite named after it (`ACDefaults`), so
/// cloning a state copies the suite and removing it drops the suite.
///
/// Copies are APFS clones (`copyfile(2)` with `COPYFILE_CLONE`, file by
/// file): instant, zero bytes until written, and a workspace disk cloned
/// from `base.img` keeps sharing its blocks with it in the copy.
enum StateStore {
    /// `<state>/state.json`.
    struct Metadata: Codable, Equatable {
        var name: String
        var createdAt: Date
        var createdBy: String?
        /// Full clone: the state it was cloned from.
        var clonedFrom: String?
        /// Assets-only clone: where the base image, caches and models came from.
        var assetsFrom: String?
        /// True when `clonedFrom` was running at the time (crash-consistent copy).
        var live: Bool?
    }

    /// One row of `state ls`.
    struct Entry {
        let name: String
        let url: URL
        let isDefault: Bool
        let metadata: Metadata?
        let instance: (locked: Bool, info: ACInstance.Info?)
        let settingsDomain: String
    }

    enum Failure: Error, CustomStringConvertible {
        case badName(String)
        case exists(String)
        case missing(String)
        case isDefault(String)
        case running(String, ACInstance.Info?)
        case io(String)

        var description: String {
            switch self {
            case .badName(let n): return "'\(n)' isn't a state name (one path component, not hidden)"
            case .exists(let n): return "state '\(n)' already exists"
            case .missing(let n): return "no state named '\(n)'"
            case .isDefault(let n): return "'\(n)' is the default state (the one with no --state): it can't be removed"
            case .running(let n, let info):
                if let info { return "state '\(n)' is running (pid \(info.pid), build \(info.build))" }
                return "state '\(n)' is running"
            case .io(let s): return s
            }
        }
    }

    static let metadataFileName = "state.json"

    /// Entries this process never copies from one state to another: the
    /// instance's own (socket, lock, record) and the per-launch log dir.
    static let neverCloned: Set<String> = [
        "control.sock", ACInstance.lockFileName, ACInstance.infoFileName,
        "claude-subscription.enc.lock", "claude-subscription.enc.refresh-lock",
    ]

    /// What `--assets-from` clones: the base and stock images with their
    /// stamps, the firmware variables, the image caches and catalogs, the
    /// provisioner kernel/initrd, the browser image and the local models.
    /// Everything a fresh state would otherwise download or bake again;
    /// nothing a user made.
    static let assetNames: [String] = [
        "base.img", "base.version", "stock.img", "stock-state.json", "image-state.json",
        "efivars.bin", "catalog.json", "img-catalog.json", "browser-img-catalog.json",
        "provisioner-vmlinuz", "provisioner-initrd", "provisioner-initrd-shimmed",
        "browser", "Models", "models",
    ]
    /// Download caches: `ubuntu-<version>/`.
    static func isAssetCacheDir(_ name: String) -> Bool { name.hasPrefix("ubuntu-") }

    // MARK: Listing

    /// Every state: the default one first, then the named ones, sorted.
    static func list() -> [Entry] {
        var entries = [entry(name: ACSupportDir.defaultStateName, url: ACSupportDir.defaultStateURL, isDefault: true)]
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: ACSupportDir.statesRoot.path) {
            for n in names.sorted() where !n.hasPrefix(".") {
                let url = ACSupportDir.statesRoot.appendingPathComponent(n, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                entries.append(entry(name: n, url: url, isDefault: false))
            }
        }
        return entries
    }

    static func entry(name: String, url: URL, isDefault: Bool) -> Entry {
        Entry(name: name, url: url, isDefault: isDefault,
              metadata: readMetadata(url),
              instance: ACInstance.running(stateURL: url),
              settingsDomain: ACDefaults.suiteName(forState: name) ?? ACDefaults.bundleDomain)
    }

    /// Resolve a name to an existing state.
    static func existing(_ raw: String) throws -> Entry {
        guard let name = ACSupportDir.validStateName(raw), let url = ACSupportDir.stateURL(named: name) else {
            throw Failure.badName(raw)
        }
        let isDefault = url.standardizedFileURL == ACSupportDir.defaultStateURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing(raw) }
        return entry(name: isDefault ? ACSupportDir.defaultStateName : name, url: url, isDefault: isDefault)
    }

    /// Apparent and allocated bytes of a tree. Allocated counts every file's
    /// blocks as its own: clones that share blocks are counted twice, so the
    /// sum over states can exceed the disk.
    static func sizes(of url: URL) -> (apparent: Int64, allocated: Int64) {
        var apparent: Int64 = 0, allocated: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsPackageDescendants]) else { return (0, 0) }
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            apparent += Int64(v.fileSize ?? 0)
            allocated += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return (apparent, allocated)
    }

    // MARK: Metadata

    static func readMetadata(_ stateURL: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: stateURL.appendingPathComponent(metadataFileName)) else { return nil }
        return try? decoder.decode(Metadata.self, from: data)
    }

    static func writeMetadata(_ m: Metadata, to stateURL: URL) throws {
        let data = try encoder.encode(m)
        try data.write(to: stateURL.appendingPathComponent(metadataFileName), options: .atomic)
    }

    // MARK: Create / clone / remove

    /// A new, empty state: its directory and `state.json`. With `assetsFrom`,
    /// the source's assets (`assetNames`, download caches) are cloned in.
    @discardableResult
    static func create(named raw: String, assetsFrom: Entry? = nil, createdBy: String? = nil) throws -> Entry {
        let (name, url) = try newStateURL(raw)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            if let src = assetsFrom {
                for n in (try? fm.contentsOfDirectory(atPath: src.url.path)) ?? [] {
                    guard assetNames.contains(n) || isAssetCacheDir(n) else { continue }
                    try cloneTree(from: src.url.appendingPathComponent(n), to: url.appendingPathComponent(n),
                                  relative: n, excluding: { _ in false })
                }
            }
            try writeMetadata(Metadata(name: name, createdAt: Date(), createdBy: createdBy,
                                       assetsFrom: assetsFrom?.name), to: url)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return entry(name: name, url: url, isDefault: false)
    }

    /// A full clone of `source`: every file (minus `neverCloned`), as APFS
    /// clones, plus a copy of its settings suite. Refused while the source
    /// runs unless `live` (crash-consistent, like a power cut; the saved RAM
    /// images `profiles/*/vm.state` are left out of the copy, so its
    /// workspaces cold-boot from their disks).
    @discardableResult
    static func clone(_ source: Entry, as raw: String, live: Bool = false, createdBy: String? = nil) throws -> Entry {
        let (name, url) = try newStateURL(raw)
        if source.instance.locked, !live { throw Failure.running(source.name, source.instance.info) }
        let fm = FileManager.default
        do {
            try cloneTree(from: source.url, to: url, relative: "", excluding: { rel in
                if neverCloned.contains(rel) || rel == metadataFileName || rel == "logs" { return true }
                if live, rel.hasPrefix("profiles/"), rel.hasSuffix("/vm.state") { return true }
                return false
            })
            copySettings(from: source.settingsDomain, to: ACDefaults.suiteName(forState: name) ?? ACDefaults.bundleDomain)
            try writeMetadata(Metadata(name: name, createdAt: Date(), createdBy: createdBy,
                                       clonedFrom: source.name, live: source.instance.locked ? true : nil), to: url)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return entry(name: name, url: url, isDefault: false)
    }

    /// Remove a state and its settings suite. Never the default state, never
    /// a running one. Never touches the keychain: a clone's workspaces share
    /// their keys (LUKS, secrets) with the original's.
    static func remove(_ state: Entry) throws {
        if state.isDefault { throw Failure.isDefault(state.name) }
        if state.instance.locked { throw Failure.running(state.name, state.instance.info) }
        try FileManager.default.removeItem(at: state.url)
        if let suite = ACDefaults.suiteName(forState: state.name) { removeSettingsDomain(suite) }
    }

    /// Drop a settings domain for good. `removePersistentDomain` empties it
    /// but leaves a 42-byte empty plist under ~/Library/Preferences, which
    /// cfprefsd no longer counts as a domain (`defaults delete` says "not
    /// found"), so the file itself goes too.
    static func removeSettingsDomain(_ domain: String) {
        UserDefaults.standard.removePersistentDomain(forName: domain)
        CFPreferencesAppSynchronize(domain as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
        if let d = UserDefaults.standard.persistentDomain(forName: domain), !d.isEmpty { return }
        // cfprefsd writes the empty file lazily, sometimes after the first
        // removal: a second pass a moment later catches it. Best effort; an
        // empty plist left behind is not a domain.
        try? FileManager.default.removeItem(at: plist)
        Thread.sleep(forTimeInterval: 0.3)
        try? FileManager.default.removeItem(at: plist)
    }

    private static func newStateURL(_ raw: String) throws -> (String, URL) {
        guard let name = ACSupportDir.validStateName(raw),
              name != ACSupportDir.defaultStateName, name != ACSupportDir.name,
              let url = ACSupportDir.stateURL(named: name) else { throw Failure.badName(raw) }
        if FileManager.default.fileExists(atPath: url.path) { throw Failure.exists(name) }
        try FileManager.default.createDirectory(at: ACSupportDir.statesRoot, withIntermediateDirectories: true)
        return (name, url)
    }

    // MARK: Settings

    /// Copy one settings domain over another (`defaults export` + `import`).
    static func copySettings(from source: String, to destination: String) {
        guard source != destination else { return }
        let d = UserDefaults.standard
        let values = d.persistentDomain(forName: source) ?? [:]
        d.removePersistentDomain(forName: destination)
        if !values.isEmpty { d.setPersistentDomain(values, forName: destination) }
    }

    // MARK: Clone helper

    /// Clone `src` to `dst`, file by file. Directories are recreated (so
    /// entries can be excluded underneath), everything else goes through
    /// `copyfile(COPYFILE_CLONE)`: an APFS clone on the same volume, a copy
    /// elsewhere. Sockets are skipped. `excluding` sees paths relative to the
    /// tree's root ("profiles/<id>/vm.state").
    static func cloneTree(from src: URL, to dst: URL, relative: String,
                          excluding: (String) -> Bool) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: src.path)
        guard let type = attrs[.type] as? FileAttributeType else { return }
        switch type {
        case .typeDirectory:
            try fm.createDirectory(at: dst, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: attrs[.posixPermissions] ?? 0o755])
            for n in try fm.contentsOfDirectory(atPath: src.path) {
                let rel = relative.isEmpty ? n : "\(relative)/\(n)"
                if excluding(rel) { continue }
                try cloneTree(from: src.appendingPathComponent(n), to: dst.appendingPathComponent(n),
                              relative: rel, excluding: excluding)
            }
        case .typeSocket:
            return
        case .typeSymbolicLink:
            // Recreated, not cloned: a link stays a link, pointing where it did.
            try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: src.path))
        default:
            let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
            if copyfile(src.path, dst.path, nil, flags) != 0 {
                throw Failure.io("couldn't clone \(relative): \(String(cString: strerror(errno)))")
            }
        }
    }

    static func human(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
