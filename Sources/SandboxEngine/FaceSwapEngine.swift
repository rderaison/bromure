import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import OnnxRuntimeBindings
import Vision

private let fsDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

// MARK: - Error types

public enum FaceSwapError: LocalizedError {
    case invalidSourceImage
    case noFaceDetected
    case modelNotFound(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceImage: "Could not decode the source face image"
        case .noFaceDetected: "No face detected in the source image"
        case .modelNotFound(let name): "Model not found: \(name)"
        case .downloadFailed(let reason): "Model download failed: \(reason)"
        }
    }
}

// MARK: - FaceSwapEngine

/// Face swap using InsightFace ONNX models, matching the FaceFusion pipeline:
///   1. ArcFace w600k_r50 for source face embedding (112×112, RGB [-1,1])
///   2. emap matrix (from model's 'buff2fs' initializer) to transform embedding
///   3. inswapper_128 for per-frame swap (128×128, RGB [0,1])
///   4. Inverse-warp + elliptical blend to composite back
public final class FaceSwapEngine: @unchecked Sendable {

    // MARK: - Model management

    private static let arcfaceModelName = "w600k_r50.onnx"
    private static let inswapperModelName = "inswapper_128.onnx"

    private static let arcfaceDownloadURL = URL(string:
        "https://huggingface.co/public-data/insightface/resolve/main/models/buffalo_l/w600k_r50.onnx")!
    private static let inswapperDownloadURL = URL(string:
        "https://huggingface.co/hacksider/deep-live-cam/resolve/main/inswapper_128.onnx")!

    public static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bromure/Models", isDirectory: true)
    }

    public static var modelsExist: Bool {
        let dir = modelsDirectory
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(arcfaceModelName).path)
            && fm.fileExists(atPath: dir.appendingPathComponent(inswapperModelName).path)
    }

    /// Download both ONNX models. Progress callback reports 0.0...1.0 (each model is 50%).
    public static func downloadModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try await downloadFile(
            from: arcfaceDownloadURL,
            to: dir.appendingPathComponent(arcfaceModelName),
            progressOffset: 0, progressScale: 0.5, progress: progress
        )
        try await downloadFile(
            from: inswapperDownloadURL,
            to: dir.appendingPathComponent(inswapperModelName),
            progressOffset: 0.5, progressScale: 0.5, progress: progress
        )
        progress(1.0)
    }

    private static func downloadFile(
        from url: URL, to destination: URL,
        progressOffset: Double, progressScale: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if fsDebug { print("[FaceSwap] downloading \(url.lastPathComponent)") }

        let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: DownloadProgressDelegate { fraction in
            progress(progressOffset + fraction * progressScale)
        })

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FaceSwapError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent)")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
        if fsDebug { print("[FaceSwap] saved \(destination.lastPathComponent)") }
    }

    // MARK: - Instance

    private let env: ORTEnv
    private let arcfaceSession: ORTSession
    private let inswapperSession: ORTSession
    private let sourceEmbedding: [Float]  // emap-transformed latent

    // ArcFace alignment template (112×112 coordinate space)
    private static let arcfaceTemplate: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),   // left eye
        CGPoint(x: 73.5318, y: 51.5014),   // right eye
        CGPoint(x: 56.0252, y: 71.7366),   // nose tip
        CGPoint(x: 41.5493, y: 92.3655),   // left mouth corner
        CGPoint(x: 70.7299, y: 92.2041),   // right mouth corner
    ]

    // Inswapper template (128×128 coordinate space).
    // InsightFace: for 128px mode, x += 8.0 (centering offset), y unchanged.
    // FaceFusion 'arcface_128' normalized coords × 128 produce the same result.
    private static let inswapperTemplate: [CGPoint] = [
        CGPoint(x: 46.2946, y: 51.6963),   // 38.2946 + 8
        CGPoint(x: 81.5318, y: 51.5014),   // 73.5318 + 8
        CGPoint(x: 64.0252, y: 71.7366),   // 56.0252 + 8
        CGPoint(x: 49.5493, y: 92.3655),   // 41.5493 + 8
        CGPoint(x: 78.7299, y: 92.2041),   // 70.7299 + 8
    ]

    /// Create an engine with the given source face image.
    public init(sourceImageData: Data) throws {
        guard Self.modelsExist else {
            throw FaceSwapError.modelNotFound("Models not downloaded")
        }

        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env

        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(.all)

        // Use CoreML EP → dispatches to Neural Engine on Apple Silicon
        // Set BROMURE_NO_COREML=1 to disable (for debugging)
        if ORTIsCoreMLExecutionProviderAvailable() &&
           ProcessInfo.processInfo.environment["BROMURE_NO_COREML"] == nil {
            let coremlOpts = ORTCoreMLExecutionProviderOptions()
            coremlOpts.enableOnSubgraphs = true
            try opts.appendCoreMLExecutionProvider(with: coremlOpts)
            print("[FaceSwap] CoreML EP enabled (Neural Engine)")
        } else {
            print("[FaceSwap] using CPU execution provider")
        }

        let arcfacePath = Self.modelsDirectory.appendingPathComponent(Self.arcfaceModelName).path
        let inswapperPath = Self.modelsDirectory.appendingPathComponent(Self.inswapperModelName).path

        self.arcfaceSession = try ORTSession(env: env, modelPath: arcfacePath, sessionOptions: opts)
        self.inswapperSession = try ORTSession(env: env, modelPath: inswapperPath, sessionOptions: opts)

        // Compute source face embedding
        guard let cgImage = Self.cgImageFromData(sourceImageData) else {
            throw FaceSwapError.invalidSourceImage
        }

        let landmarks = try Self.detectFiveLandmarks(in: cgImage)
        print("[FaceSwap] source landmarks: \(landmarks.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " "))")
        // ArcFace: 112×112, RGB, [-1, 1] normalization
        let aligned = try Self.alignFace(from: cgImage, landmarks: landmarks, template: Self.arcfaceTemplate, size: 112)
        let normedEmbedding = try Self.runArcFace(session: arcfaceSession, alignedFace: aligned)

        // Extract emap ('buff2fs') from inswapper model and transform embedding:
        //   latent = normalize(normed_embedding @ emap)
        guard let emap = Self.extractEmap(from: inswapperPath) else {
            throw FaceSwapError.modelNotFound("Could not extract emap (buff2fs) from inswapper model")
        }

        let dim = normedEmbedding.count  // 512
        let emapCols = emap.count / dim
        guard emapCols > 0, emap.count == dim * emapCols else {
            throw FaceSwapError.modelNotFound("emap size \(emap.count) not divisible by embedding dim \(dim)")
        }
        print("[FaceSwap] emap: \(dim)×\(emapCols)")
        var latent = Self.matmul(normedEmbedding, emap, m: 1, k: dim, n: emapCols)
        let norm = sqrt(latent.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<latent.count { latent[i] /= norm }
        }

        self.sourceEmbedding = latent
        print("[FaceSwap] engine ready (\(sourceEmbedding.count)-dim latent)")
    }

    // MARK: - Per-frame processing

    private var swapCount = 0
    private var useNeg1to1 = false  // auto-detected from first inference

    @discardableResult
    public func processFrame(ctx: CGContext, pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard let frameLandmarks = try? detectFiveLandmarks(in: pixelBuffer, width: width, height: height) else {
            return false
        }

        guard let transform = Self.estimateSimilarityTransform(from: frameLandmarks, to: Self.inswapperTemplate) else {
            return false
        }

        guard let alignedPixels = extractAlignedFace(pixelBuffer: pixelBuffer, width: width, height: height, transform: transform, cropSize: 128) else {
            return false
        }

        // Inswapper input: RGB NCHW (try [0,1] first; if output is [-1,1] we switch)
        let inputTensor = useNeg1to1 ?
            Self.bgraToNCHW_RGB_neg1to1(alignedPixels, size: 128) :
            Self.bgraToNCHW_RGB_01(alignedPixels, size: 128)

        guard let swappedNCHW = try? runInswapper(target: inputTensor) else {
            return false
        }

        // Auto-detect output range on first frame, then lock in
        if swapCount == 0 {
            let minVal = swappedNCHW.min() ?? 0
            let maxVal = swappedNCHW.max() ?? 0
            let mean = swappedNCHW.reduce(0, +) / Float(swappedNCHW.count)
            print("[FaceSwap] output range: min=\(minVal) max=\(maxVal) mean=\(mean)")
            if minVal < -0.5 {
                useNeg1to1 = true
                print("[FaceSwap] detected [-1,1] range — switching input+output normalization")
            }
        }

        // Convert output NCHW → BGRA using detected range
        var swappedBGRA = useNeg1to1
            ? Self.nchwRGB_neg1to1_toBGRA(swappedNCHW, size: 128)
            : Self.nchwRGB01_toBGRA(swappedNCHW, size: 128)


        // Color correction — match lighting/skin tone to target face
        Self.transferColor(from: alignedPixels, to: &swappedBGRA, size: 128, strength: 0.6)

        // Bake soft elliptical alpha into pixels, then composite via CGContext
        Self.applyAlphaMask(&swappedBGRA, size: 128)
        let inverse = transform.inverted()
        drawSwappedFace(ctx: ctx, bgra: swappedBGRA, size: 128, transform: inverse)

        swapCount += 1

        return true
    }

    // MARK: - Face detection

    private static func detectFiveLandmarks(in image: CGImage) throws -> [CGPoint] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        try handler.perform([request])

        guard let face = request.results?.first, let lm = face.landmarks else {
            throw FaceSwapError.noFaceDetected
        }

        return extractFivePoints(from: lm, boundingBox: face.boundingBox,
                                 imageWidth: image.width, imageHeight: image.height)
    }

    private func detectFiveLandmarks(in pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> [CGPoint] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        try handler.perform([request])

        guard let face = request.results?.first, let lm = face.landmarks else {
            throw FaceSwapError.noFaceDetected
        }

        return Self.extractFivePoints(from: lm, boundingBox: face.boundingBox,
                                      imageWidth: width, imageHeight: height)
    }

    /// Extract 5 keypoints matching InsightFace's convention:
    ///   [left_eye_center, right_eye_center, nose_tip, left_mouth_corner, right_mouth_corner]
    ///
    /// Vision gives landmark *regions* (multiple points per feature). We need specific points:
    /// - Eyes: pupil if available, otherwise region centroid
    /// - Nose: the TIP (bottom-most point of noseCrest), NOT the region centroid
    /// - Mouth: outer lip corners (first and midpoint of outerLips contour)
    private static func extractFivePoints(
        from landmarks: VNFaceLandmarks2D, boundingBox bbox: CGRect,
        imageWidth: Int, imageHeight: Int
    ) -> [CGPoint] {
        func toImageCoords(_ normalizedInBBox: CGPoint) -> CGPoint {
            // Vision: bbox and landmarks use bottom-left origin, normalize to [0,1]
            let imgX = (bbox.origin.x + normalizedInBBox.x * bbox.width) * CGFloat(imageWidth)
            let imgY = (1.0 - (bbox.origin.y + normalizedInBBox.y * bbox.height)) * CGFloat(imageHeight)
            return CGPoint(x: imgX, y: imgY)
        }

        func regionCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint {
            guard let region, region.pointCount > 0 else { return .zero }
            let pts = region.normalizedPoints
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
            return CGPoint(x: cx, y: cy)
        }

        // Eyes: use pupil if available (single point, most accurate), else region centroid
        let leftEye: CGPoint
        if let pupil = landmarks.leftPupil, pupil.pointCount > 0 {
            let p = pupil.normalizedPoints[0]
            leftEye = toImageCoords(CGPoint(x: p.x, y: p.y))
        } else {
            leftEye = toImageCoords(regionCenter(landmarks.leftEye))
        }

        let rightEye: CGPoint
        if let pupil = landmarks.rightPupil, pupil.pointCount > 0 {
            let p = pupil.normalizedPoints[0]
            rightEye = toImageCoords(CGPoint(x: p.x, y: p.y))
        } else {
            rightEye = toImageCoords(regionCenter(landmarks.rightEye))
        }

        // Nose: use the BOTTOM-MOST point of noseCrest (= nose tip).
        // Vision's noseCrest goes from the bridge down to the tip.
        // In Vision's bottom-left coords, the tip has the LOWEST y value.
        // Fallback: bottom-most point of the nose region.
        let nose: CGPoint
        if let crest = landmarks.noseCrest, crest.pointCount > 0 {
            // Lowest y in Vision coords = nose tip (bottom of face)
            let tip = crest.normalizedPoints.min(by: { $0.y < $1.y })!
            nose = toImageCoords(CGPoint(x: tip.x, y: tip.y))
        } else if let noseRegion = landmarks.nose, noseRegion.pointCount > 0 {
            let tip = noseRegion.normalizedPoints.min(by: { $0.y < $1.y })!
            nose = toImageCoords(CGPoint(x: tip.x, y: tip.y))
        } else {
            nose = toImageCoords(regionCenter(landmarks.nose))
        }

        // Mouth corners: first point = left corner, midpoint = right corner
        let leftMouth: CGPoint
        let rightMouth: CGPoint
        if let lips = landmarks.outerLips, lips.pointCount >= 2 {
            let pts = lips.normalizedPoints
            leftMouth = toImageCoords(CGPoint(x: pts[0].x, y: pts[0].y))
            let mid = lips.pointCount / 2
            rightMouth = toImageCoords(CGPoint(x: pts[mid].x, y: pts[mid].y))
        } else {
            leftMouth = toImageCoords(regionCenter(landmarks.outerLips))
            rightMouth = leftMouth
        }

        return [leftEye, rightEye, nose, leftMouth, rightMouth]
    }

    // MARK: - Face alignment

    static func estimateSimilarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = src.count

        var sumSxDx: CGFloat = 0, sumSyDy: CGFloat = 0
        var sumSxDy: CGFloat = 0, sumSyDx: CGFloat = 0
        var sumSxSx: CGFloat = 0, sumSySy: CGFloat = 0
        var sumSx: CGFloat = 0, sumSy: CGFloat = 0
        var sumDx: CGFloat = 0, sumDy: CGFloat = 0

        for i in 0..<n {
            let sx = src[i].x, sy = src[i].y
            let dx = dst[i].x, dy = dst[i].y
            sumSxDx += sx * dx; sumSyDy += sy * dy
            sumSxDy += sx * dy; sumSyDx += sy * dx
            sumSxSx += sx * sx; sumSySy += sy * sy
            sumSx += sx; sumSy += sy; sumDx += dx; sumDy += dy
        }

        let nf = CGFloat(n)
        let denom = sumSxSx + sumSySy - (sumSx * sumSx + sumSy * sumSy) / nf
        guard abs(denom) > 1e-10 else { return nil }

        let a = (sumSxDx + sumSyDy - (sumSx * sumDx + sumSy * sumDy) / nf) / denom
        let b = (sumSxDy - sumSyDx - (sumSx * sumDy - sumSy * sumDx) / nf) / denom
        let tx = (sumDx - a * sumSx + b * sumSy) / nf
        let ty = (sumDy - b * sumSx - a * sumSy) / nf

        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Align source face via manual pixel sampling (top-left coords throughout).
    private static func alignFace(from image: CGImage, landmarks: [CGPoint], template: [CGPoint], size: Int) throws -> [Float] {
        guard let transform = estimateSimilarityTransform(from: landmarks, to: template) else {
            throw FaceSwapError.noFaceDetected
        }
        let inverse = transform.inverted()

        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= Self.maxImageDimension, h <= Self.maxImageDimension else {
            throw FaceSwapError.invalidSourceImage
        }
        let bytesPerRow = w * 4
        var srcPixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let ctx = CGContext(
            data: &srcPixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FaceSwapError.invalidSourceImage
        }

        // Default CGContext (y-up) + ctx.draw already stores image with top at bitmap row 0.
        // Do NOT flip — flipping would invert the image in the bitmap, causing wrong sampling.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var aligned = [UInt8](repeating: 0, count: size * size * 4)
        for ay in 0..<size {
            for ax in 0..<size {
                let src = CGPoint(x: CGFloat(ax) + 0.5, y: CGFloat(ay) + 0.5).applying(inverse)
                let sx = Int(src.x), sy = Int(src.y)
                guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }

                let srcOff = (sy * w + sx) * 4
                let dstOff = (ay * size + ax) * 4
                aligned[dstOff + 0] = srcPixels[srcOff + 0]  // R
                aligned[dstOff + 1] = srcPixels[srcOff + 1]  // G
                aligned[dstOff + 2] = srcPixels[srcOff + 2]  // B
                aligned[dstOff + 3] = 255
            }
        }

        // ArcFace: RGB, [-1, 1] normalization
        return rgbaToNCHW_RGB_arcface(aligned, size: size)
    }

    // MARK: - ONNX inference

    private static func runArcFace(session: ORTSession, alignedFace: [Float]) throws -> [Float] {
        let inputData = NSMutableData(bytes: alignedFace, length: alignedFace.count * MemoryLayout<Float>.size)
        let inputTensor = try ORTValue(
            tensorData: inputData,
            elementType: .float,
            shape: [1, 3, 112, 112]
        )

        let outputs = try session.run(
            withInputs: ["input.1": inputTensor],
            outputNames: Set(try session.outputNames()),
            runOptions: nil
        )

        guard let outputValue = outputs.values.first else {
            throw FaceSwapError.noFaceDetected
        }

        let outputData = try outputValue.tensorData() as Data
        let count = outputData.count / MemoryLayout<Float>.size
        var embedding = [Float](repeating: 0, count: count)
        _ = outputData.withUnsafeBytes { ptr in
            memcpy(&embedding, ptr.baseAddress!, outputData.count)
        }

        // L2 normalize
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<embedding.count { embedding[i] /= norm }
        }

        return embedding
    }

    private func runInswapper(target: [Float]) throws -> [Float] {
        let targetData = NSMutableData(bytes: target, length: target.count * MemoryLayout<Float>.size)
        let targetTensor = try ORTValue(
            tensorData: targetData,
            elementType: .float,
            shape: [1, 3, 128, 128]
        )

        let sourceData = NSMutableData(bytes: sourceEmbedding, length: sourceEmbedding.count * MemoryLayout<Float>.size)
        let sourceTensor = try ORTValue(
            tensorData: sourceData,
            elementType: .float,
            shape: [1, sourceEmbedding.count as NSNumber]
        )

        let inputNames = try inswapperSession.inputNames()
        let outputNames = try inswapperSession.outputNames()

        let inputs: [String: ORTValue]
        if inputNames.count >= 2 {
            inputs = [inputNames[0]: targetTensor, inputNames[1]: sourceTensor]
        } else {
            inputs = [inputNames[0]: targetTensor]
        }

        let outputs = try inswapperSession.run(
            withInputs: inputs,
            outputNames: Set(outputNames),
            runOptions: nil
        )

        guard let outputValue = outputs.values.first else {
            throw FaceSwapError.noFaceDetected
        }

        let outputData = try outputValue.tensorData() as Data
        let count = outputData.count / MemoryLayout<Float>.size
        var result = [Float](repeating: 0, count: count)
        _ = outputData.withUnsafeBytes { ptr in
            memcpy(&result, ptr.baseAddress!, outputData.count)
        }

        return result
    }

    // MARK: - Pixel format conversions

    /// RGBA → NCHW RGB [-1, 1] for ArcFace (w600k_r50).
    /// Matches: cv2.dnn.blobFromImage(img, 1.0/127.5, size, (127.5,127.5,127.5), swapRB=True)
    private static func rgbaToNCHW_RGB_arcface(_ pixels: [UInt8], size: Int) -> [Float] {
        let channelSize = size * size
        var nchw = [Float](repeating: 0, count: 3 * channelSize)

        for i in 0..<channelSize {
            let srcIdx = i * 4  // RGBA
            nchw[0 * channelSize + i] = Float(pixels[srcIdx + 0]) / 127.5 - 1.0  // R
            nchw[1 * channelSize + i] = Float(pixels[srcIdx + 1]) / 127.5 - 1.0  // G
            nchw[2 * channelSize + i] = Float(pixels[srcIdx + 2]) / 127.5 - 1.0  // B
        }

        return nchw
    }

    /// BGRA → NCHW RGB [-1, 1]. Matches: (pixel / 127.5) - 1.0
    static func bgraToNCHW_RGB_neg1to1(_ bgraPixels: [UInt8], size: Int) -> [Float] {
        let channelSize = size * size
        var nchw = [Float](repeating: 0, count: 3 * channelSize)
        for i in 0..<channelSize {
            let srcIdx = i * 4
            nchw[0 * channelSize + i] = Float(bgraPixels[srcIdx + 2]) / 127.5 - 1.0  // R
            nchw[1 * channelSize + i] = Float(bgraPixels[srcIdx + 1]) / 127.5 - 1.0  // G
            nchw[2 * channelSize + i] = Float(bgraPixels[srcIdx + 0]) / 127.5 - 1.0  // B
        }
        return nchw
    }

    /// BGRA → NCHW RGB [0, 1] for inswapper_128.
    /// Matches: cv2.dnn.blobFromImage(img, 1.0/255.0, size, (0,0,0), swapRB=True)
    static func bgraToNCHW_RGB_01(_ bgraPixels: [UInt8], size: Int) -> [Float] {
        let channelSize = size * size
        var nchw = [Float](repeating: 0, count: 3 * channelSize)

        for i in 0..<channelSize {
            let srcIdx = i * 4  // BGRA
            nchw[0 * channelSize + i] = Float(bgraPixels[srcIdx + 2]) / 255.0  // R
            nchw[1 * channelSize + i] = Float(bgraPixels[srcIdx + 1]) / 255.0  // G
            nchw[2 * channelSize + i] = Float(bgraPixels[srcIdx + 0]) / 255.0  // B
        }

        return nchw
    }

    /// NCHW RGB [-1, 1] → BGRA. Matches: ((output + 1) / 2 * 255).clip(0,255)
    static func nchwRGB_neg1to1_toBGRA(_ nchw: [Float], size: Int) -> [UInt8] {
        let channelSize = size * size
        var bgra = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<channelSize {
            let dstIdx = i * 4
            bgra[dstIdx + 0] = UInt8(clamping: Int((nchw[2 * channelSize + i] + 1.0) * 127.5))  // B
            bgra[dstIdx + 1] = UInt8(clamping: Int((nchw[1 * channelSize + i] + 1.0) * 127.5))  // G
            bgra[dstIdx + 2] = UInt8(clamping: Int((nchw[0 * channelSize + i] + 1.0) * 127.5))  // R
            bgra[dstIdx + 3] = 255
        }
        return bgra
    }

    /// NCHW RGB [0, 1] → BGRA. Matches: (output.clip(0,1) * 255).astype(uint8)
    static func nchwRGB01_toBGRA(_ nchw: [Float], size: Int) -> [UInt8] {
        let channelSize = size * size
        var bgra = [UInt8](repeating: 255, count: size * size * 4)

        for i in 0..<channelSize {
            let dstIdx = i * 4
            bgra[dstIdx + 0] = UInt8(clamping: Int(min(max(nchw[2 * channelSize + i], 0), 1) * 255))  // B
            bgra[dstIdx + 1] = UInt8(clamping: Int(min(max(nchw[1 * channelSize + i], 0), 1) * 255))  // G
            bgra[dstIdx + 2] = UInt8(clamping: Int(min(max(nchw[0 * channelSize + i], 0), 1) * 255))  // R
            bgra[dstIdx + 3] = 255
        }

        return bgra
    }

    // MARK: - Warp & composite

    private func extractAlignedFace(
        pixelBuffer: CVPixelBuffer, width: Int, height: Int,
        transform: CGAffineTransform, cropSize: Int
    ) -> [UInt8]? {
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bufferSize = CVPixelBufferGetDataSize(pixelBuffer)
        let src = baseAddr.assumingMemoryBound(to: UInt8.self)

        let inverse = transform.inverted()
        var crop = [UInt8](repeating: 0, count: cropSize * cropSize * 4)

        for cy in 0..<cropSize {
            for cx in 0..<cropSize {
                let pt = CGPoint(x: CGFloat(cx) + 0.5, y: CGFloat(cy) + 0.5).applying(inverse)
                let sx = Int(pt.x)
                let sy = Int(pt.y)

                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }

                let srcOff = sy * bytesPerRow + sx * 4
                guard srcOff >= 0, srcOff + 3 < bufferSize else { continue }

                let dstOff = (cy * cropSize + cx) * 4
                crop[dstOff + 0] = src[srcOff + 0]  // B
                crop[dstOff + 1] = src[srcOff + 1]  // G
                crop[dstOff + 2] = src[srcOff + 2]  // R
                crop[dstOff + 3] = 255               // A
            }
        }

        return crop
    }

    /// Draw the swapped face via CGContext. The BGRA pixels must already have
    /// premultiplied alpha baked in (via applyAlphaMask) for soft-edge compositing.
    private func drawSwappedFace(
        ctx: CGContext, bgra: [UInt8], size: Int, transform: CGAffineTransform
    ) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let swappedImage = CGImage(
                  width: size, height: size,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return }

        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(swappedImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.restoreGState()
    }

    /// Bake a soft elliptical alpha mask into BGRA pixels (premultiplied).
    /// Uses a small fully-opaque core with wide feathering to avoid the "painted mask" look.
    private static func applyAlphaMask(_ bgra: inout [UInt8], size: Int) {
        let cx = Float(size) * 0.5, cy = Float(size) * 0.5
        // Smaller ellipse (nose/eyes/mouth region only), much wider feather
        let rx = Float(size) * 0.35
        let ry = Float(size) * 0.40
        let feather: Float = 0.45  // very wide transition zone

        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) + 0.5 - cx) / rx
                let dy = (Float(y) + 0.5 - cy) / ry
                let dist = sqrt(dx * dx + dy * dy)

                let alpha: Float
                if dist <= 1.0 - feather {
                    alpha = 1.0
                } else if dist < 1.0 + feather {
                    let t = (dist - (1.0 - feather)) / (2.0 * feather)
                    alpha = 0.5 + 0.5 * cos(t * .pi)
                } else {
                    alpha = 0.0
                }

                let off = (y * size + x) * 4
                bgra[off + 0] = UInt8(clamping: Int(Float(bgra[off + 0]) * alpha))
                bgra[off + 1] = UInt8(clamping: Int(Float(bgra[off + 1]) * alpha))
                bgra[off + 2] = UInt8(clamping: Int(Float(bgra[off + 2]) * alpha))
                bgra[off + 3] = UInt8(clamping: Int(alpha * 255.0))
            }
        }
    }

    // MARK: - Color correction

    /// Transfer color statistics (mean/std per channel) from the target face crop
    /// to the swapped face so skin tone and lighting match.
    /// strength 0.0 = no correction, 1.0 = full correction.
    private static func transferColor(from target: [UInt8], to swapped: inout [UInt8], size: Int, strength: Float = 0.3) {
        let n = size * size
        // Compute mean and std for each BGR channel
        var tMean = [Float](repeating: 0, count: 3)
        var sMean = [Float](repeating: 0, count: 3)
        let nf = Float(n)

        for i in 0..<n {
            let off = i * 4
            for c in 0..<3 {
                tMean[c] += Float(target[off + c])
                sMean[c] += Float(swapped[off + c])
            }
        }
        for c in 0..<3 { tMean[c] /= nf; sMean[c] /= nf }

        var tStd = [Float](repeating: 0, count: 3)
        var sStd = [Float](repeating: 0, count: 3)
        for i in 0..<n {
            let off = i * 4
            for c in 0..<3 {
                let td = Float(target[off + c]) - tMean[c]
                let sd = Float(swapped[off + c]) - sMean[c]
                tStd[c] += td * td
                sStd[c] += sd * sd
            }
        }
        for c in 0..<3 {
            tStd[c] = max(sqrt(tStd[c] / nf), 1.0)
            sStd[c] = max(sqrt(sStd[c] / nf), 1.0)
        }

        // Apply: out = (swapped - sMean) * (tStd/sStd) + tMean
        // Blend with original to avoid over-correction
        let blend: Float = strength
        for i in 0..<n {
            let off = i * 4
            for c in 0..<3 {
                let original = Float(swapped[off + c])
                let corrected = (original - sMean[c]) * (tStd[c] / sStd[c]) + tMean[c]
                let blended = original * (1.0 - blend) + corrected * blend
                swapped[off + c] = UInt8(clamping: Int(min(max(blended, 0), 255)))
            }
        }
    }


    // MARK: - Emap extraction

    /// Extract the emap matrix ('buff2fs') from the inswapper ONNX model.
    ///
    /// The emap is stored as an ONNX graph initializer that no computation node references.
    /// onnxruntime removes it during optimization, so we extract it directly from the file.
    ///
    /// Strategy: binary-search for the protobuf-encoded name "buff2fs" in the file, then
    /// locate the containing TensorProto and parse ALL its data fields.  The tensor data
    /// may live in `float_data` (field 4, packed) which has a *lower* field number than
    /// `name` (field 8), so it appears *before* the name in the binary.  We therefore
    /// need the full TensorProto range — not just a forward scan from the name.
    private static func extractEmap(from modelPath: String) -> [Float]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: modelPath), options: .mappedIfSafe) else {
            print("[FaceSwap] emap: could not read model file")
            return nil
        }

        // 1. Find the byte offset of the name "buff2fs" in the file.
        let needle = Data([0x42, 0x07, 0x62, 0x75, 0x66, 0x66, 0x32, 0x66, 0x73])
        guard let nameRange = data.range(of: needle) else {
            print("[FaceSwap] emap: 'buff2fs' not found in model (\(data.count) bytes)")
            return nil
        }
        let nameOffset = nameRange.lowerBound
        print("[FaceSwap] emap: found 'buff2fs' at byte \(nameOffset)")

        // 2. Walk ModelProto → GraphProto → initializers to find the TensorProto
        //    that *contains* that byte offset, then parse it fully.
        if let floats = extractEmapViaHierarchy(data: data, nameOffset: nameOffset) {
            return floats
        }

        print("[FaceSwap] emap: hierarchical parse failed, trying backward scan")

        // 3. Fallback: scan backward from name for a large float_data / raw_data block.
        return extractEmapBackwardScan(data: data, nameOffset: nameOffset)
    }

    /// Walk ModelProto(field 7) → GraphProto(field 5 repeated) to find the TensorProto
    /// whose byte range contains `nameOffset`, then extract its float data.
    private static func extractEmapViaHierarchy(data: Data, nameOffset: Int) -> [Float]? {
        var top = ProtoScanner(data: data)

        // ModelProto: skip to field 7 (graph)
        while let (field, wireType) = top.readTag() {
            if field == 7 && wireType == 2 {
                guard let graphRange = top.readLengthDelimitedRange() else {
                    print("[FaceSwap] emap/hier: bad graph length")
                    return nil
                }
                print("[FaceSwap] emap/hier: graph at \(graphRange.lowerBound)..<\(graphRange.upperBound)")

                // GraphProto: scan all field 5 (initializer) entries
                var graph = ProtoScanner(data: data, offset: graphRange.lowerBound, end: graphRange.upperBound)
                while let (gf, gw) = graph.readTag() {
                    if gf == 5 && gw == 2 {
                        guard let tensorRange = graph.readLengthDelimitedRange() else { continue }
                        // Does this TensorProto contain our name?
                        if tensorRange.contains(nameOffset) {
                            print("[FaceSwap] emap/hier: tensor at \(tensorRange.lowerBound)..<\(tensorRange.upperBound) (\(tensorRange.count) bytes)")
                            return parseTensorFloats(data: data, range: tensorRange)
                        }
                    } else {
                        guard graph.skip(wireType: gw) else {
                            print("[FaceSwap] emap/hier: skip failed at graph field \(gf) wire \(gw)")
                            return nil
                        }
                    }
                }
                print("[FaceSwap] emap/hier: no initializer contains name offset \(nameOffset)")
                return nil
            }
            guard top.skip(wireType: wireType) else {
                print("[FaceSwap] emap/hier: skip failed at model field \(field) wire \(wireType) offset \(top.offset)")
                return nil
            }
        }
        print("[FaceSwap] emap/hier: graph field not found")
        return nil
    }

    /// Parse a TensorProto and return its float data from whichever field stores it.
    private static func parseTensorFloats(data: Data, range: Range<Int>) -> [Float]? {
        var scanner = ProtoScanner(data: data, offset: range.lowerBound, end: range.upperBound)
        var floatDataRange: Range<Int>?   // field 4 (packed repeated float)
        var rawDataRange: Range<Int>?     // field 13 (bytes)
        var dataType: Int?                // field 2

        while let (field, wireType) = scanner.readTag() {
            switch (field, wireType) {
            case (2, 0):  // data_type (int32 as varint)
                if let v = scanner.readVarint() { dataType = Int(v) }
            case (4, 2):  // float_data (packed repeated float)
                floatDataRange = scanner.readLengthDelimitedRange()
            case (13, 2): // raw_data (bytes)
                rawDataRange = scanner.readLengthDelimitedRange()
            default:
                guard scanner.skip(wireType: wireType) else { break }
            }
        }

        print("[FaceSwap] emap/tensor: data_type=\(dataType ?? -1) float_data=\(floatDataRange?.count ?? 0)B raw_data=\(rawDataRange?.count ?? 0)B")

        // Prefer raw_data, fall back to float_data
        if let r = rawDataRange, !r.isEmpty {
            return extractFloats(data: data, range: r, dataType: dataType ?? 1)
        }
        if let r = floatDataRange, !r.isEmpty {
            return extractFloats(data: data, range: r, dataType: 1)  // float_data is always float32
        }
        print("[FaceSwap] emap/tensor: no data fields found")
        return nil
    }

    /// Max emap size: 512×512 in float32 or float16 (+ margin). Rejects suspiciously large tensors.
    private static let maxEmapBytes = 512 * 512 * MemoryLayout<Float>.size * 2

    /// Read floats from a byte range, handling float32 and float16 data types.
    private static func extractFloats(data: Data, range: Range<Int>, dataType: Int) -> [Float]? {
        guard range.count > 0, range.count <= maxEmapBytes else {
            print("[FaceSwap] emap: rejected tensor data \(range.count) bytes (limit \(maxEmapBytes))")
            return nil
        }
        if dataType == 10 {
            // FLOAT16 — convert to float32
            let count = range.count / 2
            var floats = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { ptr in
                let src = ptr.baseAddress!.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt16.self)
                for i in 0..<count {
                    floats[i] = float16ToFloat32(src[i])
                }
            }
            print("[FaceSwap] emap: converted \(count) float16 values")
            return floats
        }

        // FLOAT32
        let count = range.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { ptr in
            let src = ptr.baseAddress!.advanced(by: range.lowerBound)
            _ = floats.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, src, range.count)
            }
        }
        print("[FaceSwap] emap: extracted \(count) float32 values")
        return floats
    }

    private static func float16ToFloat32(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) & 1
        let exp  = UInt32(h >> 10) & 0x1F
        let frac = UInt32(h) & 0x3FF
        if exp == 0 {
            if frac == 0 { return sign == 1 ? -0.0 : 0.0 }
            // Subnormal
            var f = Float(frac) / 1024.0 * pow(2.0, -14.0)
            if sign == 1 { f = -f }
            return f
        }
        if exp == 0x1F {
            return frac == 0 ? (sign == 1 ? -.infinity : .infinity) : .nan
        }
        let bits = (sign << 31) | ((exp - 15 + 127) << 23) | (frac << 13)
        return Float(bitPattern: bits)
    }

    /// Fallback: scan backward from name position for a large data block.
    private static func extractEmapBackwardScan(data: Data, nameOffset: Int) -> [Float]? {
        // float_data tag = (4<<3)|2 = 0x22, raw_data tag = (13<<3)|2 = 0x6A
        // Search backward for either tag followed by a varint encoding length > 50000
        let searchStart = max(0, nameOffset - 2 * 1024 * 1024)

        for tag: UInt8 in [0x22, 0x6A] {
            var pos = nameOffset - 1
            while pos > searchStart {
                if data[pos] == tag {
                    var scanner = ProtoScanner(data: data, offset: pos + 1, end: nameOffset)
                    if let len = scanner.readVarint(), len > 50000 {
                        let dataStart = scanner.offset
                        let dataEnd = dataStart + Int(len)
                        guard dataEnd <= data.count else { pos -= 1; continue }
                        let range = dataStart..<dataEnd
                        print("[FaceSwap] emap/backward: found tag 0x\(String(tag, radix: 16)) at \(pos), \(len) bytes")
                        return extractFloats(data: data, range: range, dataType: 1)
                    }
                }
                pos -= 1
            }
        }
        print("[FaceSwap] emap/backward: no large data block found")
        return nil
    }

    private static func matmul(_ a: [Float], _ b: [Float], m: Int, k: Int, n: Int) -> [Float] {
        var result = [Float](repeating: 0, count: m * n)
        for i in 0..<m {
            for j in 0..<n {
                var sum: Float = 0
                for p in 0..<k {
                    sum += a[i * k + p] * b[p * n + j]
                }
                result[i * n + j] = sum
            }
        }
        return result
    }

    // MARK: - Helpers

    // MARK: - Image decoding (security hardened)

    /// Max accepted image data size (50 MB). Rejects suspiciously large blobs early
    /// before passing them to ImageIO decoders.
    private static let maxImageDataSize = 50 * 1024 * 1024

    /// Max decoded pixel dimension. Prevents memory exhaustion from decompression bombs
    /// (e.g. a tiny PNG that decompresses to 100000×100000 pixels).
    private static let maxImageDimension = 4096

    /// Decode image data of any format (PNG, JPEG, HEIC, TIFF, …) into a CGImage.
    /// Downscales to max 1024px and applies EXIF orientation — we only need enough
    /// resolution to detect face landmarks and crop a 112×112 aligned face.
    private static func cgImageFromData(_ data: Data) -> CGImage? {
        // Reject oversized blobs before touching ImageIO
        guard data.count > 0, data.count <= maxImageDataSize else {
            print("[FaceSwap] cgImageFromData: rejected (\(data.count) bytes, limit \(maxImageDataSize))")
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            print("[FaceSwap] cgImageFromData: CGImageSourceCreate failed (\(data.count) bytes)")
            return nil
        }

        // Check declared dimensions before decoding to catch decompression bombs
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            if pw > maxImageDimension || ph > maxImageDimension || pw <= 0 || ph <= 0 {
                print("[FaceSwap] cgImageFromData: rejected dimensions \(pw)×\(ph) (limit \(maxImageDimension))")
                return nil
            }
        }

        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // apply EXIF orientation
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return thumb
        }

        // Fallback: full-size decode (only reached if thumbnail creation fails)
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Minimal protobuf scanner

private struct ProtoScanner {
    let data: Data
    var offset: Int
    let end: Int

    init(data: Data, offset: Int = 0, end: Int? = nil) {
        self.data = data
        self.offset = offset
        self.end = end ?? data.count
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard offset < end else { return nil }
        guard let tag = readVarint() else { return nil }
        return (field: Int(tag >> 3), wireType: Int(tag & 7))
    }

    mutating func readLengthDelimitedRange() -> Range<Int>? {
        guard let len = readVarint() else { return nil }
        let start = offset
        let rangeEnd = start + Int(len)
        guard rangeEnd <= end else { return nil }
        offset = rangeEnd
        return start..<rangeEnd
    }

    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1: offset += 8; return offset <= end
        case 2:
            guard let len = readVarint() else { return false }
            offset += Int(len); return offset <= end
        case 5: offset += 4; return offset <= end
        default: return false
        }
    }
}

// MARK: - Download progress delegate

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        // Upload delegate — not used for downloads.
    }
}

