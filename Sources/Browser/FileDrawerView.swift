import SwiftUI
import SandboxEngine
import BrowserBridges

/// Status of a transferred file's security scan.
enum ScanStatus: Equatable {
    case pending
    case scanning
    case clean
    case threat(String)
    case error(String)
    case skipped

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .scanning: return "Scanning..."
        case .clean: return "Clean"
        case .threat(let name): return "Threat: \(name)"
        case .error(let reason): return "Scan failed: \(reason)"
        case .skipped: return "Skipped"
        }
    }
}

/// Direction of file transfer.
enum TransferDirection {
    case hostToGuest
    case guestToHost
}

/// A file that has been transferred or is in progress.
@Observable
final class TransferredFile: Identifiable {
    let id = UUID()
    let filename: String
    let size: Int
    let direction: TransferDirection
    let date: Date
    var scanStatus: ScanStatus
    var localURL: URL?
    /// Transfer progress: 0.0 to 1.0, or nil if transfer is complete / single-shot.
    var progress: Double?
    /// Whether this file has been explicitly saved to ~/Downloads by the user.
    var isSaved = false

    /// Whether the scan is still in progress (file should not be saved/dragged).
    var isScanInProgress: Bool {
        scanStatus == .pending || scanStatus == .scanning
    }

    /// Whether this file is blocked due to scan policy.
    var isBlocked = false

    init(filename: String, size: Int, direction: TransferDirection, scanStatus: ScanStatus = .pending, localURL: URL? = nil, progress: Double? = nil) {
        self.filename = filename
        self.size = size
        self.direction = direction
        self.date = Date()
        self.scanStatus = scanStatus
        self.localURL = localURL
        self.progress = progress
    }
}

/// SwiftUI view showing the file transfer drawer/panel.
///
/// Displays transferred files with drag-and-drop support for uploading
/// to the VM, and download buttons for files from the VM.
struct FileDrawerView: View {
    @Bindable var model: FileDrawerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.files.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(width: 280)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("File Transfer", systemImage: "doc.on.doc")
                .font(.headline)
            Spacer()
            if model.isConnected {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Downloads will appear here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Drag files out to save them to your Mac")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File list

    private var fileList: some View {
        List {
            ForEach(model.files) { file in
                fileRow(file)
            }
        }
        .listStyle(.plain)
    }

    private func fileRow(_ file: TransferredFile) -> some View {
        HStack(spacing: 8) {
            directionIcon(file.direction)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let progress = file.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }

                HStack(spacing: 6) {
                    Text(formattedSize(file.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if file.isBlocked {
                        Label(blockedReason(file.scanStatus), systemImage: "xmark.shield.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        scanBadge(file.scanStatus)
                    }
                }
            }

            Spacer()

            if file.direction == .guestToHost, file.localURL != nil, file.progress == nil, !file.isScanInProgress, !file.isBlocked {
                if file.isSaved {
                    Button {
                        if let url = file.localURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Saved — Show in Finder")
                } else {
                    Button {
                        model.saveFile(file)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Save to Downloads")
                }
            }
        }
        .padding(.vertical, 2)
        .onDrag {
            if let url = file.localURL, !file.isScanInProgress, !file.isBlocked {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        }
    }

    private func directionIcon(_ direction: TransferDirection) -> some View {
        Image(systemName: direction == .hostToGuest ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            .foregroundStyle(direction == .hostToGuest ? .blue : .green)
            .font(.body)
    }

    @ViewBuilder
    private func scanBadge(_ status: ScanStatus) -> some View {
        switch status {
        case .pending:
            Label("Pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .scanning:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .clean:
            Label("Clean", systemImage: "checkmark.shield.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .threat(let name):
            Label(name, systemImage: "exclamationmark.shield.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .error(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .skipped:
            EmptyView()
        }
    }

    // MARK: - Formatting

    private func blockedReason(_ status: ScanStatus) -> String {
        switch status {
        case .threat(let detail): return "Threat: \(detail)"
        case .error(let reason): return "Blocked: \(reason)"
        default: return "Blocked"
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - File Drawer Model

/// Observable model backing the file transfer drawer.
/// Manages the list of transferred files and communicates with FileTransferBridge.
@MainActor
@Observable
final class FileDrawerModel {
    var files: [TransferredFile] = []
    var isConnected = false

    /// Called when a file is received from the guest (for auto-opening the drawer).
    @ObservationIgnored nonisolated(unsafe) var onFileFromGuest: (() -> Void)?

    private var bridge: FileTransferBridge?
    /// Per-session temp directory for received files. Deleted on detach/teardown.
    let sessionDir: URL
    private let userDownloadsDir: URL
    private var virusTotalClient: VirusTotalClient?

    /// Whether to block files flagged as threats by VirusTotal.
    let blockThreats: Bool
    /// Whether to block files that could not be scanned by VirusTotal.
    let blockUnscannable: Bool

    init(virusTotalAPIKey: String? = nil, blockThreats: Bool = false, blockUnscannable: Bool = false) {
        let bromureTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure", isDirectory: true)
        // Clean up stale session dirs from previous crashes
        if FileManager.default.fileExists(atPath: bromureTmp.path) {
            try? FileManager.default.removeItem(at: bromureTmp)
        }
        let tmpBase = bromureTmp
            .appendingPathComponent("session-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        self.sessionDir = tmpBase
        self.userDownloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.blockThreats = blockThreats
        self.blockUnscannable = blockUnscannable
        if let key = virusTotalAPIKey, !key.isEmpty {
            self.virusTotalClient = try? VirusTotalClient(apiKey: key)
        }
    }

    /// Attach to a file transfer bridge (called when a VM session starts).
    func attach(bridge: FileTransferBridge) {
        self.bridge = bridge
        self.isConnected = bridge.isConnected

        bridge.onFileReceived = { [weak self] filename, data in
            self?.handleReceivedFile(filename: filename, data: data)
        }

        bridge.onTransferProgress = { [weak self] filename, received, total in
            guard let self else { return }
            // Find the in-progress file entry and update its progress
            if let existing = self.files.first(where: { $0.filename == filename && $0.progress != nil }) {
                existing.progress = total > 0 ? Double(received) / Double(total) : 0
            } else {
                // First chunk — insert a placeholder entry and open the drawer
                let file = TransferredFile(
                    filename: filename,
                    size: total,
                    direction: .guestToHost,
                    scanStatus: .pending,
                    progress: total > 0 ? Double(received) / Double(total) : 0
                )
                self.files.insert(file, at: 0)
                self.onFileFromGuest?()
            }
        }

        bridge.onFileListReceived = { [weak self] fileList in
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                print("[FileDrawer] file list from guest: \(fileList)")
            }
            _ = self
        }

        bridge.onConnectionChanged = { [weak self] connected in
            self?.isConnected = connected
        }
    }

    /// Detach from the bridge (called on session teardown).
    func detach() {
        bridge?.onFileReceived = nil
        bridge?.onFileListReceived = nil
        bridge?.onConnectionChanged = nil
        bridge?.onTransferProgress = nil
        bridge = nil
        isConnected = false
        // Delete the per-session temp directory and all unsaved files
        try? FileManager.default.removeItem(at: sessionDir)
    }

    /// Handle a file received from the guest VM.
    private func handleReceivedFile(filename: String, data: Data) {
        // Save to per-session temp directory (not ~/Downloads)
        let destURL = uniqueURL(for: filename, in: sessionDir)
        do {
            try data.write(to: destURL)
        } catch {
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                print("[FileDrawer] failed to save \(filename): \(error)")
            }
            return
        }

        let initialStatus: ScanStatus = virusTotalClient != nil ? .pending : .skipped

        // If there's an in-progress entry from chunked transfer, finalize it
        let transferredFile: TransferredFile
        if let existing = files.first(where: { $0.filename == filename && $0.progress != nil }) {
            existing.progress = nil
            existing.scanStatus = initialStatus
            existing.localURL = destURL
            transferredFile = existing
        } else {
            let newFile = TransferredFile(
                filename: destURL.lastPathComponent,
                size: data.count,
                direction: .guestToHost,
                scanStatus: initialStatus,
                localURL: destURL
            )
            files.insert(newFile, at: 0)
            transferredFile = newFile
        }
        onFileFromGuest?()

        // Trigger VirusTotal scan if configured
        if let client = virusTotalClient {
            Task { @MainActor in
                transferredFile.scanStatus = .scanning
                do {
                    let result = try await client.scanFile(at: destURL)
                    switch result.status {
                    case .clean:
                        transferredFile.scanStatus = .clean
                    case .threat(let positives, let total):
                        transferredFile.scanStatus = .threat("\(positives)/\(total) engines")
                        if blockThreats {
                            transferredFile.isBlocked = true
                            try? FileManager.default.removeItem(at: destURL)
                        }
                    default:
                        transferredFile.scanStatus = .pending
                    }
                } catch let vtError as VirusTotalError {
                    switch vtError {
                    case .fileTooLarge:
                        transferredFile.scanStatus = .error("Too large to scan")
                    case .rateLimited:
                        transferredFile.scanStatus = .error("Rate limited")
                    case .notFound:
                        transferredFile.scanStatus = .error("Unknown file")
                    default:
                        transferredFile.scanStatus = .error("Scan failed")
                    }
                    if blockUnscannable {
                        transferredFile.isBlocked = true
                        try? FileManager.default.removeItem(at: destURL)
                    }
                } catch {
                    transferredFile.scanStatus = .error("Scan failed")
                    if blockUnscannable {
                        transferredFile.isBlocked = true
                        try? FileManager.default.removeItem(at: destURL)
                    }
                }
            }
        }
    }

    /// Save a received file to ~/Downloads (user-initiated).
    func saveFile(_ file: TransferredFile) {
        guard let sourceURL = file.localURL, !file.isSaved, !file.isBlocked else { return }
        let destURL = uniqueURL(for: file.filename, in: userDownloadsDir)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            file.localURL = destURL
            file.isSaved = true
        } catch {
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                print("[FileDrawer] failed to save \(file.filename): \(error)")
            }
        }
    }

    /// Generate a unique file URL, appending (1), (2), etc. if the name is taken.
    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: url.path) else { return url }

        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        repeat {
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            url = directory.appendingPathComponent(newName)
            counter += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}
