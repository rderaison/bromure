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
    private var inFlight = 0
    public var guestDisplayScale: Double = 1
    public var displaySizeChanged: ((Int, Int) -> Void)?
    private var resizeTask: DispatchWorkItem?
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
            return source.sample(sample, value.uv);
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

    public func discardFrame() { texture = nil; needsDisplay = true }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        resizeTask?.cancel()
        let width = Int(min(max(view.bounds.width * guestDisplayScale, 64), 8192))
        let height = Int(min(max(view.bounds.height * guestDisplayScale, 64), 8192))
        let task = DispatchWorkItem { [weak self] in self?.displaySizeChanged?(width, height) }
        resizeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    public func draw(in view: MTKView) {
        guard inFlight < 3, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
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
                self?.inFlight -= 1
                if completed { self?.presentedFrameCount += 1 }
            }
        }
        command.commit()
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "BromureGPUDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
