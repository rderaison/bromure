import Foundation
import Security

/// Manages LUKS-encrypted persistent disk images for browser profiles.
///
/// Each persistent profile gets a raw disk image that is LUKS-encrypted inside the VM.
/// The encryption key is a random 32-byte hex string stored in the macOS Keychain,
/// keyed by the profile's UUID. The actual LUKS formatting and unlocking happens
/// inside the guest VM via serial console commands.
public final class ProfileDisk {
    /// Keychain service name for profile disk encryption keys.
    private static let keychainService = "com.bromure.profile-key"

    /// Default disk size for new profile disks.
    public static let defaultSizeGB = 1

    // MARK: - Disk Management

    /// Create a raw disk image for a profile's persistent storage.
    ///
    /// The disk is created as a sparse file at the URL provided by
    /// `ProfileManager.profileDiskURL(for:)`. LUKS formatting must be
    /// performed inside the VM on first use.
    public static func createDisk(profileID: UUID, at url: URL, sizeGB: Int = defaultSizeGB) throws {
        let fm = FileManager.default
        let parentDir = url.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Remove any existing disk
        try? fm.removeItem(at: url)

        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw SandboxError.diskCreationFailed(
                "Failed to create profile disk: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(fd) }

        let size = Int64(sizeGB) * 1024 * 1024 * 1024
        guard ftruncate(fd, size) == 0 else {
            throw SandboxError.diskCreationFailed(
                "Failed to set profile disk size: \(String(cString: strerror(errno)))"
            )
        }

        // Ensure a Keychain entry exists for this profile
        _ = try keyForProfile(id: profileID)
    }

    /// Delete a profile's disk image and its Keychain entry.
    public static func deleteDisk(profileID: UUID, at url: URL) {
        try? FileManager.default.removeItem(at: url)
        deleteKey(for: profileID)
    }

    /// Whether a profile disk image exists at the given URL.
    public static func diskExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Keychain

    /// Retrieve or generate the LUKS encryption key for a profile.
    ///
    /// On first call for a given profile, generates a random 32-byte hex key
    /// and stores it in the macOS Keychain. Subsequent calls return the stored key.
    public static func keyForProfile(id: UUID) throws -> String {
        // Try to read existing key
        if let existing = readKey(for: id) {
            return existing
        }

        // Generate a new random key (32 bytes = 64 hex chars)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SandboxError.diskCreationFailed("Failed to generate random key (SecRandomCopyBytes: \(status))")
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()

        // Store in Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SandboxError.diskCreationFailed("Failed to store key in Keychain (status: \(addStatus))")
        }

        return key
    }

    // MARK: - Serial Commands

    /// Shell command to LUKS-format a new disk inside the VM.
    ///
    /// This should only be run once when the profile disk is first created.
    /// The disk appears as `/dev/vdb` in the guest.
    public static func luksFormatCommand(key: String) -> String {
        "echo -n '\(key)' | cryptsetup luksFormat --batch-mode /dev/vdb -"
    }

    /// Shell command to unlock and mount a LUKS-encrypted profile disk.
    ///
    /// Opens the LUKS volume, creates the filesystem if needed, and mounts
    /// it at the given mount point.
    public static func luksUnlockAndMountCommand(key: String, mountPoint: String) -> String {
        let open = "echo -n '\(key)' | cryptsetup open /dev/vdb profile_data -"
        let mkdirMount = "mkdir -p \(mountPoint)"
        // If the mapper device has no filesystem yet, create one
        let mkfs = "blkid /dev/mapper/profile_data >/dev/null 2>&1 || mkfs.ext4 -q /dev/mapper/profile_data"
        let mount = "mount /dev/mapper/profile_data \(mountPoint)"
        let chown = "chown chrome:chrome \(mountPoint)"
        return [open, mkdirMount, mkfs, mount, chown].joined(separator: " && ")
    }

    /// Shell command to cleanly unmount and close the LUKS volume before VM shutdown.
    public static func luksCloseCommand() -> String {
        "umount /home/chrome/profile 2>/dev/null; cryptsetup close profile_data 2>/dev/null"
    }

    // MARK: - Private

    private static func readKey(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKey(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
