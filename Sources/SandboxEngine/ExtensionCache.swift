import Foundation

public actor ExtensionCache {
    public static let shared = ExtensionCache()

    public static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    private var cacheDir: URL {
        VMConfig.defaultStorageDirectory.appendingPathComponent("extensions", isDirectory: true)
    }

    private func extensionDir(for extensionID: String) -> URL {
        cacheDir.appendingPathComponent(extensionID, isDirectory: true)
    }

    private func crxFile(for extensionID: String) -> URL {
        extensionDir(for: extensionID).appendingPathComponent("extension.crx")
    }

    public func download(extensionID: String) async throws -> URL {
        guard Self.isValidExtensionID(extensionID) else {
            throw ExtensionCacheError.invalidExtensionID
        }
        let dir = extensionDir(for: extensionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let urlString = "https://clients2.google.com/service/update2/crx"
            + "?response=redirect&prodversion=130.0&acceptformat=crx3"
            + "&x=id%3D\(extensionID)%26uc"
        guard let url = URL(string: urlString) else {
            throw ExtensionCacheError.invalidExtensionID
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ExtensionCacheError.downloadFailed
        }
        guard !data.isEmpty else {
            throw ExtensionCacheError.downloadFailed
        }

        let dest = crxFile(for: extensionID)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    public nonisolated func cachedPathSync(for extensionID: String) -> URL? {
        let path = VMConfig.defaultStorageDirectory
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(extensionID, isDirectory: true)
            .appendingPathComponent("extension.crx")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    public func cachedPath(for extensionID: String) -> URL? {
        let path = crxFile(for: extensionID)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    public func extractName(for extensionID: String) throws -> String? {
        guard let crxURL = cachedPath(for: extensionID) else { return nil }
        let crxData = try Data(contentsOf: crxURL)
        let zipData = try Self.extractZipFromCRX(crxData)
        return try Self.readNameFromManifest(zipData: zipData)
    }

    public func clearCache(for extensionID: String) throws {
        let dir = extensionDir(for: extensionID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - CRX parsing

    static func extractZipFromCRX(_ data: Data) throws -> Data {
        guard data.count > 16 else { throw ExtensionCacheError.invalidCRX }
        let magic = data[data.startIndex..<data.startIndex + 4]
        if magic == Data([0x43, 0x72, 0x32, 0x34]) {  // "Cr24"
            let headerLen = data.withUnsafeBytes { buf in
                buf.load(fromByteOffset: 8, as: UInt32.self).littleEndian
            }
            let zipStart = 12 + Int(headerLen)
            guard zipStart < data.count else { throw ExtensionCacheError.invalidCRX }
            return data[zipStart...]  as Data
        }
        return data
    }

    static func readNameFromManifest(zipData: Data) throws -> String? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipFile = tempDir.appendingPathComponent("ext.zip")
        try zipData.write(to: zipFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-j", "-q", zipFile.path, "manifest.json", "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else { return nil }
        return json["name"] as? String
    }
}

public enum ExtensionCacheError: Error, LocalizedError {
    case invalidExtensionID
    case downloadFailed
    case invalidCRX

    public var errorDescription: String? {
        switch self {
        case .invalidExtensionID: "Invalid extension ID"
        case .downloadFailed: "Failed to download extension"
        case .invalidCRX: "Invalid CRX file format"
        }
    }
}
