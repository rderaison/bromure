import SwiftUI
import SandboxEngine

/// Status of a transferred file's security scan.
enum ScanStatus: Equatable {
    case pending
    case scanning
    case clean
    case threat(String)
    case skipped

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .scanning: return "Scanning..."
        case .clean: return "Clean"
        case .threat(let name): return "Threat: \(name)"
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

    init(filename: String, size: Int, direction: TransferDirection, scanStatus: ScanStatus = .pending, localURL: URL? = nil) {
        self.filename = filename
        self.size = size
        self.direction = direction
        self.date = Date()
        self.scanStatus = scanStatus
        self.localURL = localURL
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
        .onDrop(of: [.fileURL], isTargeted: $model.isDragTargeted) { providers in
            handleDrop(providers)
        }
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
            Image(systemName: model.isDragTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 32))
                .foregroundStyle(model.isDragTargeted ? .blue : .secondary)
            Text("Drop files here to upload to VM")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Files downloaded in the VM will appear here automatically")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.isDragTargeted ? Color.blue.opacity(0.05) : .clear)
    }

    // MARK: - File list

    private var fileList: some View {
        List {
            ForEach(model.files) { file in
                fileRow(file)
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            if model.isDragTargeted {
                dropOverlay
            }
        }
    }

    private func fileRow(_ file: TransferredFile) -> some View {
        HStack(spacing: 8) {
            directionIcon(file.direction)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(formattedSize(file.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    scanBadge(file.scanStatus)
                }
            }

            Spacer()

            if file.direction == .guestToHost, let url = file.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.vertical, 2)
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
        case .skipped:
            EmptyView()
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6]))
            .background(Color.blue.opacity(0.05))
            .padding(8)
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let urlData = data as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    model.uploadFile(url: url)
                }
            }
        }
        return true
    }

    // MARK: - Formatting

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
    var isDragTargeted = false
    var isConnected = false

    private var bridge: FileTransferBridge?
    private let downloadDir: URL
    private var virusTotalClient: VirusTotalClient?

    init(virusTotalAPIKey: String? = nil) {
        self.downloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
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
        bridge = nil
        isConnected = false
    }

    /// Upload a file from the host to the guest VM.
    func uploadFile(url: URL) {
        guard let bridge else { return }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let file = TransferredFile(
            filename: url.lastPathComponent,
            size: size,
            direction: .hostToGuest,
            scanStatus: .skipped
        )
        files.insert(file, at: 0)

        bridge.sendFile(url: url)
    }

    /// Handle a file received from the guest VM.
    private func handleReceivedFile(filename: String, data: Data) {
        // Save to host Downloads directory
        let destURL = uniqueURL(for: filename, in: downloadDir)
        do {
            try data.write(to: destURL)
        } catch {
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                print("[FileDrawer] failed to save \(filename): \(error)")
            }
            return
        }

        let initialStatus: ScanStatus = virusTotalClient != nil ? .pending : .skipped
        let file = TransferredFile(
            filename: destURL.lastPathComponent,
            size: data.count,
            direction: .guestToHost,
            scanStatus: initialStatus,
            localURL: destURL
        )
        files.insert(file, at: 0)

        // Trigger VirusTotal scan if configured
        if let client = virusTotalClient {
            Task { @MainActor in
                file.scanStatus = .scanning
                do {
                    let result = try await client.scanFile(at: destURL)
                    switch result.status {
                    case .clean:
                        file.scanStatus = .clean
                    case .threat(let positives, let total):
                        file.scanStatus = .threat("\(positives)/\(total) engines")
                    default:
                        file.scanStatus = .pending
                    }
                } catch {
                    if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil {
                        print("[FileDrawer] VirusTotal scan failed: \(error)")
                    }
                    file.scanStatus = .skipped
                }
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
