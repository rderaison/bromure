import Foundation

/// Manages named browser profiles with JSON persistence.
///
/// Profile metadata (JSON) is stored in iCloud Drive when available, so
/// profiles sync across Macs.  Disk images stay local in Application Support
/// since they're large and machine-specific.
///
/// Layout:
///   iCloud:  <ubiquity-container>/Documents/profiles/<UUID>/profile.json
///   Local:   ~/Library/Application Support/Bromure/profiles/<UUID>/image/profile.img
///   Fallback (no iCloud): metadata also goes in the local dir.
public final class ProfileManager {
    /// Local storage for disk images (always local).
    private let localDir: URL
    /// Where profile metadata lives — iCloud if available, local fallback.
    private var metadataBaseDir: URL
    private var profiles: [Profile] = []
    private var iCloudReady = false

    /// Called on the main thread once iCloud discovery completes and profiles are loaded.
    public var onReady: (() -> Void)?

    /// Directory containing profile data.
    public static let profilesDirName = "profiles"

    public init(storageDir: URL? = nil) {
        let base = storageDir ?? VMConfig.defaultStorageDirectory
        self.localDir = base.appendingPathComponent(Self.profilesDirName)
        self.metadataBaseDir = localDir  // temporary until iCloud check completes
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        // Discover iCloud container in the background.
        // url(forUbiquityContainerIdentifier:) can block indefinitely, so we
        // race it against a timeout and fall back to the well-known path.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var icloudDir: URL?

            // Try the official API with a timeout
            let semaphore = DispatchSemaphore(value: 0)
            var apiResult: URL?
            DispatchQueue.global(qos: .userInitiated).async {
                apiResult = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.io.bromure.app")
                semaphore.signal()
            }
            let timedOut = semaphore.wait(timeout: .now() + 5) == .timedOut

            if let icloudURL = apiResult {
                icloudDir = icloudURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent(Self.profilesDirName, isDirectory: true)
            } else {
                if timedOut {
                    print("[Profiles] iCloud API timed out, trying Mobile Documents fallback")
                }
                // Fall back to the well-known Mobile Documents path
                let home = FileManager.default.homeDirectoryForCurrentUser
                let containerDir = home.appendingPathComponent(
                    "Library/Mobile Documents/iCloud~io~bromure~app", isDirectory: true)
                if FileManager.default.fileExists(atPath: containerDir.path) {
                    icloudDir = containerDir
                        .appendingPathComponent("Documents", isDirectory: true)
                        .appendingPathComponent(Self.profilesDirName, isDirectory: true)
                }
            }

            if let dir = icloudDir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                DispatchQueue.main.async {
                    self.metadataBaseDir = dir
                    print("[Profiles] iCloud ready: \(dir.path)")
                    self.migrateLocalToCloud()
                    self.loadAll()
                    self.iCloudReady = true
                    self.onReady?()
                }
            } else {
                DispatchQueue.main.async {
                    print("[Profiles] iCloud unavailable, using local storage")
                    self.loadAll()
                    self.iCloudReady = true
                    self.onReady?()
                }
            }
        }
    }

    /// Whether iCloud discovery has completed (profiles are loaded).
    public var isReady: Bool { iCloudReady }

    // MARK: - Public API

    /// All profiles, sorted by last used (most recent first), then creation date.
    public var allProfiles: [Profile] {
        profiles.sorted { a, b in
            let aDate = a.lastUsedAt ?? a.createdAt
            let bDate = b.lastUsedAt ?? b.createdAt
            return aDate > bDate
        }
    }

    /// Get a profile by ID.
    public func profile(withID id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Create a new profile and save it.
    @discardableResult
    public func createProfile(name: String, comments: String = "", color: ProfileColor? = .blue, settings: ProfileSettings = ProfileSettings()) -> Profile {
        let profile = Profile(name: name, comments: comments, color: color, settings: settings)
        profiles.append(profile)
        save(profile)
        return profile
    }

    /// Update an existing profile.
    public func updateProfile(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save(profile)
        }
    }

    /// Delete a profile and its data.
    public func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        // Remove metadata
        let metaDir = metadataDir(for: id)
        try? FileManager.default.removeItem(at: metaDir)
        // Remove local disk image
        let diskDir = localProfileDir(for: id)
        try? FileManager.default.removeItem(at: diskDir)
    }

    /// Mark a profile as recently used.
    public func markUsed(id: UUID) {
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx].lastUsedAt = Date()
            save(profiles[idx])
        }
    }

    /// Migrate from legacy UserDefaults-based settings to a default profile.
    /// Returns the migrated profile, or nil if no legacy settings found.
    @discardableResult
    public func migrateFromUserDefaults() -> Profile? {
        let defaults = UserDefaults.standard
        // Check if migration already happened
        guard defaults.object(forKey: "vm.profilesMigrated") == nil else { return nil }
        // Only migrate if there are legacy settings
        guard defaults.object(forKey: "vm.enableAudio") != nil ||
              defaults.object(forKey: "vm.homePage") != nil else {
            defaults.set(true, forKey: "vm.profilesMigrated")
            return nil
        }

        var settings = ProfileSettings()
        settings.homePage = defaults.string(forKey: "vm.homePage") ?? "https://bromure.io/hello"
        settings.enableGPU = defaults.object(forKey: "vm.enableGPU") as? Bool ?? true
        settings.enableWebGL = defaults.object(forKey: "vm.enableWebGL") as? Bool ?? false
        settings.enableAdBlocking = defaults.object(forKey: "vm.enableAdBlocking") as? Bool ?? false
        if defaults.object(forKey: "vm.enableWarp") as? Bool ?? false {
            settings.vpnMode = .cloudflareWarp
        }
        settings.enableAudio = defaults.object(forKey: "vm.enableAudio") as? Bool ?? true
        settings.enableClipboardSharing = defaults.object(forKey: "vm.enableClipboardSharing") as? Bool ?? false
        settings.blockMalwareSites = defaults.object(forKey: "vm.blockMalwareSites") as? Bool ?? false
        settings.phishingWarning = defaults.object(forKey: "vm.phishingWarning") as? Bool ?? false
        if defaults.object(forKey: "vm.enableFileTransfer") as? Bool ?? false {
            settings.canUpload = true
            settings.canDownload = true
        }

        let profile = createProfile(name: "Private Browsing", color: nil, settings: settings)
        defaults.set(true, forKey: "vm.profilesMigrated")
        return profile
    }

    /// URL for the directory containing the profile's disk image.
    /// Always local — disk images don't sync to iCloud.
    public func profileImageDir(for id: UUID) -> URL {
        localProfileDir(for: id).appendingPathComponent("image")
    }

    /// URL for a profile's persistent disk image.
    public func profileDiskURL(for id: UUID) -> URL {
        profileImageDir(for: id).appendingPathComponent("profile.img")
    }

    /// Reload profiles from disk (e.g. after iCloud sync delivers changes).
    public func reload() {
        loadAll()
    }

    // MARK: - Private

    /// Local directory for a profile's disk images.
    private func localProfileDir(for id: UUID) -> URL {
        localDir.appendingPathComponent(id.uuidString)
    }

    /// Directory for profile metadata.
    private func metadataDir(for id: UUID) -> URL {
        metadataBaseDir.appendingPathComponent(id.uuidString)
    }

    private func profileMetadataURL(for id: UUID) -> URL {
        metadataDir(for: id).appendingPathComponent("profile.json")
    }

    private func save(_ profile: Profile) {
        let url = profileMetadataURL(for: profile.id)
        let dir = metadataDir(for: profile.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[Profiles] Failed to create directory \(dir.path): \(error)")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            print("[Profiles] Saved '\(profile.name)' to \(url.path)")
        } catch {
            print("[Profiles] Failed to save profile '\(profile.name)': \(error)")
        }
    }

    private func loadAll() {
        profiles = []
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: metadataBaseDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in contents where dir.hasDirectoryPath {
            let metaURL = dir.appendingPathComponent("profile.json")
            if let data = try? Data(contentsOf: metaURL),
               let profile = try? decoder.decode(Profile.self, from: data) {
                profiles.append(profile)
            }
        }
    }

    /// One-time migration: move existing local profile.json files to iCloud.
    private func migrateLocalToCloud() {
        // Only migrate if metadataBaseDir is different from localDir (i.e. iCloud)
        guard metadataBaseDir != localDir else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: localDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for dir in contents where dir.hasDirectoryPath {
            let localMeta = dir.appendingPathComponent("profile.json")
            guard fm.fileExists(atPath: localMeta.path) else { continue }

            let uuid = dir.lastPathComponent
            let cloudProfileDir = metadataBaseDir.appendingPathComponent(uuid)
            let cloudMeta = cloudProfileDir.appendingPathComponent("profile.json")

            // Don't overwrite if cloud already has this profile
            guard !fm.fileExists(atPath: cloudMeta.path) else {
                try? fm.removeItem(at: localMeta)
                continue
            }

            try? fm.createDirectory(at: cloudProfileDir, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: localMeta, to: cloudMeta)
                print("[Profiles] Migrated \(uuid) to iCloud")
            } catch {
                print("[Profiles] Failed to migrate \(uuid): \(error)")
            }
        }
    }
}
