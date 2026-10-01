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
    private var guestCursor: NSCursor = .arrow
    public private(set) var nativeCursorImageCount = 0
    private var inFlight = 0
    private var redrawPending = false
    public var guestDisplayScale: Double = 1
    public var displaySizeChanged: ((Int, Int) -> Void)?
    private var resizeTask: DispatchWorkItem?
    private var pendingDisplaySize: (Int, Int)?
    public private(set) var presentedFrameCount = 0

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
        fragment float4 frame_fragment(Vertex value [[stage_in]], texture2d<float> source [[texture(0)]]) {
            constexpr sampler sample(filter::linear, address::clamp_to_edge);
            // The primary scanout is opaque; XRGB's fourth byte is padding.
            return float4(source.sample(sample, value.uv).rgb, 1.0);
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device?.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw Self.failure("Cannot import GPU display surface")
        }
        self.texture = texture
        needsDisplay = true
    }

    public func normalizedGuestPoint(_ point: NSPoint) -> (x: Double, y: Double) {
        guard let texture else {
            return (Double(point.x / max(bounds.width, 1)), Double(1 - point.y / max(bounds.height, 1)))
        }
        let scale = min(bounds.width / CGFloat(texture.width), bounds.height / CGFloat(texture.height))
        let width = CGFloat(texture.width) * scale, height = CGFloat(texture.height) * scale
        let left = (bounds.width - width) / 2, bottom = (bounds.height - height) / 2
        return (Double((point.x - left) / max(width, 1)), Double(1 - (point.y - bottom) / max(height, 1)))
    }

    public func discardFrame() { texture = nil; needsDisplay = true }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        scheduleDisplayResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        scheduleDisplayResize()
    }

    private func scheduleDisplayResize() {
        let width = Int(min(max(bounds.width * guestDisplayScale, 64), 8192))
        let height = Int(min(max(bounds.height * guestDisplayScale, 64), 8192))
        pendingDisplaySize = (width, height)
        guard resizeTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeTask = nil
            if let size = self.pendingDisplaySize {
                self.pendingDisplaySize = nil
                self.displaySizeChanged?(size.0, size.1)
            }
        }
        resizeTask = task
        // Throttle/coalesce while dragging; debounce would defer every update
        // until the drag ends and leave the guest displaying a frozen image.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0, execute: task)
    }

    public func draw(in view: MTKView) {
        if inFlight >= 3 { redrawPending = true; return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture {
            let scale = min(Double(drawable.texture.width) / Double(texture.width),
                            Double(drawable.texture.height) / Double(texture.height))
            let width = Double(texture.width) * scale, height = Double(texture.height) * scale
            encoder.setViewport(MTLViewport(originX: (Double(drawable.texture.width) - width) / 2,
                                             originY: (Double(drawable.texture.height) - height) / 2,
                                             width: width, height: height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.present(drawable)
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
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureGPUDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
