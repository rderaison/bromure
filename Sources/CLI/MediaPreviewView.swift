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
    let captureSession = AVCaptureSession()

    private var audioEngine: AVAudioEngine?
    private var levelTimer: Timer?
    private var currentCameraInput: AVCaptureDeviceInput?
    private var currentAudioDevice: AVCaptureDevice?

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
            let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async {
                nonisolated(unsafe) let s = session
                s.startRunning()
            }
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
            let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async {
                nonisolated(unsafe) let s = session
                s.stopRunning()
            }
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
        stopCamera()
        stopMicrophone()
    }
}
