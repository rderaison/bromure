import AVFoundation
import CoreGraphics
import Foundation
import Virtualization

private let wcDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Captures the host Mac's camera via AVFoundation and streams raw YUYV frames
/// to the guest VM over vsock (port 5400) for consumption by v4l2loopback.
///
/// Protocol (binary):
///   1. 12-byte header on connect: width(u32le) + height(u32le) + fps(u32le)
///   2. Per frame: size(u32le) + raw YUYV pixel data
///
/// Uses 640x480 YUYV (2 bytes/pixel) — ~18 MB/s at 30fps, well within vsock bandwidth.
@MainActor
public final class WebcamBridge: NSObject, @unchecked Sendable {
    private static let webcamPort: UInt32 = 5400
    private static let captureWidth = 640
    private static let captureHeight = 480
    private static let captureFPS = 30

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: WebcamListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: CaptureDelegate?
    private var headerSent = false
    private let cameraID: String?
    private let effects: WebcamEffects

    /// Query the native resolution of a camera without starting capture.
    public static func queryCameraResolution(cameraID: String?) -> (width: Int, height: Int) {
        let camera: AVCaptureDevice?
        if let cameraID, let specific = AVCaptureDevice(uniqueID: cameraID) {
            camera = specific
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }
        guard let camera else { return (captureWidth, captureHeight) }
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        return (Int(dims.width), Int(dims.height))
    }

    /// - Parameter cameraID: AVCaptureDevice.uniqueID to use, or nil for default.
    /// - Parameter effects: Webcam overlay effects (city/time, name badge, logo).
    public init(socketDevice: VZVirtioSocketDevice, cameraID: String? = nil, effects: WebcamEffects = WebcamEffects()) {
        self.socketDevice = socketDevice
        self.cameraID = cameraID
        self.effects = effects
        super.init()

        if wcDebug { print("[Webcam] init: setting up vsock listener on port \(Self.webcamPort)") }

        let delegate = WebcamListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.webcamPort)
    }

    public func stop() {
        if wcDebug { print("[Webcam] stop") }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        socketDevice?.removeSocketListener(forPort: Self.webcamPort)
        connection = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if wcDebug { print("[Webcam] guest connected (fd=\(conn.fileDescriptor))") }

        // Stop any existing capture
        captureSession?.stopRunning()
        captureSession = nil
        connection = conn
        headerSent = false

        startCapture(fd: conn.fileDescriptor)
    }

    private static func sendHeader(fd: Int32, width: Int, height: Int, fps: Int) {
        var data = Data(count: 12)
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(width).littleEndian, toByteOffset: 0, as: UInt32.self)
            ptr.storeBytes(of: UInt32(height).littleEndian, toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: UInt32(fps).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
    }

    private static let faceSwapFPS = 12

    private func startCapture(fd: Int32) {
        let session = AVCaptureSession()
        let hasFaceSwap = effects.faceSwapActive
        session.sessionPreset = hasFaceSwap ? .cif352x288 : .vga640x480

        let camera: AVCaptureDevice?
        if let cameraID, let specific = AVCaptureDevice(uniqueID: cameraID) {
            camera = specific
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera) else {
            print("[Webcam] no camera available")
            return
        }

        guard session.canAddInput(input) else {
            print("[Webcam] cannot add camera input")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()

        let needsEffects = effects.hasAnyEffect
        if needsEffects {
            // Capture in BGRA for overlay rendering, then convert to YUYV for output
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        } else {
            // Request YUYV (4:2:2) — universally supported by v4l2loopback
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8_yuvs
            ]
        }
        output.alwaysDiscardsLateVideoFrames = true

        let queue = DispatchQueue(label: "io.bromure.webcam-capture", qos: .userInteractive)
        let renderer = needsEffects ? OverlayRenderer(effects: effects) : nil
        let delegate = CaptureDelegate(fd: fd, overlayRenderer: renderer) { [weak self] in
            DispatchQueue.main.async {
                self?.handleDisconnect()
            }
        }
        output.setSampleBufferDelegate(delegate, queue: queue)
        self.captureDelegate = delegate

        guard session.canAddOutput(output) else {
            print("[Webcam] cannot add video output")
            return
        }
        session.addOutput(output)

        // Configure frame rate — cap at 12fps for face swap, native otherwise
        var actualFPS = hasFaceSwap ? Self.faceSwapFPS : Self.captureFPS
        do {
            try camera.lockForConfiguration()
            if hasFaceSwap {
                let dur = CMTime(value: 1, timescale: CMTimeScale(Self.faceSwapFPS))
                camera.activeVideoMinFrameDuration = dur
                camera.activeVideoMaxFrameDuration = dur
            } else if let range = camera.activeFormat.videoSupportedFrameRateRanges.first {
                camera.activeVideoMinFrameDuration = range.minFrameDuration
                camera.activeVideoMaxFrameDuration = range.minFrameDuration
                actualFPS = Int(range.maxFrameRate)
            }
            camera.unlockForConfiguration()
        } catch {
            print("[Webcam] failed to configure frame rate: \(error)")
        }

        // Header is sent from the first captured frame (actual resolution may differ from preset)
        let bridge = self
        delegate.onFirstFrame = { width, height in
            guard !bridge.headerSent else { return }
            Self.sendHeader(fd: fd, width: width, height: height, fps: actualFPS)
            bridge.headerSent = true
            print("[Webcam] capture started at \(width)x\(height)@\(actualFPS)fps\(needsEffects ? " (effects on)" : "")")
        }

        session.startRunning()
        self.captureSession = session
    }

    private func handleDisconnect() {
        if wcDebug { print("[Webcam] guest disconnected, stopping capture") }
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        connection = nil
        headerSent = false
    }
}

// MARK: - Overlay Renderer

/// Renders text and logo overlays onto BGRA pixel buffers, then converts to YUYV.
final class OverlayRenderer: @unchecked Sendable {
    private let effects: WebcamEffects
    private let timeZone: TimeZone?
    private let logoImage: CGImage?
    private let dateFormatter: DateFormatter
    private let faceSwapEngine: FaceSwapEngine?

    init(effects: WebcamEffects) {
        self.effects = effects
        self.timeZone = effects.timeZoneIdentifier.isEmpty ? nil : TimeZone(identifier: effects.timeZoneIdentifier)

        if let data = effects.logoPNGData,
           let provider = CGDataProvider(data: data as CFData),
           let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            self.logoImage = image
        } else {
            self.logoImage = nil
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "H:mm"
        if let tz = self.timeZone {
            fmt.timeZone = tz
        }
        self.dateFormatter = fmt

        // Initialize face swap engine if enabled and configured
        if effects.faceSwapActive, let imageData = effects.faceSwapImageData {
            do {
                self.faceSwapEngine = try FaceSwapEngine(sourceImageData: imageData)
                if wcDebug { print("[Webcam] face swap engine initialized") }
            } catch {
                print("[Webcam] failed to initialize face swap: \(error)")
                self.faceSwapEngine = nil
            }
        } else {
            self.faceSwapEngine = nil
        }
    }

    /// Render overlays onto a BGRA pixel buffer and return YUYV data.
    func renderOverlayAndConvert(pixelBuffer: CVPixelBuffer) -> Data {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return bgraToYUYV(pixelBuffer: pixelBuffer, width: width, height: height)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: baseAddr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return bgraToYUYV(pixelBuffer: pixelBuffer, width: width, height: height)
        }

        // CoreGraphics has origin at bottom-left, flip for top-left origin
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Face swap (applied first, before overlays)
        let faceSwapped: Bool
        if let engine = faceSwapEngine {
            faceSwapped = engine.processFrame(ctx: ctx, pixelBuffer: pixelBuffer, width: width, height: height)
        } else {
            faceSwapped = false
        }

        let fontSize = CGFloat(height) * CGFloat(effects.fontSizePercent) / 100.0
        let margin = fontSize * 1.2

        // Top-left: city & time (CNN-style stacked box)
        if !effects.cityName.isEmpty {
            drawCityTimeBox(ctx: ctx, width: width, height: height, fontSize: fontSize, margin: margin)
        }

        // Bottom-right: CNN-style name badge (offset above banner if face swap active)
        if !effects.displayName.isEmpty || !effects.displayTitle.isEmpty {
            let bannerOffset = faceSwapped ? CGFloat(height) * 0.06 : 0
            drawNameBadge(ctx: ctx, name: effects.displayName, title: effects.displayTitle,
                          width: width, height: height, fontSize: fontSize, margin: margin,
                          bottomOffset: bannerOffset)
        }

        // Top-right: logo
        if let logo = logoImage {
            let logoHeight = fontSize * 2.5
            let logoWidth = logoHeight * CGFloat(logo.width) / CGFloat(logo.height)
            let logoRect = CGRect(
                x: CGFloat(width) - logoWidth - margin,
                y: margin * 0.8,
                width: logoWidth,
                height: logoHeight
            )
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.4))
            ctx.draw(logo, in: logoRect)
            ctx.restoreGState()
        }

        // Red banner at bottom when face swap is active
        if faceSwapped {
            drawFaceSwapBanner(ctx: ctx, width: width, height: height)
        }

        return bgraToYUYV(pixelBuffer: pixelBuffer, width: width, height: height)
    }

    private func drawCityTimeBox(ctx: CGContext, width: Int, height: Int, fontSize: CGFloat, margin: CGFloat) {
        let fontName = effects.fontFamily as CFString
        let cityFontSize = fontSize * 0.75
        let timeFontSize = fontSize

        let cityFont = CTFontCreateWithName(fontName, cityFontSize, nil)
        let timeFont = CTFontCreateWithName(fontName, timeFontSize, nil)

        let cityText = effects.cityName.uppercased()
        let timeText = dateFormatter.string(from: Date())

        let cityAttrs: [NSAttributedString.Key: Any] = [
            .font: cityFont,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: timeFont,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]

        let cityLine = CTLineCreateWithAttributedString(NSAttributedString(string: cityText, attributes: cityAttrs))
        let timeLine = CTLineCreateWithAttributedString(NSAttributedString(string: timeText, attributes: timeAttrs))

        let cityBounds = CTLineGetBoundsWithOptions(cityLine, [])
        let timeBounds = CTLineGetBoundsWithOptions(timeLine, [])

        let padH = fontSize * 0.5
        let padV = fontSize * 0.2
        let boxWidth = max(cityBounds.width, timeBounds.width) + padH * 2
        let minWidth = fontSize * 4
        let finalWidth = max(boxWidth, minWidth)

        let cityRowHeight = cityFontSize + padV * 2
        let timeRowHeight = timeFontSize + padV * 2

        let boxX = margin
        let boxY = margin * 0.8
        let cornerRadius = fontSize * 0.15

        // Red background for city row
        ctx.saveGState()
        let cityRect = CGRect(x: boxX, y: boxY, width: finalWidth, height: cityRowHeight)
        let cityPath = CGMutablePath()
        cityPath.addRoundedRect(in: cityRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        ctx.addPath(cityPath)
        // Also fill the bottom corners (they'll be covered by the time row)
        ctx.addRect(CGRect(x: boxX, y: boxY + cityRowHeight - cornerRadius, width: finalWidth, height: cornerRadius))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Dark background for time row
        ctx.saveGState()
        let timeRect = CGRect(x: boxX, y: boxY + cityRowHeight, width: finalWidth, height: timeRowHeight)
        let timePath = CGMutablePath()
        timePath.addRoundedRect(in: timeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        ctx.addPath(timePath)
        // Also fill the top corners (covered by city row)
        ctx.addRect(CGRect(x: boxX, y: boxY + cityRowHeight, width: finalWidth, height: cornerRadius))
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Draw city text (centered in its row)
        ctx.saveGState()
        let cityTextX = boxX + (finalWidth - cityBounds.width) / 2
        ctx.textPosition = CGPoint(x: cityTextX, y: boxY + padV + cityFontSize * 0.15)
        CTLineDraw(cityLine, ctx)
        ctx.restoreGState()

        // Draw time text (centered in its row)
        ctx.saveGState()
        let timeTextX = boxX + (finalWidth - timeBounds.width) / 2
        ctx.textPosition = CGPoint(x: timeTextX, y: boxY + cityRowHeight + padV + timeFontSize * 0.15)
        CTLineDraw(timeLine, ctx)
        ctx.restoreGState()
    }

    /// CNN-style two-row badge: name white-on-red, title black-on-white.
    private func drawNameBadge(ctx: CGContext, name: String, title: String, width: Int, height: Int, fontSize: CGFloat, margin: CGFloat, bottomOffset: CGFloat = 0) {
        let fontName = effects.fontFamily as CFString
        let nameFont = CTFontCreateWithName(fontName, fontSize, nil)
        let titleFontSize = fontSize * 0.7
        let titleFont = CTFontCreateWithName(fontName, titleFontSize, nil)

        let hasName = !name.isEmpty
        let hasTitle = !title.isEmpty

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: CGColor(gray: 1, alpha: 1),  // white text
        ]
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: CGColor(gray: 0, alpha: 1),  // black text
        ]

        let nameLine = hasName ? CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: nameAttrs)) : nil
        let titleLine = hasTitle ? CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: titleAttrs)) : nil

        let nameBounds = nameLine.map { CTLineGetBoundsWithOptions($0, []) } ?? .zero
        let titleBounds = titleLine.map { CTLineGetBoundsWithOptions($0, []) } ?? .zero

        let padH = fontSize * 0.6
        let padV = fontSize * 0.25
        let contentWidth = max(nameBounds.width, titleBounds.width)
        let nameRowHeight = hasName ? nameBounds.height + padV * 2 : 0
        let titleRowHeight = hasTitle ? titleBounds.height + padV * 2 : 0
        let badgeWidth = max(contentWidth + padH * 2, fontSize * 4)
        let badgeHeight = nameRowHeight + titleRowHeight
        let badgeX = CGFloat(width) - badgeWidth - margin
        let badgeY = CGFloat(height) - badgeHeight - margin * 0.8 - bottomOffset

        // Red background for name row
        if hasName {
            ctx.saveGState()
            ctx.setFillColor(CGColor(red: 0.8, green: 0.05, blue: 0.05, alpha: 1))
            ctx.fill(CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: nameRowHeight))
            ctx.restoreGState()

            // White name text
            ctx.saveGState()
            ctx.textPosition = CGPoint(x: badgeX + padH, y: badgeY + padV + nameBounds.height * 0.15)
            CTLineDraw(nameLine!, ctx)
            ctx.restoreGState()
        }

        // White background for title row
        if hasTitle {
            let titleY = badgeY + nameRowHeight
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: badgeX, y: titleY, width: badgeWidth, height: titleRowHeight))
            ctx.restoreGState()

            // Black title text
            ctx.saveGState()
            ctx.textPosition = CGPoint(x: badgeX + padH, y: titleY + padV + titleBounds.height * 0.15)
            CTLineDraw(titleLine!, ctx)
            ctx.restoreGState()
        }
    }

    private func drawFaceSwapBanner(ctx: CGContext, width: Int, height: Int) {
        let bannerHeight = CGFloat(height) * 0.06
        let bannerY = CGFloat(height) - bannerHeight

        // Red background
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: bannerY, width: CGFloat(width), height: bannerHeight))

        // White text centered
        let bannerFontSize = bannerHeight * 0.55
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, bannerFontSize, nil)
        let text = "User\u{2019}s real face anonymized by Bromure.io"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let textX = (CGFloat(width) - bounds.width) / 2
        let textY = bannerY + (bannerHeight - bounds.height) / 2 + bounds.height * 0.15
        ctx.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Convert a BGRA pixel buffer to YUYV data.
    private func bgraToYUYV(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> Data {
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Data(count: width * height * 2)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let yuyvRowBytes = width * 2
        var yuyv = Data(count: yuyvRowBytes * height)

        yuyv.withUnsafeMutableBytes { yuyvPtr in
            let dst = yuyvPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let src = baseAddr.assumingMemoryBound(to: UInt8.self)

            for row in 0..<height {
                let srcRow = src + row * bytesPerRow
                let dstRow = dst + row * yuyvRowBytes

                for col in stride(from: 0, to: width, by: 2) {
                    // BGRA layout: B G R A
                    let px0 = srcRow + col * 4
                    let b0 = Int(px0[0]), g0 = Int(px0[1]), r0 = Int(px0[2])

                    let px1: UnsafePointer<UInt8>
                    let b1: Int, g1: Int, r1: Int
                    if col + 1 < width {
                        px1 = UnsafePointer(srcRow + (col + 1) * 4)
                        b1 = Int(px1[0]); g1 = Int(px1[1]); r1 = Int(px1[2])
                    } else {
                        b1 = b0; g1 = g0; r1 = r0
                    }

                    // BT.601 conversion
                    let y0 = clampU8((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8 + 16)
                    let y1 = clampU8((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8 + 16)
                    let avgR = (r0 + r1) >> 1
                    let avgG = (g0 + g1) >> 1
                    let avgB = (b0 + b1) >> 1
                    let u = clampU8((-38 * avgR - 74 * avgG + 112 * avgB + 128) >> 8 + 128)
                    let v = clampU8((112 * avgR - 94 * avgG - 18 * avgB + 128) >> 8 + 128)

                    let dstPx = dstRow + col * 2
                    dstPx[0] = y0
                    dstPx[1] = u
                    dstPx[2] = y1
                    dstPx[3] = v
                }
            }
        }

        return yuyv
    }

    @inline(__always) private func clampU8(_ val: Int) -> UInt8 {
        UInt8(max(0, min(255, val)))
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let fd: Int32
    private let onDisconnect: () -> Void
    private let overlayRenderer: OverlayRenderer?
    private var disconnected = false
    var onFirstFrame: ((_ width: Int, _ height: Int) -> Void)?
    private var headerSent = false

    init(fd: Int32, overlayRenderer: OverlayRenderer?, onDisconnect: @escaping () -> Void) {
        self.fd = fd
        self.overlayRenderer = overlayRenderer
        self.onDisconnect = onDisconnect
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !disconnected else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Send header with actual resolution on first frame
        if !headerSent {
            onFirstFrame?(width, height)
            headerSent = true
        }

        if let renderer = overlayRenderer {
            // Effects path: render overlays on BGRA, convert to YUYV
            let yuyvData = renderer.renderOverlayAndConvert(pixelBuffer: pixelBuffer)
            let frameSize = yuyvData.count
            writeFrameSize(frameSize)
            if disconnected { return }
            yuyvData.withUnsafeBytes { ptr in
                writeAll(ptr.baseAddress!, count: frameSize)
            }
        } else {
            // Direct path: send raw YUYV frames
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let rowBytes = width * 2  // YUYV = 2 bytes/pixel
            let frameSize = rowBytes * height

            writeFrameSize(frameSize)
            if disconnected { return }

            if bytesPerRow == rowBytes {
                writeAll(baseAddr, count: frameSize)
            } else {
                for row in 0..<height {
                    writeAll(baseAddr + row * bytesPerRow, count: rowBytes)
                    if disconnected { return }
                }
            }
        }
    }

    private func writeFrameSize(_ size: Int) {
        var sizeLE = UInt32(size).littleEndian
        let written = withUnsafeBytes(of: &sizeLE) { ptr in
            Darwin.write(fd, ptr.baseAddress!, 4)
        }
        if written <= 0 {
            disconnected = true
            onDisconnect()
        }
    }

    private func writeAll(_ ptr: UnsafeRawPointer, count: Int) {
        var total = 0
        while total < count {
            let n = Darwin.write(fd, ptr + total, count - total)
            if n <= 0 {
                disconnected = true
                onDisconnect()
                return
            }
            total += n
        }
    }
}

// MARK: - Listener delegate

private final class WebcamListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if wcDebug { print("[Webcam] listener: accepting connection") }
        onConnection(connection)
        return true
    }
}
