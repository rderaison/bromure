import Foundation

/// Manages named browser profiles with JSON persistence.
public final class ProfileManager {
    private let storageDir: URL
    private var profiles: [Profile] = []

    /// Directory containing profile data.
    public static let profilesDirName = "profiles"

    public init(storageDir: URL? = nil) {
        let base = storageDir ?? VMConfig.defaultStorageDirectory
        self.storageDir = base.appendingPathComponent(Self.profilesDirName)
        try? FileManager.default.createDirectory(at: self.storageDir, withIntermediateDirectories: true)
        loadAll()
    }

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
    public func createProfile(name: String, color: ProfileColor? = .blue, settings: ProfileSettings = ProfileSettings()) -> Profile {
        let profile = Profile(name: name, color: color, settings: settings)
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
        let dir = profileDir(for: id)
        try? FileManager.default.removeItem(at: dir)
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
        settings.homePage = defaults.string(forKey: "vm.homePage") ?? "https://www.google.com"
        settings.enableGPU = defaults.object(forKey: "vm.enableGPU") as? Bool ?? true
        settings.enableWebGL = defaults.object(forKey: "vm.enableWebGL") as? Bool ?? false
        settings.enableAdBlocking = defaults.object(forKey: "vm.enableAdBlocking") as? Bool ?? false
        settings.enableWarp = defaults.object(forKey: "vm.enableWarp") as? Bool ?? false
        settings.enableClipboardSharing = defaults.object(forKey: "vm.enableClipboardSharing") as? Bool ?? false
        settings.blockMalwareSites = defaults.object(forKey: "vm.blockMalwareSites") as? Bool ?? false
        settings.phishingWarning = defaults.object(forKey: "vm.phishingWarning") as? Bool ?? false
        if defaults.object(forKey: "vm.enableFileTransfer") as? Bool ?? false {
            settings.canUpload = true
            settings.canDownload = true
        }

        let profile = createProfile(name: "Default", color: nil, settings: settings)
        defaults.set(true, forKey: "vm.profilesMigrated")
        return profile
    }

    /// URL for the directory containing the profile's disk image.
    /// This directory is shared with the guest VM via virtio-fs.
    public func profileImageDir(for id: UUID) -> URL {
        profileDir(for: id).appendingPathComponent("image")
    }

    /// URL for a profile's persistent disk image.
    public func profileDiskURL(for id: UUID) -> URL {
        profileImageDir(for: id).appendingPathComponent("profile.img")
    }

    // MARK: - Private

    private func profileDir(for id: UUID) -> URL {
        storageDir.appendingPathComponent(id.uuidString)
    }

    private func profileMetadataURL(for id: UUID) -> URL {
        profileDir(for: id).appendingPathComponent("profile.json")
    }

    private func save(_ profile: Profile) {
        let dir = profileDir(for: profile.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(profile) {
            try? data.write(to: profileMetadataURL(for: profile.id))
        }
    }

    private func loadAll() {
        profiles = []
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: storageDir,
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
}
