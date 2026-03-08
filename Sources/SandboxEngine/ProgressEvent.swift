import Foundation

/// Structured progress events emitted during long-running operations.
public enum ProgressEvent {
    /// A status message (e.g. "Creating auxiliary storage...")
    case message(String)

    /// A step started — show a spinner until the next event.
    case stepStart(String)

    /// A step completed successfully.
    case stepDone(String)

    /// Download progress: bytes received / total bytes (total may be 0 if unknown).
    case download(bytesReceived: Int64, totalBytes: Int64)

    /// Installation progress: 0.0 to 1.0.
    case install(fraction: Double)
}
