import AppKit
import IOSurface
import MetalKit
// The display-only harness omits the VM session and its macOS27 runtime.
public struct HostGPUCursor { public var width, height, hotX, hotY: Int; public var rgba: Data }
@main struct Test {
    @MainActor static func surface(_ w: Int, _ h: Int, _ pixel: UInt32) -> IOSurface {
        let s = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .pixelFormat: 0x42475241])!
        for y in 0..<h {
            let p = IOSurfaceGetBaseAddress(s).advanced(by: y * IOSurfaceGetBytesPerRow(s)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w { p[x] = pixel }
        }
        return s
    }
    // Inspect the real imported Metal texture; size alone cannot detect a stale
    // delayed clear replacing a painted frame of the same dimensions.
    @MainActor static func pixel(_ view: HostGPUFrameView, y: Int = 0) -> UInt32 {
        let texture = Mirror(reflecting: view).children.first { $0.label == "texture" }!.value as! MTLTexture
        var value: UInt32 = 0
        texture.getBytes(&value, bytesPerRow: 4, from: MTLRegionMake2D(0,y,1,1), mipmapLevel: 0)
        return value
    }
    @MainActor static func wait(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let v = try HostGPUFrameView(gpuFrame: NSRect(x: 0, y: 0, width: 100, height: 100))
        try v.present(surface(64,64,0)); precondition(v.currentFrameSize == NSSize(width:64,height:64), "first boot clear must present")
        try v.present(surface(64,64,0xff0088ff))
        try v.present(surface(80,80,0)); precondition(v.currentFrameSize?.width == 64)
        wait(0.20); precondition(pixel(v) == 0); precondition(v.currentFrameSize?.width == 80, "single black candidate must expire without a flush")
        try v.present(surface(80,80,0xff0088ff))
        try v.present(surface(96,96,0)); wait(0.08)
        try v.present(surface(100,100,0)); wait(0.10)
        precondition(v.currentFrameSize?.width == 100, "repeated frames must not extend deadline; latest wins")
        try v.present(surface(120,120,0)); try v.present(surface(120,120,0xff0088ff))
        precondition(v.currentFrameSize?.width == 120); wait(0.20)
        precondition(v.currentFrameSize?.width == 120 && pixel(v) == 0xff0088ff)
        try v.present(surface(128,128,0)); v.discardFrame(); wait(0.20)
        precondition(v.currentFrameSize == nil, "reset must cancel delayed publication")
        try v.present(surface(64,64,0xff0088ff)); try v.present(surface(64,64,0))
        precondition(v.currentFrameSize?.width == 64 && pixel(v) == 0)
        try v.present(surface(64,64,0xff0088ff))
        v.setFrameSize(NSSize(width: 110, height: 110))
        try v.present(surface(64,64,0))
        precondition(pixel(v) == 0xff0088ff, "old-sized clear during trusted resize must be held")
        wait(0.20)
        precondition(pixel(v) == 0, "old-sized black candidate still has bounded expiry")
        try v.present(surface(83,84,0xff000000))
        precondition(v.currentFrameSize?.width == 64, "opaque XRGB clear must also be held")
        wait(0.20)
        precondition(v.currentFrameSize?.width == 83 && pixel(v) == 0xff000000)
        v.hiddenTopRows = 4
        try v.present(surface(64,64,0xff0088ff))
        let hiddenChrome = surface(80,80,0)
        IOSurfaceGetBaseAddress(hiddenChrome).assumingMemoryBound(to: UInt32.self)[0] = 0xffffffff
        try v.present(hiddenChrome)
        precondition(v.currentFrameSize?.width == 64, "hidden chrome must not bypass visible-page handoff")
        wait(0.20)
        precondition(v.currentFrameSize?.width == 80 && pixel(v, y: 4) == 0)
        v.hiddenTopRows = 0
        try v.present(surface(64,64,0xff0088ff))
        let partialUI = surface(80,80,0)
        for y in 0..<8 {
            let row = IOSurfaceGetBaseAddress(partialUI).advanced(by: y * IOSurfaceGetBytesPerRow(partialUI)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<8 { row[x] = 0xffffffff }
        }
        try v.present(partialUI)
        precondition(v.currentFrameSize?.width == 64, "small UI repaint must not expose cleared page")
        wait(0.20)
        precondition(v.currentFrameSize?.width == 80 && pixel(v, y: 20) == 0)
        try v.present(surface(64,64,0xff0088ff))
        let partialPaint = surface(80,80,0xff0088ff)
        for y in 20..<60 {
            let row = IOSurfaceGetBaseAddress(partialPaint).advanced(by: y * IOSurfaceGetBytesPerRow(partialPaint)).assumingMemoryBound(to: UInt32.self)
            for x in 20..<60 { row[x] = 0 }
        }
        try v.present(partialPaint)
        precondition(v.currentFrameSize?.width == 64, "cleared hole inside partially repainted frame must be held")
        wait(0.20)
        precondition(v.currentFrameSize?.width == 80 && pixel(v, y: 30) == 0xff0088ff)
        // Valid dark content may resemble a partially cleared XRGB buffer.
        // It must eventually display, even while actual resize events continue.
        v.discardFrame()
        try v.present(surface(80,80,0xff0088ff))
        let darkPage = surface(80,80,0xff080808)
        for y in 20..<40 {
            let row = IOSurfaceGetBaseAddress(darkPage).advanced(by: y * IOSurfaceGetBytesPerRow(darkPage)).assumingMemoryBound(to: UInt32.self)
            for x in 16..<32 { row[x] = 0 }
        }
        v.setFrameSize(NSSize(width: 130, height: 130))
        try v.present(darkPage)
        precondition(pixel(v) == 0xff0088ff)
        wait(0.06)
        v.setFrameSize(NSSize(width: 140, height: 140)); try v.present(darkPage)
        wait(0.06)
        v.setFrameSize(NSSize(width: 150, height: 150)); try v.present(darkPage)
        wait(0.06)
        precondition(pixel(v) == 0xff080808, "real resize events must not extend candidate deadline")
        wait(0.20)
        try v.present(surface(80,80,0xff0088ff)); try v.present(darkPage)
        precondition(pixel(v) == 0xff080808, "valid dark content at stable size must present immediately")
        let tail = surface(7,1,0xff000000)
        IOSurfaceGetBaseAddress(tail).assumingMemoryBound(to: UInt32.self)[6] = 0x000088ff
        try v.present(tail)
        precondition(v.currentFrameSize?.width == 7, "significant nonzero RGB tail must present even with alpha0")
        for (w,h) in [(5120,2948),(7680,4320)] {
            try v.present(surface(64,64,0xff0088ff))
            let blank = surface(w,h,0), start = Date()
            try v.present(blank)
            print("ZERO_SCAN \(w)x\(h) ms=\(Date().timeIntervalSince(start)*1000)")
            v.discardFrame()
        }
        print("BROMURE_FRAME_HANDOFF_PASS")
    }
}
