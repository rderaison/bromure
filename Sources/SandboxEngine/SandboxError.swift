import Foundation

/// Errors specific to the Bromure tool.
public enum SandboxError: LocalizedError {
    case unsupportedHardware
    case baseImageNotFound
    case corruptMetadata(String)
    case downloadFailed(String)
    case diskCreationFailed(String)
    case cloneFailed(String)
    case vmStartFailed(String)
    case networkFilterFailed
    case diskFull(availableMB: UInt64, path: String)
    case macPoolExhausted

    public var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "This Mac does not support macOS virtualization. Apple Silicon is required."
        case .baseImageNotFound:
            return "No base image found. Run 'bromure init' first to create one."
        case .corruptMetadata(let detail):
            return "Base image metadata is corrupt: \(detail)"
        case .downloadFailed(let detail):
            return "Failed to download macOS restore image: \(detail)"
        case .diskCreationFailed(let detail):
            return "Failed to create disk image: \(detail)"
        case .cloneFailed(let detail):
            return "Failed to create ephemeral disk clone: \(detail)"
        case .vmStartFailed(let detail):
            return "Failed to start virtual machine: \(detail)"
        case .networkFilterFailed:
            return "Failed to initialize networking. Please quit and reopen Bromure."
        case .diskFull(let availableMB, let path):
            return "Not enough disk space to create image at \(path) "
                + "(\(availableMB) MB available). Free up space and try again."
        case .macPoolExhausted:
            return "Too many browser sessions. Close some windows and try again."
        }
    }
}
