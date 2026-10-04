import CryptoKit
import SwiftUI
import WebKit
#if canImport(AVKit)
import AVKit
#endif

// MARK: - The display MCP's cards (show_media / show_chart)
//
// An agent shows the user a picture, a video or a chart by calling the
// guest's `display` MCP (bromure-display-mcp.py). Nothing travels on a side
// channel: the call sits in the agent's transcript like any tool call, and
// its arguments are all the chat needs — so every surface that reads
// transcripts (this Mac, a fat client, iPhone/iPad) renders it the same way,
// inline, with a button to pop it out into its own window (a sheet on iOS).
// Media bytes come over the chat's own guest file reads.

/// What an agent asked to show, read from its tool call.
enum DisplayRequest: Equatable {
    case media(path: String, title: String?, caption: String?)
    case chart(spec: String, title: String?, caption: String?)
    /// A file handed to the user to download (`send_file`).
    case file(path: String, note: String?)

    /// A display-MCP call, whatever the agent calls MCP tools
    /// (`mcp__display__show_chart`, `display__show_chart`, `display.show_chart`…).
    static func parse(name: String, detail: String) -> DisplayRequest? {
        let n = name.lowercased()
        let media = n.hasSuffix("show_media"), chart = n.hasSuffix("show_chart"), send = n.hasSuffix("send_file")
        guard media || chart || send,
              n.contains("display") || n == "show_media" || n == "show_chart" || n == "send_file",
              let d = detail.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        if send {
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            return .file(path: path, note: (input["note"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        let title = (input["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let caption = (input["caption"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if media {
            guard let path = input["path"] as? String, path.hasPrefix("/") else { return nil }
            return .media(path: path, title: title, caption: caption)
        }
        // The spec may come as an object or as a JSON string.
        var spec: Any? = input["spec"]
        if let s = spec as? String, let d = s.data(using: .utf8) { spec = try? JSONSerialization.jsonObject(with: d) }
        guard let obj = spec as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return .chart(spec: text, title: title, caption: caption)
    }

    var title: String? {
        switch self {
        case .media(_, let t, _), .chart(_, let t, _): return t
        case .file(let path, _): return (path as NSString).lastPathComponent
        }
    }
    var caption: String? {
        switch self {
        case .media(_, _, let c), .chart(_, _, let c): return c
        case .file(_, let note): return note
        }
    }
}

// MARK: Reading the file off the machine

/// Reads a file from the machine the agent runs on (this Mac's VM, a remote
/// one through the fat client, …), in chunks. nil = too big or unreadable.
struct DisplayFileReader {
    let read: (_ path: String, _ maxBytes: Int) async -> Data?
    /// The guest file op underneath (downloads stream through it).
    var op: (([String: Any]) async -> [String: Any]?)? = nil
    /// The machine it reads from, so cached media never crosses machines.
    var scope = ""

    func cacheKey(_ path: String) -> String { scope + "\u{1}" + path }

    /// Read `path`, else the copy the machine kept when it was shown (the
    /// original sat in /tmp, emptied at every boot, or was deleted since).
    func readKept(_ path: String, _ maxBytes: Int) async -> Data? {
        if let d = await read(path, maxBytes) { return d }
        return await read(DisplayKeep.path(for: path), maxBytes)
    }

    /// The path to fetch `path` from: itself while it exists, else its kept copy.
    func resolve(_ path: String) async -> (path: String, size: Int64)? {
        if let n = await size(path) { return (path, n) }
        let kept = DisplayKeep.path(for: path)
        if let n = await size(kept) { return (kept, n) }
        return nil
    }

    /// The file's size on the machine, or nil when it can't be read.
    func size(_ path: String) async -> Int64? {
        // One byte: the guest reads a full chunk for a length of 0.
        guard let op, let r = await op(["op": "read", "path": path, "offset": 0, "length": 1]),
              r["error"] == nil else { return nil }
        return (r["size"] as? Int64) ?? (r["size"] as? Int).map(Int64.init) ?? (r["size"] as? Double).map { Int64($0) }
    }

    /// Stream a file off the machine into `dest`, a chunk at a time — any
    /// size, never whole in memory — reporting (done, total). Written next
    /// to `dest` and moved in place at the end, so a cancelled or failed
    /// download leaves nothing half-written under the real name.
    func download(_ path: String, to dest: URL,
                  progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        guard let op else { throw DownloadError.unavailable }
        let partial = dest.deletingLastPathComponent()
            .appendingPathComponent("." + dest.lastPathComponent + ".bromure-download")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: partial) else { throw DownloadError.cantWrite }
        var done: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let r = await op(["op": "read", "path": path, "offset": done, "length": 6 * 1024 * 1024]) else {
                    throw DownloadError.unavailable
                }
                if let e = r["error"] as? String { throw DownloadError.guest(e) }
                let data = (r["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                try out.write(contentsOf: data)
                done += Int64(data.count)
                let total = (r["size"] as? Int64) ?? (r["size"] as? Int).map(Int64.init) ?? done
                await progress(done, total)
                if (r["eof"] as? Bool) ?? true || data.isEmpty { break }
            }
            try out.close()
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: partial, to: dest)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    enum DownloadError: LocalizedError {
        case unavailable, cantWrite, guest(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return NSLocalizedString("Couldn't read the file on the machine — is it still there, and is the machine running?", comment: "download")
            case .cantWrite: return NSLocalizedString("Couldn't write the file here.", comment: "download")
            case .guest(let e): return e
            }
        }
    }

    /// Over a guest file op (`read {path, offset, length}` → base64 `data`,
    /// `eof`), 6 MB a call — the size the Files pane downloads with.
    static func chunked(_ op: @escaping ([String: Any]) async -> [String: Any]?) -> DisplayFileReader {
        DisplayFileReader(read: { path, maxBytes in
            var out = Data()
            let chunk = 6 * 1024 * 1024
            while true {
                guard let r = await op(["op": "read", "path": path, "offset": out.count, "length": chunk]),
                      r["error"] == nil else { return nil }
                if let b64 = r["data"] as? String, let d = Data(base64Encoded: b64) { out.append(d) }
                if out.count > maxBytes { return nil }
                let eof = (r["eof"] as? Bool) ?? true
                if eof || (r["data"] as? String ?? "").isEmpty { return out }
            }
        }, op: op)
    }
}

private struct DisplayFileReaderKey: EnvironmentKey {
    static let defaultValue: DisplayFileReader? = nil
}

extension EnvironmentValues {
    /// Set by each chat host: where a media card reads its file.
    var displayFileReader: DisplayFileReader? {
        get { self[DisplayFileReaderKey.self] }
        set { self[DisplayFileReaderKey.self] = newValue }
    }
}

/// Bytes already fetched, so a re-render (every transcript poll) or a
/// pop-out doesn't fetch again. Videos land in a temp file for the player.
@MainActor
enum DisplayMediaCache {
    private static var images: [String: Data] = [:]
    private static var imageBytes = 0
    private static var videos: [String: URL] = [:]
    private static let imageBudget = 200 * 1024 * 1024

    static func image(_ key: String) -> Data? { images[key] }
    /// A copy of `path` fetched by some chat in this run, whatever machine
    /// scope it was cached under — for a card with no live reader (a paused
    /// session, B70). Only an unambiguous match: two machines' /tmp/shot.png
    /// are two pictures.
    static func image(anyScopeFor path: String) -> Data? {
        if let d = images[path] { return d }
        let suffix = "\u{1}" + path
        let hits = images.filter { $0.key.hasSuffix(suffix) }
        return hits.count == 1 ? hits.first?.value : nil
    }
    static func video(anyScopeFor path: String) -> URL? {
        if let u = video(path) { return u }
        let suffix = "\u{1}" + path
        let hits = videos.keys.filter { $0.hasSuffix(suffix) }
        return hits.count == 1 ? video(hits[0]) : nil
    }
    static func store(image: Data, for key: String) {
        if imageBytes + image.count > imageBudget { images.removeAll(); imageBytes = 0 }
        images[key] = image
        imageBytes += image.count
    }
    static func video(_ key: String) -> URL? {
        videos[key].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    static func store(video: Data, for key: String, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-display-\(UUID().uuidString).\(ext)")
        guard (try? video.write(to: url)) != nil else { return nil }
        videos[key] = url
        return url
    }
}

enum DisplayMediaKind {
    case image, video

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
    static let videoExt: Set<String> = ["mp4", "m4v", "mov"]

    init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.imageExt.contains(ext) { self = .image }
        else if Self.videoExt.contains(ext) { self = .video }
        else { return nil }
    }
}

// MARK: The card in the chat

struct DisplayCard: View {
    let request: DisplayRequest
    @Environment(\.displayFileReader) private var reader
    #if os(iOS) || os(visionOS)
    @State private var poppedOut = false
    #endif

    var body: some View {
        if case .file(let path, let note) = request {
            FileDownloadCard(path: path, note: note)
        } else {
            visualCard
        }
    }

    private var visualCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content(expanded: false)
                .padding(8)
            if let c = request.caption {
                Text(c)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }
        }
        .transcriptCard()
        #if os(iOS) || os(visionOS)
        .sheet(isPresented: $poppedOut) {
            NavigationStack {
                content(expanded: true)
                    .padding()
                    .navigationTitle(request.title ?? kindName)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("Done", comment: "display card")) { poppedOut = false }
                        }
                    }
            }
            .environment(\.displayFileReader, reader)
        }
        #endif
    }

    private var kindName: String {
        switch request {
        case .chart: return NSLocalizedString("Chart", comment: "display card")
        case .file: return NSLocalizedString("File", comment: "display card")
        case .media(let path, _, _):
            return DisplayMediaKind(path: path) == .video
                ? NSLocalizedString("Video", comment: "display card")
                : NSLocalizedString("Image", comment: "display card")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(request.title ?? kindName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if case .media(let path, _, _) = request {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: popOut) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isChart
                  ? NSLocalizedString("Open in its own window (inline, ⌥-scroll zooms the chart)", comment: "display card")
                  : NSLocalizedString("Open in its own window", comment: "display card"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var isChart: Bool { if case .chart = request { return true }; return false }

    private var icon: String {
        switch request {
        case .chart: return "chart.xyaxis.line"
        case .file: return "arrow.down.doc"
        case .media(let path, _, _): return DisplayMediaKind(path: path) == .video ? "film" : "photo"
        }
    }

    @ViewBuilder
    private func content(expanded: Bool) -> some View {
        switch request {
        case .chart(let spec, _, _):
            ChartView(spec: spec, fill: expanded)
        case .media(let path, _, _):
            MediaView(path: path, expanded: expanded)
        case .file(let path, let note):
            FileDownloadCard(path: path, note: note)
        }
    }

    private func popOut() {
        #if os(macOS)
        DisplayWindows.open(request: request, reader: reader)
        #else
        poppedOut = true
        #endif
    }
}

/// Where the machine keeps a copy of what an agent showed or sent
/// (bromure-display-mcp.py `kept_path`, same naming).
enum DisplayKeep {
    static let dir = "/home/ubuntu/.bromure/display"
    static func path(for original: String) -> String {
        let digest = SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (original as NSString).pathExtension.lowercased()
        return dir + "/" + String(digest.prefix(32)) + (ext.isEmpty ? "" : "." + ext)
    }
}

// MARK: Sent files (send_file)

/// One download's progress, held outside the view so it survives the chat's
/// lazy list recycling the row (and a second card for the same file shows the
/// same state).
@MainActor
final class DisplayDownloads: ObservableObject {
    static let shared = DisplayDownloads()

    enum State: Equatable {
        case idle
        case running(done: Int64, total: Int64)
        case done(URL)
        case failed(String)
    }
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var sizes: [String: Int64] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func state(_ key: String) -> State { states[key] ?? .idle }

    func loadSize(_ path: String, reader: DisplayFileReader) async {
        guard sizes[path] == nil, let found = await reader.resolve(path) else { return }
        sizes[path] = found.size
    }

    func start(_ key: String, path: String, to dest: URL, reader: DisplayFileReader) {
        guard tasks[key] == nil else { return }
        states[key] = .running(done: 0, total: sizes[path] ?? 0)
        tasks[key] = Task { [weak self] in
            do {
                // The original, else the copy the machine kept when it was sent.
                let source = await reader.resolve(path)?.path ?? path
                try await reader.download(source, to: dest) { done, total in
                    self?.states[key] = .running(done: done, total: total)
                }
                self?.states[key] = .done(dest)
            } catch is CancellationError {
                self?.states[key] = .idle
            } catch {
                self?.states[key] = .failed(error.localizedDescription)
            }
            self?.tasks[key] = nil
        }
    }

    func cancel(_ key: String) { tasks[key]?.cancel() }

    /// A free name in `folder`: "report.zip", then "report 2.zip", …
    nonisolated static func uniqueURL(in folder: URL, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// A file the agent sent: its name and size, and the way to get it onto this
/// device — streamed off the machine in chunks, so any size works.
struct FileDownloadCard: View {
    let path: String
    let note: String?
    @Environment(\.displayFileReader) private var reader
    @ObservedObject private var downloads = DisplayDownloads.shared

    private var name: String { (path as NSString).lastPathComponent }
    private var key: String { path }
    private var state: DisplayDownloads.State { downloads.state(key) }
    private var isArchive: Bool {
        let low = name.lowercased()
        return [".zip", ".tar", ".tgz", ".gz", ".xz", ".bz2", ".7z", ".zst"].contains { low.hasSuffix($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isArchive ? "doc.zipper" : "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                actions
            }
            if case .running(let done, let total) = state {
                if total > 0 {
                    ProgressView(value: Double(min(done, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .transcriptCard()
        .task(id: path) {
            if let reader { await downloads.loadSize(path, reader: reader) }
        }
    }

    private var subtitle: String {
        let size = downloads.sizes[path].map(Self.bytes)
        switch state {
        case .idle:
            if reader?.op == nil {
                // No live machine behind this chat (a paused session, B70).
                return NSLocalizedString("Available when the workspace is running", comment: "download")
            }
            return size.map { String(format: NSLocalizedString("%@ · sent by the agent", comment: "download"), $0) }
                ?? NSLocalizedString("Sent by the agent", comment: "download")
        case .running(let done, let total):
            return total > 0
                ? String(format: NSLocalizedString("%@ of %@", comment: "download"), Self.bytes(done), Self.bytes(total))
                : Self.bytes(done)
        case .done(let url):
            #if os(macOS)
            return String(format: NSLocalizedString("Saved to %@", comment: "download"),
                          (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            #else
            _ = url
            return size.map { String(format: NSLocalizedString("%@ · downloaded", comment: "download"), $0) }
                ?? NSLocalizedString("Downloaded", comment: "download")
            #endif
        case .failed(let why):
            return why
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch state {
            case .idle:
                if let reader, reader.op != nil {
                    #if os(macOS)
                    Button(NSLocalizedString("Save As…", comment: "download")) { saveAs(reader) }
                        .controlSize(.small)
                    #endif
                    Button(NSLocalizedString("Download", comment: "download")) { download(reader) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            case .running:
                Button(NSLocalizedString("Cancel", comment: "download")) { downloads.cancel(key) }
                    .controlSize(.small)
            case .done(let url):
                #if os(macOS)
                Button(NSLocalizedString("Show in Finder", comment: "download")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
                Button(NSLocalizedString("Open", comment: "download")) { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                #else
                ShareLink(item: url) {
                    Label(NSLocalizedString("Save or Share", comment: "download"), systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                #endif
            case .failed:
                if let reader {
                    Button(NSLocalizedString("Try Again", comment: "download")) { download(reader) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func download(_ reader: DisplayFileReader) {
        #if os(macOS)
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bromure Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        downloads.start(key, path: path, to: DisplayDownloads.uniqueURL(in: folder, name: name), reader: reader)
    }

    #if os(macOS)
    private func saveAs(_ reader: DisplayFileReader) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloads.start(key, path: path, to: url, reader: reader)
    }
    #endif

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: Media

struct MediaView: View {
    let path: String
    let expanded: Bool
    @Environment(\.displayFileReader) private var reader
    @State private var image: PlatformImage?
    @State private var videoURL: URL?
    @State private var loading = false
    @State private var failure: String?
    /// No machine to read from (a paused session) and nothing cached.
    @State private var offline = false

    private var kind: DisplayMediaKind? { DisplayMediaKind(path: path) }

    var body: some View {
        Group {
            if offline {
                // B70: no machine to read from (a paused session) — a calm
                // placeholder, not a warning.
                VStack(spacing: 6) {
                    Image(systemName: kind == .video ? "film" : "photo")
                        .font(.system(size: 22, weight: .light))
                    Text(kind == .video
                         ? NSLocalizedString("Video available when the workspace is running", comment: "display card")
                         : NSLocalizedString("Image available when the workspace is running", comment: "display card"))
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if let image {
                imageView(image)
            } else if let videoURL {
                #if canImport(AVKit)
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .frame(minHeight: expanded ? 300 : 240, maxHeight: expanded ? .infinity : 360)
                #endif
            } else if kind == .video && !loading {
                Button(action: load) {
                    Label(NSLocalizedString("Play video", comment: "display card"), systemImage: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        // Re-run when the machine comes or goes (a paused session resumed).
        .task(id: reader == nil) {
            guard let reader else {
                // A paused session: the copy this run already fetched, if any.
                if let d = DisplayMediaCache.image(anyScopeFor: path), let img = PlatformImage(data: d) {
                    image = img
                } else if let u = DisplayMediaCache.video(anyScopeFor: path) {
                    videoURL = u
                } else if kind != nil {
                    offline = true
                } else {
                    load()   // says it isn't an image or a video
                }
                return
            }
            offline = false
            let key = reader.cacheKey(path)
            if let d = DisplayMediaCache.image(key), let img = PlatformImage(data: d) { image = img; return }
            if let u = DisplayMediaCache.video(key) { videoURL = u; return }
            if kind == .image || expanded { load() }   // a video waits for a tap inline
        }
    }

    @ViewBuilder
    private func imageView(_ img: PlatformImage) -> some View {
        #if os(macOS)
        let v = Image(nsImage: img)
        #else
        let v = Image(uiImage: img)
        #endif
        v.resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : 420)
    }

    private func load() {
        guard !loading else { return }
        guard let kind else { failure = NSLocalizedString("Not an image or a video this app can show.", comment: "display card"); return }
        guard let reader else { offline = true; return }   // B70: paused — a calm placeholder
        loading = true
        let path = self.path
        Task { @MainActor in
            let cap = kind == .image ? 25 * 1024 * 1024 : 500 * 1024 * 1024
            let key = reader.cacheKey(path)
            guard let data = await reader.readKept(path, cap) else {
                loading = false
                failure = String(format: NSLocalizedString("Couldn't read %@.", comment: "display card"),
                                 (path as NSString).lastPathComponent)
                return
            }
            switch kind {
            case .image:
                if let img = PlatformImage(data: data) {
                    DisplayMediaCache.store(image: data, for: key)
                    image = img
                } else {
                    failure = NSLocalizedString("That image couldn't be decoded.", comment: "display card")
                }
            case .video:
                if let url = DisplayMediaCache.store(video: data, for: key,
                                                     ext: (path as NSString).pathExtension.lowercased()) {
                    videoURL = url
                } else {
                    failure = NSLocalizedString("Couldn't prepare the video.", comment: "display card")
                }
            }
            loading = false
        }
    }
}

// MARK: Charts (Vega-Lite, offline)

/// The bundled Vega libraries, read once. nil when this bundle doesn't ship
/// them → the card shows the spec instead.
enum VegaBundle {
    static let script: String? = {
        let names = ["vega.min", "vega-lite.min", "vega-embed.min"]
        var parts: [String] = []
        for n in names {
            guard let url = acResourceBundle.url(forResource: n, withExtension: "js", subdirectory: "vega"),
                  let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            parts.append(s)
        }
        return parts.joined(separator: "\n;\n")
    }()
}

enum VegaRenderer {
    /// Renders with vega-embed (tooltips, the spec's own zoom/pan/selection
    /// params), sized to the container, and reports the height back (and
    /// again whenever it changes). `fill`: the chart takes the whole page (a
    /// popped-out window) — its height too, unless the spec sets one.
    static let initScript = """
    (async () => {
      const post = (name, v) => { try { window.webkit.messageHandlers[name].postMessage(v); } catch (e) {} };
      try {
        if (typeof vegaEmbed !== 'function') throw new Error('vega-embed not loaded');
        const spec = JSON.parse(document.getElementById('spec').textContent);
        if (spec.width === undefined) spec.width = 'container';
        if (window.__fill && spec.height === undefined) spec.height = 'container';
        if (spec.autosize === undefined) spec.autosize = { type: 'fit', contains: 'padding' };
        const opts = { actions: false, renderer: 'svg', theme: window.__dark ? 'dark' : undefined,
                       config: { background: null } };
        const res = await vegaEmbed('#c', spec, opts);
        const report = () => post('vegaSize', Math.ceil(document.getElementById('c').getBoundingClientRect().height) + 4);
        report();
        new ResizeObserver(report).observe(document.getElementById('c'));
        window.addEventListener('resize', () => { res.view.resize().runAsync(); });
      } catch (e) {
        post('vegaError', String((e && e.message) || e));
      }
    })();
    """

    static func html(spec: String, dark: Bool, fill: Bool) -> String {
        // Inside <script type="application/json">: only "</" can end it early.
        let safe = spec.replacingOccurrences(of: "</", with: "<\\/")
        let size = fill ? "html, body, #c { height: 100%; }" : ""
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden;
                       font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
          #c { width: 100%; } \(size)
          #vg-tooltip-element { font-family: -apple-system, sans-serif; }
        </style></head>
        <body><div id="c"></div>
        <script type="application/json" id="spec">\(safe)</script>
        <script>window.__dark = \(dark ? "true" : "false"); window.__fill = \(fill ? "true" : "false");</script>
        <script>\(initScript)</script>
        </body></html>
        """
    }
}

final class VegaWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onHeight: (CGFloat) -> Void
    var onError: (String) -> Void
    private var loaded: (spec: String, dark: Bool)?

    init(onHeight: @escaping (CGFloat) -> Void, onError: @escaping (String) -> Void) {
        self.onHeight = onHeight
        self.onError = onError
    }

    /// Load, or reload on a spec / color-scheme change — not on every
    /// transcript re-render (that would reset the user's zoom and pan).
    func load(_ wv: WKWebView, spec: String, dark: Bool, fill: Bool) {
        if let l = loaded, l.spec == spec, l.dark == dark { return }
        loaded = (spec, dark)
        wv.loadHTMLString(VegaRenderer.html(spec: spec, dark: dark, fill: fill), baseURL: nil)
    }

    static func configure(_ cfg: WKWebViewConfiguration, coordinator: VegaWebCoordinator) {
        let ucc = WKUserContentController()
        if let lib = VegaBundle.script {
            ucc.addUserScript(WKUserScript(source: lib, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        ucc.add(coordinator, name: "vegaSize")
        ucc.add(coordinator, name: "vegaError")
        cfg.userContentController = ucc
    }

    static func teardown(_ wv: WKWebView) {
        let ucc = wv.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "vegaSize")
        ucc.removeScriptMessageHandler(forName: "vegaError")
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "vegaSize": if let n = message.body as? NSNumber { onHeight(CGFloat(truncating: n)) }
        case "vegaError": onError(String(describing: message.body))
        default: break
        }
    }

    /// No navigation away (a link in a tooltip or a mark's href).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

#if canImport(AppKit)
/// Inline in the chat, a chart must not swallow the trackpad: the scroll
/// goes on to the transcript (the web view — and a spec whose zoom is bound
/// to the wheel — took it, and the chat stopped scrolling under the pointer).
/// ⌥-scroll still zooms/pans the chart; popped out, the chart has the wheel.
final class ChartWebView: WKWebView {
    var passScroll = true
    override func scrollWheel(with event: NSEvent) {
        if passScroll, !event.modifierFlags.contains(.option), let outer = enclosingScrollView {
            outer.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct VegaWebView: NSViewRepresentable {
    let spec: String
    let dark: Bool
    let fill: Bool
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> VegaWebCoordinator { VegaWebCoordinator(onHeight: onHeight, onError: onError) }
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        VegaWebCoordinator.configure(cfg, coordinator: context.coordinator)
        let wv = ChartWebView(frame: .zero, configuration: cfg)
        wv.passScroll = !fill
        wv.underPageBackgroundColor = .clear   // the card shows through (public API)
        wv.navigationDelegate = context.coordinator
        context.coordinator.load(wv, spec: spec, dark: dark, fill: fill)
        return wv
    }
    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onError = onError
        context.coordinator.load(wv, spec: spec, dark: dark, fill: fill)
    }
    static func dismantleNSView(_ wv: WKWebView, coordinator: VegaWebCoordinator) {
        VegaWebCoordinator.teardown(wv)
    }
}
#elseif canImport(UIKit)
struct VegaWebView: UIViewRepresentable {
    let spec: String
    let dark: Bool
    let fill: Bool
    let onHeight: (CGFloat) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> VegaWebCoordinator { VegaWebCoordinator(onHeight: onHeight, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        VegaWebCoordinator.configure(cfg, coordinator: context.coordinator)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.navigationDelegate = context.coordinator
        context.coordinator.load(wv, spec: spec, dark: dark, fill: fill)
        return wv
    }
    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onError = onError
        context.coordinator.load(wv, spec: spec, dark: dark, fill: fill)
    }
    static func dismantleUIView(_ wv: WKWebView, coordinator: VegaWebCoordinator) {
        VegaWebCoordinator.teardown(wv)
    }
}
#endif

struct ChartView: View {
    let spec: String
    /// Popped out: the chart fills the window.
    let fill: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 280
    @State private var error: String?

    var body: some View {
        if VegaBundle.script == nil || error != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Label(String(format: NSLocalizedString("The chart couldn't be drawn: %@", comment: "display card"), error),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                RawJSONBlock(spec)
            }
        } else if fill {
            VegaWebView(spec: spec, dark: colorScheme == .dark, fill: true,
                        onHeight: { _ in }, onError: { error = $0 })
                .frame(minWidth: 320, minHeight: 240)
        } else {
            VegaWebView(spec: spec, dark: colorScheme == .dark, fill: false,
                        onHeight: { h in if h > 20 { height = min(h, 900) } },
                        onError: { error = $0 })
                .frame(height: height)
        }
    }
}

// MARK: Pop-out windows (macOS)

#if os(macOS)
@MainActor
enum DisplayWindows {
    private static var windows: [NSWindow] = []

    static func open(request: DisplayRequest, reader: DisplayFileReader?) {
        let title: String
        let content: AnyView
        switch request {
        case .chart(let spec, let t, _):
            title = t ?? NSLocalizedString("Chart", comment: "display card")
            content = AnyView(ChartView(spec: spec, fill: true).padding(12))
        case .media(let path, let t, _):
            title = t ?? (path as NSString).lastPathComponent
            content = AnyView(MediaView(path: path, expanded: true).padding(8))
        case .file:
            return
        }
        let root = VStack(spacing: 0) {
            content
            if let c = request.caption {
                Text(c)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .environment(\.displayFileReader, reader)
        .frame(minWidth: 360, minHeight: 280)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.collectionBehavior.insert(.fullScreenPrimary)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        win.contentView = host
        // Cascade off the last one so several don't stack exactly.
        if let last = windows.last(where: \.isVisible) {
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            win.center()
        }
        windows.removeAll { !$0.isVisible }
        windows.append(win)
        win.makeKeyAndOrderFront(nil)
    }
}
#endif

#if os(macOS)
extension DisplayCard {
    /// Hidden verification hook (`bromure-ac __shot-chart [png] [spec.json] [--dark]`):
    /// host a real chart card (the display MCP's `show_chart`) in a window,
    /// let vega-embed render and report its size, snapshot the embedded web
    /// view to a PNG, print its size (or the error), exit. Standalone: no app
    /// delegate, servers or VMs.
    static func renderChartSnapshot(spec: String, dark: Bool, to path: String) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            guard VegaBundle.script != nil else { print("error=vega bundle missing"); exit(2) }
            let root = ScrollView {
                DisplayCard(request: .chart(spec: spec, title: "Snapshot", caption: "Rendered by __shot-chart"))
                    .padding(16)
            }
            .frame(width: 760, height: 700)
            .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            func pump(_ seconds: TimeInterval) {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until {
                    if let ev = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                              inMode: .default, dequeue: true) { app.sendEvent(ev) }
                    app.updateWindows()
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
            }
            func findWebView(_ v: NSView) -> WKWebView? {
                if let w = v as? WKWebView { return w }
                for s in v.subviews { if let w = findWebView(s) { return w } }
                return nil
            }
            pump(4)
            guard let web = findWebView(host) else { print("error=no chart web view (fell back to the spec)"); exit(1) }
            print("chartWebView=\(Int(web.frame.width))x\(Int(web.frame.height))")
            var done = false
            let snap = WKSnapshotConfiguration()
            snap.rect = web.bounds
            web.takeSnapshot(with: snap) { img, err in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("png=\(path)")
                } else {
                    print("error=snapshot: \(err?.localizedDescription ?? "unknown")")
                }
                done = true
            }
            let d = Date().addingTimeInterval(10)
            while !done && Date() < d { pump(0.05) }
            exit(done ? 0 : 1)
        }
    }
}
#endif
