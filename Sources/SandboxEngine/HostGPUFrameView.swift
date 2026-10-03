import AppKit
import IOSurface
import MetalKit

/// Presents renderer-owned IOSurfaces on the host GPU. Place above the VM input
/// view: hit testing passes through, so keyboard/mouse routing stays with VZ.
@MainActor
public final class HostGPUFrameView: MTKView, MTKViewDelegate {
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    // Internal importer seam also lets the display harness exercise allocation failure.
    var textureImporter: (MTLDevice, MTLTextureDescriptor, IOSurface) -> MTLTexture? = {
        $0.makeTexture(descriptor: $1, iosurface: $2, plane: 0)
    }
    public private(set) var activeScanoutSize: NSSize?
    public var isHoldingResizeFrame: Bool { clearedResizeSurface != nil }
    private var guestCursor: NSCursor = .arrow
    public private(set) var nativeCursorImageCount = 0
    private var inFlight = 0
    private var redrawPending = false
    private var lastDrawTrace = ""
    private var importedFrameGeneration: UInt64 = 0
    private var diagnosticSnapshotCount = 0
    public var guestDisplayScale: Double = 1
    public var displayHeightAlignment: Int = 1
    public var hiddenTopRows = 0
    public var displaySizeChanged: ((Int, Int) -> Void)? {
        didSet { schedulePendingDisplayResize() }
    }
    private var resizeTask: DispatchWorkItem?
    private var clearedResizeTask: DispatchWorkItem?
    private var acceptingClearedResize = false
    private var clearedResizeSurface: IOSurface?
    private var pendingDisplaySize: (Int, Int)?
    private var lastDisplaySize: (Int, Int)?
    private var awaitingDisplaySize: (Int, Int)?
    private var lastRequestedDisplaySize: (Int, Int)?
    private var resizeProgressTask: DispatchWorkItem?
    private var resizeProgressExpired = false
    private var resizeRequestSequence: UInt64 = 0
    private var resizeHandoffUntil: Double = 0
    private var sharedDesktopResizeOperations: Set<UUID> = []
    /// Completed GPU submissions; this is not confirmed on-screen presentation.
    public private(set) var presentedFrameCount = 0
    public var currentFrameSize: NSSize? {
        texture.map { NSSize(width: $0.width, height: $0.height) }
    }

    public init(gpuFrame frame: NSRect) throws {
        guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else {
            throw Self.failure("Host Metal device unavailable")
        }
        let library = try gpu.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex frame_vertex(uint id [[vertex_id]]) {
            float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            Vertex value; value.position = float4(positions[id], 0, 1);
            value.uv = float2((positions[id].x + 1) * 0.5, (1 - positions[id].y) * 0.5);
            return value;
        }
        fragment float4 frame_fragment(Vertex value [[stage_in]], texture2d<float> source [[texture(0)]], constant float4 &texelBounds [[buffer(0)]]) {
            constexpr sampler sample(filter::linear, address::clamp_to_edge);
            // The primary scanout is opaque; XRGB's fourth byte is padding.
            return float4(source.sample(sample, clamp(value.uv, texelBounds.xy, texelBounds.zw)).rgb, 1.0);
        }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frame_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
        self.commands = commands
        super.init(frame: frame, device: gpu)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        presentsWithTransaction = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("Use init(gpuFrame:)") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: guestCursor) }

    public func presentCursor(_ cursor: HostGPUCursor?) {
        guard let cursor else {
            let image = NSImage(size: NSSize(width: 1, height: 1))
            guestCursor = NSCursor(image: image, hotSpot: .zero)
            window?.invalidateCursorRects(for: self)
            return
        }
        guard cursor.width > 0, cursor.height > 0, cursor.width <= 64, cursor.height <= 64,
              cursor.rgba.count == cursor.width * cursor.height * 4,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cursor.width,
                  pixelsHigh: cursor.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: cursor.width * 4, bitsPerPixel: 32),
              let data = bitmap.bitmapData else { return }
        if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") {
            let transparent = stride(from: 3, to: cursor.rgba.count, by: 4).filter { cursor.rgba[$0] == 0 }.count
            print("[GPU cursor] size=\(cursor.width)x\(cursor.height) transparent=\(transparent) corner=\(Array(cursor.rgba.prefix(4)))")
        }
        cursor.rgba.copyBytes(to: data, count: cursor.rgba.count)
        let scale = max(guestDisplayScale, 1)
        let image = NSImage(size: NSSize(width: Double(cursor.width) / scale, height: Double(cursor.height) / scale))
        image.addRepresentation(bitmap)
        guestCursor = NSCursor(image: image, hotSpot: NSPoint(x: Double(cursor.hotX) / scale, y: Double(cursor.hotY) / scale))
        nativeCursorImageCount += 1
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            guestCursor.set()
        }
    }

    public func present(_ surface: IOSurface) throws {
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 33554432, IOSurfaceGetPixelFormat(surface) == 0x42475241,
              IOSurfaceGetBytesPerRow(surface) >= width * 4,
              IOSurfaceGetAllocSize(surface) <= 268435456, IOSurfaceGetPlaneCount(surface) == 0 else {
            throw Self.failure("Invalid GPU display surface")
        }
        // Xorg clears its new front buffer before modesetting, then repaints it.
        activeScanoutSize = NSSize(width: width, height: height)
        // Keep the preceding painted frame through that short handoff. A bounded
        // fallback still displays a genuinely black new screen without another flush.
        // The progress timeout permits another request; it does not establish
        // that the guest completed this mode. Old-size clears can arrive later.
        let differsFromRequestedMode = lastRequestedDisplaySize.map { $0.0 != width || $0.1 != height } ?? false
        let resizeEligible = texture.map { !sharedDesktopResizeOperations.isEmpty || clearedResizeTask != nil || $0.width != width || $0.height != height || differsFromRequestedMode ||
            ProcessInfo.processInfo.systemUptime < resizeHandoffUntil } ?? false
        let oldWidth = min(texture?.width ?? width, width)
        let oldHeight = min(texture?.height ?? height, height)
        let excludedRows = max(hiddenTopRows, 0)
        let oldVisiblePixels = oldWidth * max(oldHeight - excludedRows, 0)
        let newVisiblePixels = width * max(height - excludedRows, 0)
        // A large enlargement can paint the exposed edges while clearing the
        // preceding screen rectangle. Restrict this additional check to that
        // known region, occupying at least a quarter of the candidate frame.
        let clearedPreviousRegion = (oldWidth < width || oldHeight < height) &&
            oldVisiblePixels > 0 && oldVisiblePixels * 4 >= newVisiblePixels
        let mostlyBlack = !acceptingClearedResize && resizeEligible &&
            (Self.isMostlyBlackResize(surface, excludingTopRows: hiddenTopRows) ||
             (clearedPreviousRegion && Self.isMostlyBlackResize(surface, excludingTopRows: hiddenTopRows,
                regionWidth: oldWidth, regionHeight: oldHeight, allowBlackCore: false)))
        if mostlyBlack {
            if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") { print("[GPU handoff] window=\(window?.windowNumber ?? -1) hold t=\(ProcessInfo.processInfo.systemUptime) size=\(width)x\(height)") }
            clearedResizeSurface = surface
            if clearedResizeTask == nil {
                let task = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.clearedResizeSurface else { return }
                    if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") { print("[GPU handoff] window=\(self.window?.windowNumber ?? -1) expire t=\(ProcessInfo.processInfo.systemUptime) size=\(IOSurfaceGetWidth(pending))x\(IOSurfaceGetHeight(pending))") }
                    self.acceptingClearedResize = true
                    defer { self.acceptingClearedResize = false }
                    try? self.present(pending)
                }
                clearedResizeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200), execute: task)
            }
            return
        }
        clearedResizeTask?.cancel()
        clearedResizeTask = nil
        clearedResizeSurface = nil
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let gpu = device, let texture = textureImporter(gpu, descriptor, surface) else {
            // An expired hold must not strand its already-expired progress
            // callback on import failure. Keep the previous painted texture.
            if resizeProgressExpired { finishDisplayResize() }
            else { schedulePendingDisplayResize() }
            print("[GPU] Cannot import display surface \(width)x\(height); retained preceding frame")
            throw Self.failure("Cannot import GPU display surface")
        }
        self.texture = texture
        importedFrameGeneration &+= 1
        if let wanted = lastRequestedDisplaySize, wanted.0 == width, wanted.1 == height {
            lastRequestedDisplaySize = nil
        }
        if resizeProgressExpired || (awaitingDisplaySize.map { $0.0 == width && $0.1 == height } ?? false) {
            finishDisplayResize()
        } else {
            schedulePendingDisplayResize()
        }
        if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames"),
           IOSurfaceLock(surface, .readOnly, nil) == 0 {
            do {
                let base = IOSurfaceGetBaseAddress(surface)
                let row = IOSurfaceGetBytesPerRow(surface)
                let pixel = base.advanced(by: (height / 2) * row + (width / 2) * 4).assumingMemoryBound(to: UInt8.self)
                print("[GPU frame] window=\(window?.windowNumber ?? -1) t=\(ProcessInfo.processInfo.systemUptime) size=\(width)x\(height) center=\(pixel[0]),\(pixel[1]),\(pixel[2]),\(pixel[3])")
                if pixel[0] < 4 && pixel[1] < 4 && pixel[2] < 4 {
                    var black = 0, nearBlack = 0, samples = 0
                    for y in stride(from: min(hiddenTopRows, height - 1), to: height, by: 8) {
                        let pixels = base.advanced(by: y * row).assumingMemoryBound(to: UInt32.self)
                        for x in stride(from: 0, to: width, by: 8) {
                            let rgb = pixels[x] & 0x00ffffff
                            samples += 1
                            if rgb == 0 { black += 1 }
                            if rgb & 0x00fcfcfc == 0 { nearBlack += 1 }
                        }
                    }
                    print("[GPU dark source] window=\(window?.windowNumber ?? -1) t=\(ProcessInfo.processInfo.systemUptime) exact=\(black)/\(samples) near=\(nearBlack)/\(samples)")
                    print("[GPU gate] window=\(window?.windowNumber ?? -1) eligible=\(resizeEligible) classified=\(mostlyBlack) fallback=\(acceptingClearedResize) activityUntil=\(resizeHandoffUntil) awaiting=\(String(describing: awaitingDisplaySize)) pending=\(String(describing: pendingDisplaySize)) bounds=\(bounds) visible=\(visibleRect) crop=\(hiddenTopRows)")
                    // Explicit developer diagnostics only: copy the exact accepted
                    // source under its read lock, then compress off the main thread.
                    if resizeEligible, nearBlack * 10 >= samples * 8, diagnosticSnapshotCount < 8,
                       let directory = ProcessInfo.processInfo.environment["BROMURE_GPU_SNAPSHOT_DIR"] {
                        diagnosticSnapshotCount += 1
                        let filename = "source-\(window?.windowNumber ?? -1)-\(importedFrameGeneration)-\(ProcessInfo.processInfo.systemUptime).png"
                        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
                        let copy = Data(bytes: base, count: row * height)
                        print("[GPU snapshot] generation=\(importedFrameGeneration) path=\(url.path)")
                        DispatchQueue.global(qos: .utility).async {
                            guard let provider = CGDataProvider(data: copy as CFData),
                                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                                        .union(.byteOrder32Little), provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent),
                                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                            try? png.write(to: url)
                        }
                    }

                }
            }
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        needsDisplay = true
    }

    public func normalizedGuestPoint(_ point: NSPoint) -> (x: Double, y: Double) {
        guard let size = activeScanoutSize else {
            return (Double(point.x / max(bounds.width, 1)), Double(1 - point.y / max(bounds.height, 1)))
        }
        // Pointer packets address the current X screen, even while presentation
        // temporarily retains an older image during a resize.
        let viewport = guestViewport(for: size)
        let content = guestContentRect(for: size)
        let x = min(max(point.x, content.minX), content.maxX)
        let y = min(max(point.y, content.minY), content.maxY)
        let crop = hiddenTopRows > 0 && visibleRect.maxY < bounds.maxY
            ? min(CGFloat(hiddenTopRows), max(size.height - 1, 0)) : 0
        // Half a source pixel keeps ABS quantization on the visible side of
        // the crop boundary, even at the maximum supported screen dimensions.
        let normalizedX = Double((x - viewport.minX) / max(viewport.width, 1))
        let normalizedY = Double(1 - (y - viewport.minY) / max(viewport.height, 1))
        return (min(max(normalizedX, 0.5 / size.width), 1 - 0.5 / size.width),
                min(max(normalizedY, (crop + 0.5) / size.height), 1 - 0.5 / size.height))
    }

    // Native chrome clips the top of this view. Anchor that clipped edge to
    // source rows, so scaling an older texture cannot reveal Chromium's toolbar.
    // Drawn pixels and active-screen pointer coordinates share this transform.
    private func guestViewport(for size: NSSize) -> NSRect {
        let visible = visibleRect
        let crop = hiddenTopRows > 0 && visible.maxY < bounds.maxY
            ? min(CGFloat(hiddenTopRows), max(size.height - 1, 0)) : 0
        let target = crop > 0 ? visible : bounds
        let scale = min(target.width / max(size.width, 1), target.height / max(size.height - crop, 1))
        let width = size.width * scale, contentHeight = (size.height - crop) * scale
        return NSRect(x: target.midX - width / 2, y: target.midY - contentHeight / 2,
                      width: width, height: size.height * scale)
    }

    func guestContentRect(for size: NSSize) -> NSRect {
        let full = guestViewport(for: size)
        let crop = hiddenTopRows > 0 && visibleRect.maxY < bounds.maxY
            ? min(CGFloat(hiddenTopRows), max(size.height - 1, 0)) : 0
        return NSRect(x: full.minX, y: full.minY, width: full.width,
                      height: full.height * (size.height - crop) / max(size.height, 1))
    }

    private static func isMostlyBlackResize(_ surface: IOSurface, excludingTopRows: Int,
                                           regionWidth: Int? = nil, regionHeight: Int? = nil,
                                           allowBlackCore: Bool = true) -> Bool {
        guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { return false }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = min(regionWidth ?? IOSurfaceGetWidth(surface), IOSurfaceGetWidth(surface))
        let height = min(regionHeight ?? IOSurfaceGetHeight(surface), IOSurfaceGetHeight(surface))
        let base = IOSurfaceGetBaseAddress(surface), row = IOSurfaceGetBytesPerRow(surface)
        // During modesetting, Xorg may repaint some UI before the page.
        // XRGB padding is not paint-completion metadata: legitimate black video
        // bars can have all four bytes zero. Use only RGB for this conservative
        // mostly-black resize heuristic; normal colored content replaces a hold.
        let mask = SIMD16<UInt32>(repeating: 0x00ffffff)
        let zero = SIMD16<UInt32>(repeating: 0)
        let vectorWidth = width - width % 16
        let firstRow = min(max(excludingTopRows, 0), height)
        guard firstRow < height else { return false }
        let pixelsInRegion = width * (height - firstRow)
        // A modeset can repaint edge strips before the body. A black central
        // region plus sparse edge paint is still a candidate; centered video
        // with black letterboxing must instead replace the held frame.
        let coloredLimit = pixelsInRegion * 3 / 10
        let coreLeft = width / 4, coreRight = width * 3 / 4
        let coreTop = firstRow + (height - firstRow) / 4
        let coreBottom = firstRow + (height - firstRow) * 3 / 4
        let corePixels = max(1, (coreRight - coreLeft) * (coreBottom - coreTop))
        var coloredBound = 0, coreColoredBound = 0
        for y in firstRow..<height {
            let pixels = base.advanced(by: y * row)
            for x in stride(from: 0, to: vectorWidth, by: 16) {
                let values = pixels.advanced(by: x * 4).loadUnaligned(as: SIMD16<UInt32>.self)
                if (values & mask) != zero {
                    coloredBound += 16
                    if y >= coreTop && y < coreBottom && x < coreRight && x + 16 > coreLeft {
                        coreColoredBound += min(x + 16, coreRight) - max(x, coreLeft)
                    }
                }
                if coloredBound > coloredLimit { return false }
            }
            let tail = pixels.assumingMemoryBound(to: UInt32.self)
            for x in vectorWidth..<width {
                if tail[x] & 0x00ffffff != 0 {
                    coloredBound += 1
                    if y >= coreTop && y < coreBottom && x >= coreLeft && x < coreRight {
                        coreColoredBound += 1
                    }
                }
            }
        }
        return coloredBound <= coloredLimit &&
            (coloredBound <= pixelsInRegion / 10 ||
             (allowBlackCore && coreRight > coreLeft && coreBottom > coreTop && coreColoredBound <= corePixels / 10))
    }

    public func discardFrame() {
        clearedResizeTask?.cancel(); clearedResizeTask = nil; clearedResizeSurface = nil
        resizeHandoffUntil = 0
        resizeProgressTask?.cancel(); resizeProgressTask = nil; awaitingDisplaySize = nil
        resizeProgressExpired = false
        resizeRequestSequence &+= 1
        lastRequestedDisplaySize = nil
        texture = nil; activeScanoutSize = nil; needsDisplay = true
        schedulePendingDisplayResize()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        scheduleDisplayResize()
    }

    /// A sibling output can resize the shared X desktop and clear this output
    /// even when this view's dimensions are unchanged. Keep the same bounded
    /// repaint policy; an existing candidate's deadline is never restarted.
    public func prepareForSharedDesktopResize() {
        resizeHandoffUntil = ProcessInfo.processInfo.systemUptime + 0.75
    }

    public func beginSharedDesktopResize() -> UUID {
        let token = UUID()
        sharedDesktopResizeOperations.insert(token)
        return token
    }

    public func endSharedDesktopResize(_ token: UUID) {
        guard sharedDesktopResizeOperations.remove(token) != nil else { return }
        prepareForSharedDesktopResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        scheduleDisplayResize()
    }

    private func scheduleDisplayResize() {
        // GTF high-refresh modes use 8-pixel horizontal character cells. Request
        // that effective width explicitly, so paint acknowledgments are exact.
        let width = Int(min(max(bounds.width * guestDisplayScale, 64), 8192)) / 8 * 8
        let alignment = max(1, min(displayHeightAlignment, 8))
        let height = Int(min(max(bounds.height * guestDisplayScale, 64), 8192)) / alignment * alignment
        if let last = lastDisplaySize, last.0 == width, last.1 == height { return }
        lastDisplaySize = (width, height)
        // Xorg can clear the old framebuffer before binding the new dimensions.
        // Scope the handoff to trusted host resize activity as well as new frames.
        resizeHandoffUntil = ProcessInfo.processInfo.systemUptime + 0.75
        pendingDisplaySize = (width, height)
        schedulePendingDisplayResize()
    }

    private func finishDisplayResize() {
        resizeProgressTask?.cancel(); resizeProgressTask = nil; awaitingDisplaySize = nil
        resizeProgressExpired = false
        resizeRequestSequence &+= 1
        schedulePendingDisplayResize()
    }

    private func schedulePendingDisplayResize() {
        guard displaySizeChanged != nil, resizeTask == nil, awaitingDisplaySize == nil,
              clearedResizeTask == nil, pendingDisplaySize != nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeTask = nil
            guard self.displaySizeChanged != nil, self.clearedResizeTask == nil else { return }
            if let size = self.pendingDisplaySize {
                self.pendingDisplaySize = nil
                self.awaitingDisplaySize = size
                self.resizeRequestSequence &+= 1
                let requestID = self.resizeRequestSequence
                self.lastRequestedDisplaySize = size
                // A coalesced request can emit after host drag activity stops.
                // Re-arm eligibility, without changing an existing candidate's deadline.
                if self.displaySizeChanged != nil {
                    self.resizeHandoffUntil = ProcessInfo.processInfo.systemUptime + 0.75
                }
                // A dark page can resemble a clear; lack of painted-frame
                // evidence must not prevent the final resize indefinitely.
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self, self.resizeRequestSequence == requestID, self.awaitingDisplaySize != nil else { return }
                    self.resizeProgressExpired = true
                    if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") {
                        print("[GPU resize progress] window=\(self.window?.windowNumber ?? -1) t=\(ProcessInfo.processInfo.systemUptime) request=\(requestID) deferred=\(self.clearedResizeTask != nil)")
                    }
                    // Let the current bounded handoff resolve before starting
                    // another modeset, which could otherwise replace its clear.
                    if self.clearedResizeTask == nil { self.finishDisplayResize() }
                }
                self.resizeProgressTask = fallback
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: fallback)
                if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") {
                    print("[GPU resize request] window=\(self.window?.windowNumber ?? -1) t=\(ProcessInfo.processInfo.systemUptime) request=\(requestID) size=\(size.0)x\(size.1)")
                }
                self.displaySizeChanged?(size.0, size.1)
            }
        }
        resizeTask = task
        // Throttle/coalesce while dragging; debounce would defer every update
        // until the drag ends and leave the guest displaying a frozen image.
        // Avoid clearing another front buffer while a prior mode is repainting.
        // Fast guests can still receive 30Hz updates; slower guests coalesce
        // intermediate sizes while the host keeps drawing its painted texture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: task)
    }

    public func draw(in view: MTKView) {
        if inFlight >= 3 { redrawPending = true; return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") {
            let source = texture.map { "\($0.width)x\($0.height)" } ?? "nil"
            let geometry = "source=\(source) drawable=\(drawable.texture.width)x\(drawable.texture.height) bounds=\(bounds) visible=\(visibleRect) crop=\(hiddenTopRows)"
            if geometry != lastDrawTrace {
                lastDrawTrace = geometry
                print("[GPU draw] window=\(window?.windowNumber ?? -1) t=\(ProcessInfo.processInfo.systemUptime) generation=\(importedFrameGeneration) holding=\(isHoldingResizeFrame) \(geometry)")
            }
        }
        if let texture {
            let viewport = guestViewport(for: NSSize(width: texture.width, height: texture.height))
            let scaleX = Double(drawable.texture.width) / max(bounds.width, 1)
            let scaleY = Double(drawable.texture.height) / max(bounds.height, 1)
            encoder.setViewport(MTLViewport(originX: viewport.minX * scaleX,
                                             originY: (bounds.height - viewport.maxY) * scaleY,
                                             width: viewport.width * scaleX, height: viewport.height * scaleY,
                                             znear: 0, zfar: 1))
            // The full-source viewport extends cropped rows above the content.
            // Scissor the fitted content too: vertical letterboxing must never
            // expose those rows inside the visible region.
            let content = guestContentRect(for: NSSize(width: texture.width, height: texture.height)).intersection(visibleRect)
            guard !content.isEmpty, !content.isNull,
                  content.minX.isFinite, content.minY.isFinite, content.maxX.isFinite, content.maxY.isFinite else {
                encoder.endEncoding(); return
            }
            let left = max(0, Int(ceil(content.minX * scaleX)))
            let top = max(0, Int(ceil((bounds.height - content.maxY) * scaleY)))
            let right = min(drawable.texture.width, Int(floor(content.maxX * scaleX)))
            let bottom = min(drawable.texture.height, Int(floor((bounds.height - content.minY) * scaleY)))
            guard right > left, bottom > top else { encoder.endEncoding(); return }
            encoder.setScissorRect(MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            let crop = hiddenTopRows > 0 && visibleRect.maxY < bounds.maxY
                ? min(hiddenTopRows, texture.height - 1) : 0
            var texelBounds = SIMD4<Float>(0.5 / Float(texture.width), (Float(crop) + 0.5) / Float(texture.height),
                                          1 - 0.5 / Float(texture.width), 1 - 0.5 / Float(texture.height))
            encoder.setFragmentBytes(&texelBounds, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        inFlight += 1
        command.addCompletedHandler { [weak self] result in
            let completed = result.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight -= 1
                if completed { self.presentedFrameCount += 1 }
                if self.redrawPending {
                    self.redrawPending = false
                    self.needsDisplay = true
                }
            }
        }
        command.commit()
        // Synchronize the drawable with AppKit's resize/layout transaction.
        // Scheduling presentation on the command buffer bypasses that ordering.
        let schedulingStart = ProcessInfo.processInfo.systemUptime
        command.waitUntilScheduled()
        if UserDefaults.standard.bool(forKey: "vm.traceGPUFrames") {
            let wait = ProcessInfo.processInfo.systemUptime - schedulingStart
            if wait > 0.005 { print("[GPU schedule wait] window=\(window?.windowNumber ?? -1) ms=\(wait * 1000)") }
        }
        drawable.present()
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureGPUDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
