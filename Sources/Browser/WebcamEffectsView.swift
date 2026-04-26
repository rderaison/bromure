@preconcurrency import AVFoundation
import SwiftUI
import SandboxEngine
import BrowserBridges
import UniformTypeIdentifiers

/// Effects panel for configuring webcam overlays (city/time, name badge, logo, face swap).
/// Shows dual camera previews: mirrored ("What you see") and non-mirrored ("What they see").
struct WebcamEffectsView: View {
    @Binding var effects: WebcamEffects
    let webcamDeviceID: String?
    var onDismiss: () -> Void

    @StateObject private var preview = MediaPreviewModel()
    @State private var showModelDownloadAlert = false
    @State private var isDownloadingModels = false
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?
    @State private var imageError: String?
    @State private var showImageError = false
    @State private var faceSwapEngine: FaceSwapEngine?

    // Common city/timezone pairs
    private static let cities: [(name: String, tz: String)] = [
        ("New York", "America/New_York"),
        ("Los Angeles", "America/Los_Angeles"),
        ("Chicago", "America/Chicago"),
        ("London", "Europe/London"),
        ("Paris", "Europe/Paris"),
        ("Berlin", "Europe/Berlin"),
        ("Tokyo", "Asia/Tokyo"),
        ("Shanghai", "Asia/Shanghai"),
        ("Dubai", "Asia/Dubai"),
        ("Sydney", "Australia/Sydney"),
        ("Mumbai", "Asia/Kolkata"),
        ("S\u{e3}o Paulo", "America/Sao_Paulo"),
        ("Toronto", "America/Toronto"),
        ("Singapore", "Asia/Singapore"),
        ("Hong Kong", "Asia/Hong_Kong"),
        ("Seoul", "Asia/Seoul"),
        ("Moscow", "Europe/Moscow"),
        ("Istanbul", "Europe/Istanbul"),
        ("Mexico City", "America/Mexico_City"),
        ("Johannesburg", "Africa/Johannesburg"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Dual preview
            HStack(spacing: 16) {
                previewPane(mirrored: true, caption: "What you see")
                previewPane(mirrored: false, caption: "What they see")
            }
            .padding(20)

            Divider()

            // Effect controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // City & Time
                    VStack(alignment: .leading, spacing: 6) {
                        Text("City & Time").font(.headline)
                        Text("Shows a city name and its current local time in the top-left corner.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("City name", text: $effects.cityName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Picker("Time zone", selection: $effects.timeZoneIdentifier) {
                                Text("Select\u{2026}").tag("")
                                Divider()
                                ForEach(Self.cities, id: \.tz) { city in
                                    Text("\(city.name) (\(Self.abbreviation(for: city.tz)))")
                                        .tag(city.tz)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }

                    Divider()

                    // Display Name & Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name Badge").font(.headline)
                        Text("Your name and title appear in the bottom-right corner, like a TV news anchor.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Display name", text: $effects.displayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                        TextField("Job title", text: $effects.displayTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }

                    Divider()

                    // Logo
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Logo").font(.headline)
                        Text("An image displayed in the top-right corner of the video.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            if let data = effects.logoPNGData, let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )

                                Button(role: .destructive) {
                                    effects.logoPNGData = nil
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .controlSize(.small)
                            }

                            Button {
                                pickLogo()
                            } label: {
                                Label(
                                    effects.logoPNGData == nil ? "Choose Image\u{2026}" : "Replace\u{2026}",
                                    systemImage: "photo"
                                )
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Face Swap
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Face Swap").font(.headline)
                        Text("Replace your face with another in the video feed. A red banner will indicate the effect is active.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Toggle("Enable Face Swap", isOn: $effects.faceSwapEnabled)
                            .onChange(of: effects.faceSwapEnabled) { _, enabled in
                                if enabled && !FaceSwapEngine.modelsExist {
                                    effects.faceSwapEnabled = false
                                    showModelDownloadAlert = true
                                }
                            }

                        if effects.faceSwapEnabled {
                            HStack(spacing: 12) {
                                if let data = effects.faceSwapImageData, let nsImage = NSImage(data: data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 48, height: 48)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                                    Button(role: .destructive) {
                                        effects.faceSwapImageData = nil
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                    .controlSize(.small)
                                }

                                Button {
                                    pickFaceSwapImage()
                                } label: {
                                    Label(
                                        effects.faceSwapImageData == nil ? "Choose Face\u{2026}" : "Replace\u{2026}",
                                        systemImage: "person.crop.circle"
                                    )
                                }
                                .controlSize(.small)
                            }
                        }

                        if isDownloadingModels {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: downloadProgress)
                                    .frame(width: 200)
                                Text("Downloading face swap models\u{2026}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = downloadError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                }
                .padding(20)
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 680)
        .onAppear {
            preview.startCamera(deviceID: webcamDeviceID)
            updateFaceSwapProcessor()
        }
        .onDisappear {
            preview.stop()
        }
        .onChange(of: effects.faceSwapEnabled) { _, _ in updateFaceSwapProcessor() }
        .onChange(of: effects.faceSwapImageData) { _, _ in updateFaceSwapProcessor() }
        .alert("Image Error", isPresented: $showImageError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(imageError ?? "Unknown error")
        }
        .alert("Download Face Swap Models?", isPresented: $showModelDownloadAlert) {
            Button("Download") {
                startModelDownload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Face swap requires two AI models (~500 MB total). They will be downloaded from Hugging Face and stored locally.")
        }
    }

    /// Max logo height in pixels — the overlay renders it at ~50px on 1080p,
    /// so 256px gives plenty of headroom for retina without wasting memory.
    private static let maxLogoHeight: CGFloat = 256
    private static let maxLogoFileSize = 10 * 1024 * 1024  // 10 MB

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .svg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int, fileSize > Self.maxLogoFileSize {
            imageError = "Logo file is too large (\(fileSize / 1024 / 1024) MB). Maximum is 10 MB."
            showImageError = true
            return
        }

        guard let nsImage = NSImage(contentsOf: url) else {
            imageError = "Could not open this file."
            showImageError = true
            return
        }

        // Downscale if taller than maxLogoHeight, preserving aspect ratio
        let rep = nsImage.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(nsImage.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(nsImage.size.height))
        let maxH = Self.maxLogoHeight

        let finalImage: NSImage
        if ph > maxH {
            let scale = maxH / ph
            let newW = round(pw * scale)
            let newSize = NSSize(width: newW, height: maxH)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            nsImage.draw(in: NSRect(origin: .zero, size: newSize),
                         from: NSRect(x: 0, y: 0, width: pw, height: ph),
                         operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            finalImage = resized
        } else {
            finalImage = nsImage
        }

        guard let pngData = finalImage.pngRepresentation() else {
            imageError = "Could not process this image."
            showImageError = true
            return
        }
        effects.logoPNGData = pngData
    }

    private func pickFaceSwapImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Validate file size (50 MB limit)
        let maxSize = 50 * 1024 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int, fileSize > maxSize {
            imageError = "Image file is too large (\(fileSize / 1024 / 1024) MB). Maximum is 50 MB."
            showImageError = true
            return
        }

        guard let nsImage = NSImage(contentsOf: url) else {
            imageError = "Could not open this file. It may be corrupted or in an unsupported format."
            showImageError = true
            return
        }

        // Check dimensions (4096×4096 limit)
        let rep = nsImage.representations.first
        let pw = rep?.pixelsWide ?? Int(nsImage.size.width)
        let ph = rep?.pixelsHigh ?? Int(nsImage.size.height)
        if pw > 4096 || ph > 4096 {
            imageError = "Image is too large (\(pw)×\(ph) pixels). Maximum is 4096×4096."
            showImageError = true
            return
        }

        guard let pngData = nsImage.pngRepresentation() else {
            imageError = "Could not process this image. Try a different file."
            showImageError = true
            return
        }

        effects.faceSwapImageData = pngData
    }

    private func updateFaceSwapProcessor() {
        if effects.faceSwapActive, let imageData = effects.faceSwapImageData {
            do {
                let engine = try FaceSwapEngine(sourceImageData: imageData)
                self.faceSwapEngine = engine
                preview.setFrameProcessor { pixelBuffer, ctx, width, height in
                    engine.processFrame(ctx: ctx, pixelBuffer: pixelBuffer, width: width, height: height)
                }
                return
            } catch {
                print("[FaceSwap] engine init failed: \(error)")
                imageError = "Face swap failed: \(error.localizedDescription)"
                showImageError = true
            }
        }
        // Disable processing
        self.faceSwapEngine = nil
        preview.setFrameProcessor(nil)
    }

    private func startModelDownload() {
        isDownloadingModels = true
        downloadProgress = 0
        downloadError = nil

        Task {
            do {
                try await FaceSwapEngine.downloadModels { progress in
                    Task { @MainActor in
                        downloadProgress = progress
                    }
                }
                await MainActor.run {
                    isDownloadingModels = false
                    effects.faceSwapEnabled = true
                }
            } catch {
                await MainActor.run {
                    isDownloadingModels = false
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Preview Pane

    @ViewBuilder
    private func previewPane(mirrored: Bool, caption: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if let processedFrame = preview.processedFrame {
                    // Show face-swapped processed frame
                    ProcessedFrameView(frame: processedFrame)
                        .aspectRatio(4/3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    // Show raw camera preview
                    CameraPreviewView(session: preview.captureSession)
                        .aspectRatio(4/3, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                if !preview.cameraActive {
                    VStack(spacing: 4) {
                        Image(systemName: "video.slash")
                            .font(.title2)
                        Text("No camera")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                // Overlay effects (drawn on top — only non-faceswap overlays when processed)
                overlayEffects
            }
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - SwiftUI Overlay Effects

    @ViewBuilder
    private var overlayEffects: some View {
        GeometryReader { geo in
            let fontSize = max(8, geo.size.height * effects.fontSizePercent / 100)
            let margin = fontSize * 1.2

            // Top-left: city & time (CNN-style stacked box)
            if !effects.cityName.isEmpty {
                CityTimeBox(
                    cityName: effects.cityName,
                    timeZoneIdentifier: effects.timeZoneIdentifier,
                    fontSize: fontSize
                )
                .padding(.leading, margin)
                .padding(.top, margin * 0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // Top-right: logo
            if let data = effects.logoPNGData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: fontSize * 2.5)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 1)
                    .padding(.trailing, margin)
                    .padding(.top, margin * 0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Bottom-right: CNN-style name badge (name white-on-red, title black-on-white)
            if !effects.displayName.isEmpty || !effects.displayTitle.isEmpty {
                NameBadge(name: effects.displayName, title: effects.displayTitle,
                          fontSize: fontSize)
                    .padding(.trailing, margin)
                    .padding(.bottom, effects.faceSwapActive ? margin * 0.8 + geo.size.height * 0.06 : margin * 0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            // Face swap scrolling disclaimer banner at bottom
            if effects.faceSwapActive {
                FaceSwapBanner(height: geo.size.height * 0.06, fontSize: max(6, geo.size.height * 0.033))
            }
        }
    }

    // MARK: - Timezone helper

    private static func abbreviation(for identifier: String) -> String {
        TimeZone(identifier: identifier)?.abbreviation() ?? identifier
    }
}

// MARK: - City & Time box (CNN-style stacked display)

/// Displays city name above a separator line above the time, in a clean news-style box.
private struct CityTimeBox: View {
    let cityName: String
    let timeZoneIdentifier: String
    let fontSize: CGFloat
    private let fontFamily = "Helvetica Neue"

    @State private var currentTime = ""
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // City name row (white on red)
            Text(cityName.uppercased())
                .font(.custom(fontFamily, size: fontSize * 0.75).weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, fontSize * 0.5)
                .padding(.vertical, fontSize * 0.2)
                .frame(minWidth: fontSize * 4)
                .background(Color.red)

            // Time row (white on dark)
            Text(currentTime)
                .font(.custom(fontFamily, size: fontSize * 0.85).weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, fontSize * 0.5)
                .padding(.vertical, fontSize * 0.15)
                .frame(minWidth: fontSize * 4)
                .background(Color(white: 0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: fontSize * 0.15))
        .shadow(color: .black.opacity(0.4), radius: 3, x: 1, y: 1)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
        .onChange(of: timeZoneIdentifier) { _, _ in updateTime() }
    }

    private func startTimer() {
        updateTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { updateTime() }
        }
    }

    private func updateTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "H:mm"
        if !timeZoneIdentifier.isEmpty, let tz = TimeZone(identifier: timeZoneIdentifier) {
            fmt.timeZone = tz
        }
        currentTime = fmt.string(from: Date())
    }
}

// MARK: - CNN-style Name Badge (shared between previews)

/// Two-row badge: name in white-on-red (top), title in black-on-white (bottom).
struct NameBadge: View {
    let name: String
    let title: String
    var fontSize: CGFloat = 14
    private let fontFamily = "Helvetica Neue"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !name.isEmpty {
                Text(name)
                    .font(.custom(fontFamily, size: fontSize).weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, fontSize * 0.6)
                    .padding(.vertical, fontSize * 0.25)
                    .frame(minWidth: fontSize * 4, alignment: .leading)
                    .background(Color.red)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.custom(fontFamily, size: fontSize * 0.7))
                    .foregroundStyle(.black)
                    .padding(.horizontal, fontSize * 0.6)
                    .padding(.vertical, fontSize * 0.2)
                    .frame(minWidth: fontSize * 4, alignment: .leading)
                    .background(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: fontSize * 0.1))
        .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 1)
    }
}

// MARK: - Face Swap Scrolling Banner

/// Red banner at the bottom with scrolling disclaimer text.
struct FaceSwapBanner: View {
    let height: CGFloat
    let fontSize: CGFloat

    private let text = "DISCLAIMER \u{2014} User\u{2019}s real face has been anonymized by Bromure.io    \u{2022}    "

    var body: some View {
        VStack {
            Spacer()
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    // Red background
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.85, green: 0.05, blue: 0.05)))

                    let fullText = text + text
                    let resolved = context.resolve(Text(fullText).font(.system(size: fontSize, weight: .bold)).foregroundStyle(.white))
                    let textWidth = resolved.measure(in: CGSize(width: .infinity, height: size.height)).width
                    let singleWidth = textWidth / 2

                    // Scroll: 60 points/sec
                    let offset = CGFloat(t.truncatingRemainder(dividingBy: Double(singleWidth) / 60.0)) * 60.0
                    let x = -offset.truncatingRemainder(dividingBy: singleWidth)
                    let y = (size.height - fontSize) / 2

                    context.draw(resolved, in: CGRect(x: x, y: y, width: textWidth, height: size.height))
                }
                .frame(height: height)
                .clipped()
            }
            .frame(height: height)
        }
    }
}

// MARK: - Live Effects View (for in-session editing)

/// Wraps ``WebcamEffectsView`` for use in a floating panel during an active
/// browser session.  Changes are applied to the running webcam stream in
/// real time via the ``onEffectsChanged`` callback.
struct LiveWebcamEffectsView: View {
    @State private var effects: WebcamEffects
    let webcamDeviceID: String?
    let onEffectsChanged: (WebcamEffects) -> Void
    let onDismiss: () -> Void

    init(effects: WebcamEffects, webcamDeviceID: String?,
         onEffectsChanged: @escaping (WebcamEffects) -> Void,
         onDismiss: @escaping () -> Void) {
        self._effects = State(initialValue: effects)
        self.webcamDeviceID = webcamDeviceID
        self.onEffectsChanged = onEffectsChanged
        self.onDismiss = onDismiss
    }

    var body: some View {
        WebcamEffectsView(
            effects: $effects,
            webcamDeviceID: webcamDeviceID,
            onDismiss: onDismiss
        )
        .onChange(of: effects) { _, newEffects in
            onEffectsChanged(newEffects)
        }
    }
}

// MARK: - NSImage PNG helper

private extension NSImage {
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
