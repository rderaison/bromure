@preconcurrency import AVFoundation
import SwiftUI
import SandboxEngine

/// Live camera preview + microphone level meter + speaker picker,
/// similar to what video conferencing apps show in their settings.
struct MediaPreviewView: View {
    @Binding var webcamDeviceID: String?
    @Binding var microphoneDeviceID: String?
    @Binding var speakerDeviceID: String?
    let enableWebcam: Bool
    let enableMicrophone: Bool
    var webcamEffects: WebcamEffects = WebcamEffects()

    @StateObject private var preview = MediaPreviewModel()

    var body: some View {
        VStack(spacing: 12) {
            // Camera preview
            if enableWebcam {
                ZStack {
                    CameraPreviewView(session: preview.captureSession)
                        .aspectRatio(4/3, contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    if !preview.cameraActive {
                        VStack(spacing: 4) {
                            Image(systemName: "video.slash")
                                .font(.title2)
                            Text("No camera")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Show effect overlays in the preview
                    if webcamEffects.hasAnyEffect {
                        effectOverlays
                            .scaleEffect(x: -1, y: 1)  // match the mirror flip
                    }
                }

                Picker("Camera", selection: $webcamDeviceID) {
                    Text("Default").tag(String?.none)
                    ForEach(MediaDevices.cameras()) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .onChange(of: webcamDeviceID) { _, newValue in
                    preview.switchCamera(to: newValue)
                }
            }

            // Microphone level
            if enableMicrophone {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.2))

                            RoundedRectangle(cornerRadius: 3)
                                .fill(levelColor(preview.micLevel))
                                .frame(width: geo.size.width * CGFloat(preview.micLevel))
                                .animation(.linear(duration: 0.05), value: preview.micLevel)
                        }
                    }
                    .frame(height: 6)
                }
                .frame(height: 20)

                Picker("Microphone", selection: $microphoneDeviceID) {
                    Text("Default").tag(String?.none)
                    ForEach(MediaDevices.microphones()) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .onChange(of: microphoneDeviceID) { _, newValue in
                    preview.switchMicrophone(to: newValue)
                }
            }

            // Speaker picker (always shown when audio is relevant)
            Picker("Speaker", selection: $speakerDeviceID) {
                Text("Default").tag(String?.none)
                ForEach(MediaDevices.speakers()) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
        }
        .onAppear {
            if enableWebcam { preview.startCamera(deviceID: webcamDeviceID) }
            if enableMicrophone { preview.startMicrophone(deviceID: microphoneDeviceID) }
        }
        .onDisappear {
            preview.stop()
        }
        .onChange(of: enableWebcam) { _, enabled in
            if enabled { preview.startCamera(deviceID: webcamDeviceID) }
            else { preview.stopCamera() }
        }
        .onChange(of: enableMicrophone) { _, enabled in
            if enabled { preview.startMicrophone(deviceID: microphoneDeviceID) }
            else { preview.stopMicrophone() }
        }
    }

    /// Simplified effect overlays for the settings preview.
    private var effectOverlays: some View {
        GeometryReader { geo in
            let fs = max(8, geo.size.height * CGFloat(webcamEffects.fontSizePercent) / 100)
            let m = fs * 1.2

            ZStack {
                if !webcamEffects.displayName.isEmpty || !webcamEffects.displayTitle.isEmpty {
                    NameBadge(name: webcamEffects.displayName, title: webcamEffects.displayTitle,
                              fontFamily: webcamEffects.fontFamily, fontSize: fs)
                        .padding(.trailing, m)
                        .padding(.bottom, m * 0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                if webcamEffects.faceSwapActive {
                    FaceSwapBanner(height: geo.size.height * 0.06, fontSize: max(6, geo.size.height * 0.033))
                }
            }
        }
    }

    private func levelColor(_ level: Float) -> Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .yellow }
        return .green
    }
}

// MARK: - Camera preview NSView wrapper

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.addSublayer(previewLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let previewLayer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.session = session
            previewLayer.frame = nsView.bounds
        }
    }
}

// MARK: - Preview model

@MainActor
final class MediaPreviewModel: ObservableObject {
    @Published var micLevel: Float = 0
    @Published var cameraActive = false
    @Published var processedFrame: CGImage?
    let captureSession = AVCaptureSession()

    private var audioEngine: AVAudioEngine?
    private var levelTimer: Timer?
    private var currentCameraInput: AVCaptureDeviceInput?
    private var currentAudioDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var frameDelegate: FrameProcessingDelegate?

    /// Set a frame processor for real-time video effects preview.
    /// When set, frames are captured in BGRA, processed, and published to `processedFrame`.
    func setFrameProcessor(_ processor: ((CVPixelBuffer, CGContext, Int, Int) -> Void)?) {
        captureSession.beginConfiguration()

        // Remove existing video output
        if let output = videoOutput {
            captureSession.removeOutput(output)
            videoOutput = nil
            frameDelegate = nil
        }

        if let processor {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.alwaysDiscardsLateVideoFrames = true

            let delegate = FrameProcessingDelegate(processor: processor) { [weak self] image in
                DispatchQueue.main.async { self?.processedFrame = image }
            }
            let queue = DispatchQueue(label: "io.bromure.preview-processing", qos: .userInteractive)
            output.setSampleBufferDelegate(delegate, queue: queue)
            self.frameDelegate = delegate

            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                videoOutput = output
            }
        } else {
            processedFrame = nil
        }

        captureSession.commitConfiguration()
    }

    func startCamera(deviceID: String?) {
        captureSession.beginConfiguration()
        // Remove existing input
        if let input = currentCameraInput {
            captureSession.removeInput(input)
            currentCameraInput = nil
        }

        let camera: AVCaptureDevice?
        if let deviceID, let specific = AVCaptureDevice(uniqueID: deviceID) {
            camera = specific
        } else {
            camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        }

        if let camera, let input = try? AVCaptureDeviceInput(device: camera) {
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                currentCameraInput = input
                cameraActive = true
            }
        }
        captureSession.commitConfiguration()

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    func switchCamera(to deviceID: String?) {
        startCamera(deviceID: deviceID)
    }

    func stopCamera() {
        captureSession.beginConfiguration()
        if let input = currentCameraInput {
            captureSession.removeInput(input)
            currentCameraInput = nil
        }
        captureSession.commitConfiguration()
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        cameraActive = false
    }

    func startMicrophone(deviceID: String?) {
        stopMicrophone()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Switch to specified device if needed
        if let deviceID {
            MediaDevices.setDefaultAudioInput(deviceID: deviceID)
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            guard let data = channelData, frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                sum += data[i] * data[i]
            }
            let rms = sqrt(sum / Float(frameLength))
            // Convert to 0-1 range (RMS is typically 0-0.5 for normal speech)
            let level = min(1.0, rms * 4)

            DispatchQueue.main.async {
                self?.micLevel = level
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            print("[MediaPreview] failed to start audio engine: \(error)")
        }
    }

    func switchMicrophone(to deviceID: String?) {
        startMicrophone(deviceID: deviceID)
    }

    func stopMicrophone() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micLevel = 0
    }

    func stop() {
        setFrameProcessor(nil)
        stopCamera()
        stopMicrophone()
    }
}

// MARK: - Frame processing delegate

private final class FrameProcessingDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let processor: (CVPixelBuffer, CGContext, Int, Int) -> Void
    let onFrame: (CGImage) -> Void

    init(processor: @escaping (CVPixelBuffer, CGContext, Int, Int) -> Void, onFrame: @escaping (CGImage) -> Void) {
        self.processor = processor
        self.onFrame = onFrame
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: baseAddr, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }

        // Flip for top-left origin (same as OverlayRenderer)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        processor(pixelBuffer, ctx, width, height)

        // Create CGImage from the modified pixel buffer
        if let image = ctx.makeImage() {
            onFrame(image)
        }
    }
}

// MARK: - Processed frame view

/// Displays processed CGImage frames via a CALayer for efficient 30fps rendering.
struct ProcessedFrameView: NSViewRepresentable {
    let frame: CGImage?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.contentsGravity = .resizeAspect
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.contents = frame
    }
}
