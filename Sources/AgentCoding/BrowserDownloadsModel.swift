import SwiftUI
import SandboxEngine

/// One file the workspace browser downloaded and saved to the host's ~/Downloads.
/// `progress` tracks the guest→host vsock transfer — the web download itself
/// already finished inside the guest before `file-agent.py` pushes the bytes.
@MainActor
@Observable
final class BrowserDownload: Identifiable {
    let id = UUID()
    let filename: String
    let date: Date
    var size: Int
    /// Where it landed on the host (nil until the bytes are written).
    var localURL: URL?
    /// 0…1 while the bytes stream from the guest; nil once saved.
    var progress: Double?

    init(filename: String, size: Int, progress: Double?) {
        self.filename = filename
        self.size = size
        self.date = Date()
        self.progress = progress
    }
}

/// Safari-style downloads for the workspace browser pane. A guest download is
/// streamed over the shared `FileTransferBridge` (vsock 5100) and written
/// straight to the host's ~/Downloads, then surfaced in a toolbar popover with a
/// "Show in Finder" affordance — the host analog of the in-guest download.
@MainActor
@Observable
final class BrowserDownloadsModel {
    /// Newest first.
    var items: [BrowserDownload] = []
    /// Drives the toolbar popover; flipped true when a download completes.
    var popoverShown = false

    @ObservationIgnored private weak var bridge: FileTransferBridge?
    private let downloadsDir: URL

    init() {
        downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Wire the file-transfer bridge's guest→host direction to this model.
    /// (Uploads use the same bridge's host→guest direction; they don't touch
    /// these callbacks.)
    func attach(bridge: FileTransferBridge) {
        self.bridge = bridge
        bridge.onTransferProgress = { [weak self] filename, received, total in
            self?.handleProgress(filename: filename, received: received, total: total)
        }
        bridge.onFileReceived = { [weak self] filename, data in
            self?.handleReceived(filename: filename, data: data)
        }
    }

    func detach() {
        bridge?.onTransferProgress = nil
        bridge?.onFileReceived = nil
        bridge = nil
    }

    func revealInFinder(_ item: BrowserDownload) {
        guard let url = item.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clear() {
        items.removeAll()
        popoverShown = false
    }

    // MARK: - Bridge callbacks

    private func handleProgress(filename: String, received: Int, total: Int) {
        let p = total > 0 ? Double(received) / Double(total) : 0
        if let inFlight = items.first(where: { $0.filename == filename && $0.progress != nil }) {
            inFlight.progress = p
        } else {
            items.insert(BrowserDownload(filename: filename, size: total, progress: p), at: 0)
        }
    }

    private func handleReceived(filename: String, data: Data) {
        let dest = uniqueURL(for: filename, in: downloadsDir)
        do {
            try data.write(to: dest)
        } catch {
            print("[browser] download save failed for \(filename): \(error)")
            // Drop the in-flight placeholder so a failed transfer doesn't linger.
            items.removeAll { $0.filename == filename && $0.progress != nil && $0.localURL == nil }
            return
        }
        if let inFlight = items.first(where: { $0.filename == filename && $0.progress != nil && $0.localURL == nil }) {
            inFlight.progress = nil
            inFlight.size = data.count
            inFlight.localURL = dest
        } else {
            items.insert(BrowserDownload(filename: dest.lastPathComponent, size: data.count, progress: nil), at: 0)
            items.first?.localURL = dest
        }
        popoverShown = true   // Safari-style: reveal where it landed.
    }

    /// Append " (1)", " (2)", … when the name is already taken in the directory,
    /// mirroring how Chromium/Finder de-duplicate download names.
    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: url.path) else { return url }
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 1
        repeat {
            let candidate = ext.isEmpty ? "\(name) (\(n))" : "\(name) (\(n)).\(ext)"
            url = directory.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }
}

// MARK: - Safari-style downloads popover

/// The popover hung off the browser toolbar's downloads button. Each row shows
/// the file, its size (or transfer progress), and — once saved — a Show-in-Finder
/// button; the whole row reveals the file in Finder.
struct BrowserDownloadsView: View {
    @Bindable var model: BrowserDownloadsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Downloads", comment: "Browser downloads popover title"))
                    .font(.headline)
                Spacer()
                if model.items.contains(where: { $0.progress == nil }) {
                    Button(NSLocalizedString("Clear", comment: "Clear downloads list")) { model.clear() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(NSLocalizedString("Downloaded files are saved to your Downloads folder.", comment: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.items) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    private func row(_ item: BrowserDownload) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title3).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.localURL?.lastPathComponent ?? item.filename)
                    .font(.subheadline).lineLimit(1).truncationMode(.middle)
                if let p = item.progress {
                    ProgressView(value: p).progressViewStyle(.linear)
                } else if let url = item.localURL {
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(
                            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if item.progress == nil, item.localURL != nil {
                Button { model.revealInFinder(item) } label: {
                    Image(systemName: "magnifyingglass.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Show in Finder", comment: ""))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.revealInFinder(item) }
    }
}
