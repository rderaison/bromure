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
        v.guestDisplayScale = 2
        v.hiddenTopRows = 16
        try v.present(surface(64,64,0xff0088ff))
        v.setFrameSize(NSSize(width:64,height:40))
        try v.present(surface(128,80,0))
        let heldPoint = v.normalizedGuestPoint(NSPoint(x:16,y:16))
        precondition(abs(heldPoint.x - 0.25) < 0.0001 && abs(heldPoint.y - 0.6) < 0.0001,
                     "held image must not change full active screen pointer coordinates at scale2 with cropped chrome")
        let cropWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:64,height:32),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        let clipped = NSView(frame: NSRect(x:0,y:0,width:64,height:32))
        cropWindow.contentView = clipped
        let cropped = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:64,height:40))
        clipped.addSubview(cropped)
        cropWindow.orderFront(nil)
        defer { cropWindow.orderOut(nil) }
        cropped.hiddenTopRows = 16
        try cropped.present(surface(128,80,0xff0088ff))
        let cropTop = cropped.normalizedGuestPoint(NSPoint(x:32,y:32))
        precondition(abs(cropTop.x - 0.5) < 0.0001 && abs(cropTop.y - 16.5/80) < 0.0001,
                     "native clipped edge must address first visible source row")
        try cropped.present(surface(256,144,0xff0088ff))
        let oldScaledTop = cropped.normalizedGuestPoint(NSPoint(x:32,y:32))
        precondition(abs(oldScaledTop.y - 16.5/144) < 0.0001,
                     "crop stays source-anchored when view and source sizes differ")
        let wideContent = cropped.guestContentRect(for: NSSize(width:512,height:200))
        precondition(abs(wideContent.minY - 4.5) < 0.0001 && abs(wideContent.height - 23) < 0.0001,
                     "wide retained source must scissor out toolbar in top letterbox")
        try cropped.present(surface(512,200,0xff0088ff))
        let topLetterbox = cropped.normalizedGuestPoint(NSPoint(x:32,y:28.5))
        precondition(abs(topLetterbox.y - 16.5/200) < 0.0001,
                     "letterbox clicks and releases cannot target hidden toolbar")
        let tallContent = cropped.guestContentRect(for: NSSize(width:128,height:272))
        precondition(abs(tallContent.minX - 24) < 0.0001 && abs(tallContent.height - 32) < 0.0001,
                     "tall source must preserve horizontal letterboxing")
        try cropped.present(surface(128,272,0xff0088ff))
        let sideLetterbox = cropped.normalizedGuestPoint(NSPoint(x:0,y:16))
        let releasedOutside = cropped.normalizedGuestPoint(NSPoint(x:-100,y:100))
        precondition(abs(sideLetterbox.x - 0.5/128) < 0.0001 && abs(releasedOutside.x - 0.5/128) < 0.0001 &&
                     abs(releasedOutside.y - 16.5/272) < 0.0001,
                     "out-of-content points stay at visible edge; releases remain routable")
        if ProcessInfo.processInfo.environment["BROMURE_CAPTURE_CROP_TEST"] == "1" {
            for (name,w,h,crop) in [("wide",512,200,16),("upscaled",24,24,5)] {
                cropped.hiddenTopRows = crop
                let contrast = surface(w,h,0xff00ff00)
                for y in 0..<crop {
                    let row = IOSurfaceGetBaseAddress(contrast).advanced(by:y * IOSurfaceGetBytesPerRow(contrast)).assumingMemoryBound(to:UInt32.self)
                    for x in 0..<w { row[x] = 0xffff0000 }
                }
                try cropped.present(contrast); wait(0.25)
                let path = "/private/tmp/bromure-crop-\(name)-pixels.png"
                let capture = Process(); capture.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments = ["-x","-o","-l\(cropWindow.windowNumber)",path]
                try capture.run(); capture.waitUntilExit()
                precondition(capture.terminationStatus == 0, "crop pixel capture failed")
                let bitmap = NSBitmapImageRep(data:try Data(contentsOf:URL(fileURLWithPath:path)))!
                var green = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                        precondition(color.redComponent < 0.05,
                                     "hidden red toolbar must not appear or bleed at cropped edge")
                        if color.greenComponent > 0.9 { green += 1 }
                    }
                }
                precondition(green > bitmap.pixelsWide * bitmap.pixelsHigh / 4,
                             "capture must contain actual rendered green content")
                print("BROMURE_CROP_PIXELS_PASS \(name) \(path)")
            }
            cropped.hiddenTopRows = 16
        }
        cropWindow.orderOut(nil)
        try v.present(surface(128,80,0xff0088ff))
        var modes: [(Int,Int)] = []
        v.displaySizeChanged = { width,height in
            modes.append((width,height))
            try! v.present(surface(width,height,0xff0088ff))
        }
        for step in 1...50 {
            v.setFrameSize(NSSize(width:64 + step,height:40 + step)); wait(0.01)
        }
        wait(0.15)
        precondition(!modes.isEmpty && modes.count <= 22, "a resize burst must coalesce guest modesets")
        precondition(modes.last!.0 == 224 && modes.last!.1 == 180, "final effective geometry must emit after the drag stops")
        v.displaySizeChanged = nil
        v.discardFrame(); modes = []
        v.guestDisplayScale = 1
        try v.present(surface(800,600,0xff0088ff))
        v.displaySizeChanged = { modes.append(($0,$1)) }
        v.setFrameSize(NSSize(width:804,height:604)); wait(0.05)
        v.setFrameSize(NSSize(width:820,height:620))
        try v.present(surface(800,600,0xff0088ff)); wait(0.05)
        precondition(modes.count == 1, "old nearby-size paint must not acknowledge a new mode")
        try v.present(surface(800,604,0xff0088ff)); wait(0.05)
        precondition(modes.count == 2, "exact effective-size paint must release next mode")
        wait(0.35)
        v.setFrameSize(NSSize(width:840,height:640)); v.discardFrame(); wait(0.05)
        precondition(modes.last!.0 == 840 && modes.last!.1 == 640, "discard must not strand final queued geometry")
        let afterDiscard = modes.count
        v.setFrameSize(NSSize(width:860,height:660)); wait(0.70)
        precondition(modes.count == afterDiscard, "canceled old fallback must not acknowledge the replacement mode")
        try v.present(surface(840,640,0xff0088ff)); wait(0.05)
        precondition(modes.last!.0 == 856 && modes.last!.1 == 660)
        v.displaySizeChanged = nil
        let queued = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        queued.guestDisplayScale = 1
        try queued.present(surface(800,600,0xff0088ff))
        var queuedModes: [(Int,Int)] = []
        queued.displaySizeChanged = { queuedModes.append(($0,$1)) }
        queued.setFrameSize(NSSize(width:816,height:616)); wait(0.05)
        queued.setFrameSize(NSSize(width:832,height:632)); wait(1.08)
        precondition(queuedModes.count == 2, "queued mode must emit after the first progress deadline")
        try queued.present(surface(800,600,0))
        precondition(pixel(queued) == 0xff0088ff && queued.isHoldingResizeFrame,
                     "late emitted mode must protect an old-size clear after host drag activity expires")
        try queued.present(surface(832,632,0xff0088ff)); wait(1.25)
        precondition(pixel(queued) == 0xff0088ff, "healthy queued mode must cancel delayed old-size clear")
        queued.displaySizeChanged = nil
        let heldResize = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        try heldResize.present(surface(800,600,0xff0088ff))
        var heldModes: [(Int,Int)] = []
        heldResize.displaySizeChanged = { heldModes.append(($0,$1)) }
        heldResize.setFrameSize(NSSize(width:816,height:616)); wait(0.05)
        try heldResize.present(surface(800,600,0))
        heldResize.setFrameSize(NSSize(width:832,height:632)); wait(1.05)
        precondition(heldModes.count == 1 && heldResize.isHoldingResizeFrame,
                     "progress fallback cannot start another mode during an anchored handoff")
        wait(0.25)
        precondition(heldModes.count == 2 && heldModes.last!.0 == 832 && pixel(heldResize) == 0,
                     "bounded black fallback still progresses the queued final mode")
        heldResize.displaySizeChanged = nil
        let failedImport = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        try failedImport.present(surface(800,600,0xff0088ff))
        var failedModes: [(Int,Int)] = []
        failedImport.displaySizeChanged = { failedModes.append(($0,$1)) }
        failedImport.setFrameSize(NSSize(width:816,height:616)); wait(0.05)
        try failedImport.present(surface(800,600,0))
        failedImport.setFrameSize(NSSize(width:832,height:632)); wait(1.05)
        failedImport.textureImporter = { _,_,_ in nil }
        wait(0.25)
        precondition(failedModes.count == 2 && pixel(failedImport) == 0xff0088ff && !failedImport.isHoldingResizeFrame,
                     "failed import after expired progress must retain paint and drain final size without another frame")
        failedImport.displaySizeChanged = nil; failedImport.discardFrame()
        let scheduledHold = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        try scheduledHold.present(surface(800,600,0xff0088ff))
        var scheduledModes: [(Int,Int)] = []
        scheduledHold.displaySizeChanged = { scheduledModes.append(($0,$1)) }
        scheduledHold.setFrameSize(NSSize(width:816,height:616)); wait(0.05)
        scheduledHold.setFrameSize(NSSize(width:832,height:632))
        try scheduledHold.present(surface(816,616,0xff0088ff)) // queues B
        try scheduledHold.present(surface(816,616,0)) // hold begins before B executes
        wait(0.05)
        precondition(scheduledModes.count == 1 && scheduledHold.isHoldingResizeFrame,
                     "a newly-started clear must park an already scheduled next mode")
        try scheduledHold.present(surface(816,616,0xff0088ff)); wait(0.05)
        precondition(scheduledModes.count == 2 && scheduledModes.last!.0 == 832,
                     "resolving parked hold must emit latest size without another callback")
        scheduledHold.displaySizeChanged = nil
        let lateMode = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        lateMode.guestDisplayScale = 1
        try lateMode.present(surface(800,600,0xff0088ff))
        lateMode.displaySizeChanged = { _,_ in }
        lateMode.setFrameSize(NSSize(width:816,height:616)); wait(1.60)
        try lateMode.present(surface(800,600,0xff0088ff))
        try lateMode.present(surface(800,600,0))
        precondition(pixel(lateMode) == 0xff0088ff, "old-mode clear after progress timeout must remain eligible for bounded protection")
        wait(1.25)
        precondition(pixel(lateMode) == 0, "a failed mode request must not indefinitely hide legitimate old-mode black content")
        try lateMode.present(surface(800,600,0xff0088ff)); try lateMode.present(surface(800,600,0))
        try lateMode.present(surface(816,616,0xff0088ff)); wait(1.25)
        try lateMode.present(surface(816,616,0))
        precondition(pixel(lateMode) == 0, "requested mode at stable geometry must bypass resize protection")
        lateMode.discardFrame(); try lateMode.present(surface(800,600,0xff0088ff)); try lateMode.present(surface(800,600,0))
        precondition(pixel(lateMode) == 0, "reset must clear remembered mode eligibility")
        lateMode.displaySizeChanged = nil
        let latePaint = try HostGPUFrameView(gpuFrame: NSRect(x:0,y:0,width:800,height:600))
        latePaint.guestDisplayScale = 1; latePaint.displaySizeChanged = { _,_ in }
        try latePaint.present(surface(800,600,0xff0088ff))
        latePaint.setFrameSize(NSSize(width:816,height:616)); wait(1.60)
        try latePaint.present(surface(800,600,0xff0088ff)); try latePaint.present(surface(800,600,0))
        wait(0.30); try latePaint.present(surface(816,616,0xff0088ff)); wait(0.95)
        precondition(pixel(latePaint) == 0xff0088ff, "late healthy requested mode must immediately replace old-size clear and cancel its timer")
        latePaint.setFrameSize(NSSize(width:832,height:632)); wait(1.60)
        for shade in [UInt32(8),UInt32(9)] {
            let darkAnimation = surface(816,616,0xff000000)
            IOSurfaceGetBaseAddress(darkAnimation).assumingMemoryBound(to:UInt32.self)[0] = 0xff000000 | shade
            try latePaint.present(darkAnimation); wait(1.25)
            precondition(pixel(latePaint) == 0xff000000 | shade, "legitimate dark animation must progress even when requested geometry never arrives")
        }
        latePaint.discardFrame(); latePaint.displaySizeChanged = nil
        modes = []
        v.discardFrame(); v.guestDisplayScale = 2
        v.displaySizeChanged = { modes.append(($0,$1)) }
        v.setFrameSize(NSSize(width:130,height:90)); wait(0.05)
        v.setFrameSize(NSSize(width:160,height:120)); wait(0.10)
        precondition(modes.count == 1, "one mode must remain outstanding while the guest repaints")
        try v.present(surface(256,180,0xff0088ff)); wait(0.05)
        precondition(modes.count == 2 && modes.last!.0 == 320 && modes.last!.1 == 240,
                     "painted frame must release the latest queued geometry")
        v.setFrameSize(NSSize(width:170,height:130)); wait(1.10)
        precondition(modes.last!.0 == 336 && modes.last!.1 == 260, "fallback must release final geometry even without paint evidence")
        v.displaySizeChanged = nil
        v.discardFrame(); v.hiddenTopRows = 0; v.guestDisplayScale = 1
        try v.present(surface(64,64,0xff0088ff))
        v.setFrameSize(NSSize(width:120,height:100))
        wait(0.70)
        try v.present(surface(64,64,0))
        wait(0.10)
        try v.present(surface(64,64,0))
        precondition(pixel(v) == 0xff0088ff, "activity-window expiry must not bypass an already anchored candidate hold")
        wait(1.15)
        precondition(pixel(v) == 0, "candidate still expires from its first arrival")
        v.discardFrame()
        try v.present(surface(64,64,0)); precondition(v.currentFrameSize == NSSize(width:64,height:64), "first boot clear must present")
        try v.present(surface(64,64,0xff0088ff))
        try v.present(surface(80,80,0)); precondition(v.currentFrameSize?.width == 64)
        wait(1.25); precondition(pixel(v) == 0); precondition(v.currentFrameSize?.width == 80, "single black candidate must expire without a flush")
        try v.present(surface(80,80,0xff0088ff))
        try v.present(surface(96,96,0)); wait(0.30)
        try v.present(surface(100,100,0)); wait(0.95)
        precondition(v.currentFrameSize?.width == 100, "repeated frames must not extend deadline; latest wins")
        try v.present(surface(120,120,0)); try v.present(surface(120,120,0xff0088ff))
        precondition(v.currentFrameSize?.width == 120); wait(1.25)
        precondition(v.currentFrameSize?.width == 120 && pixel(v) == 0xff0088ff)
        try v.present(surface(128,128,0)); v.discardFrame(); wait(1.25)
        precondition(v.currentFrameSize == nil, "reset must cancel delayed publication")
        try v.present(surface(64,64,0xff0088ff)); try v.present(surface(64,64,0))
        precondition(v.currentFrameSize?.width == 64 && pixel(v) == 0)
        try v.present(surface(64,64,0xff0088ff))
        v.setFrameSize(NSSize(width: 110, height: 110))
        try v.present(surface(64,64,0))
        precondition(pixel(v) == 0xff0088ff, "old-sized clear during trusted resize must be held")
        wait(1.25)
        precondition(pixel(v) == 0, "old-sized black candidate still has bounded expiry")
        try v.present(surface(83,84,0xff000000))
        precondition(v.currentFrameSize?.width == 64, "opaque XRGB clear must also be held")
        wait(1.25)
        precondition(v.currentFrameSize?.width == 83 && pixel(v) == 0xff000000)
        v.hiddenTopRows = 4
        try v.present(surface(64,64,0xff0088ff))
        let hiddenChrome = surface(80,80,0)
        IOSurfaceGetBaseAddress(hiddenChrome).assumingMemoryBound(to: UInt32.self)[0] = 0xffffffff
        try v.present(hiddenChrome)
        precondition(v.currentFrameSize?.width == 64, "hidden chrome must not bypass visible-page handoff")
        wait(1.25)
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
        wait(1.25)
        precondition(v.currentFrameSize?.width == 80 && pixel(v, y: 20) == 0)
        try v.present(surface(64,64,0xff0088ff))
        let partialPaint = surface(80,80,0xff0088ff)
        for y in 20..<60 {
            let row = IOSurfaceGetBaseAddress(partialPaint).advanced(by: y * IOSurfaceGetBytesPerRow(partialPaint)).assumingMemoryBound(to: UInt32.self)
            for x in 20..<60 { row[x] = 0 }
        }
        try v.present(partialPaint)
        precondition(v.currentFrameSize?.width == 80, "a black region in mostly painted XRGB is valid content")
        wait(1.25)
        precondition(v.currentFrameSize?.width == 80 && pixel(v, y: 30) == 0xff0088ff)
        // Valid mostly-black content may resemble a cleared XRGB buffer.
        // It must eventually display, even while actual resize events continue.
        v.discardFrame()
        try v.present(surface(80,80,0xff0088ff))
        let darkPage = surface(80,80,0xff000000)
        IOSurfaceGetBaseAddress(darkPage).assumingMemoryBound(to:UInt32.self)[0] = 0xff080808
        v.setFrameSize(NSSize(width: 130, height: 130))
        try v.present(darkPage)
        precondition(pixel(v) == 0xff0088ff)
        wait(0.42)
        v.setFrameSize(NSSize(width: 140, height: 140)); try v.present(darkPage)
        wait(0.42)
        v.setFrameSize(NSSize(width: 150, height: 150)); try v.present(darkPage)
        wait(0.42)
        precondition(pixel(v) == 0xff080808, "real resize events must not extend candidate deadline")
        wait(1.25)
        try v.present(surface(80,80,0xff0088ff)); try v.present(darkPage)
        precondition(pixel(v) == 0xff080808, "valid dark content at stable size must present immediately")
        for generation in 1...3 {
            let shade = UInt32(8 + generation)
            let animatedPixel = 0xff000000 | shade | (shade << 8) | (shade << 16)
            let animation = surface(80,80,0xff000000)
            IOSurfaceGetBaseAddress(animation).assumingMemoryBound(to:UInt32.self)[0] = animatedPixel
            for step in 1...4 {
                v.setFrameSize(NSSize(width:200 + generation * 10 + step,height:200))
                try v.present(animation); wait(0.32)
            }
            precondition(pixel(v) == animatedPixel, "continuous dark animation must progress across successive anchored deadlines")
        }
        wait(1.25)
        for padding: UInt32 in [0,128,255] {
            v.discardFrame()
            try v.present(surface(64,64,0xff0088ff))
            try v.present(surface(80,80,padding << 24))
            precondition(v.currentFrameSize?.width == 64, "X padding must not change the mostly-black decision")
            let video = surface(80,80,padding << 24)
            for y in 20..<60 {
                let row = IOSurfaceGetBaseAddress(video).advanced(by:y * IOSurfaceGetBytesPerRow(video)).assumingMemoryBound(to:UInt32.self)
                for x in 0..<80 { row[x] = (padding << 24) | 0x0088ff }
            }
            try v.present(video)
            precondition(v.currentFrameSize?.width == 80 && pixel(v,y:30) & 0x00ffffff == 0x0088ff,
                         "colored video with zero-padded black bars must replace the clear immediately")
            wait(1.25)
            precondition(pixel(v,y:30) & 0x00ffffff == 0x0088ff, "canceled clear must not overwrite video")
        }
        v.discardFrame()
        try v.present(surface(128,128,0xff0088ff))
        let edgePaint = surface(160,160,0xff000000)
        for y in 0..<160 {
            let row = IOSurfaceGetBaseAddress(edgePaint).advanced(by:y * IOSurfaceGetBytesPerRow(edgePaint)).assumingMemoryBound(to:UInt32.self)
            for x in 136..<160 { row[x] = 0xff0088ff }
        }
        try v.present(edgePaint)
        precondition(v.currentFrameSize?.width == 128, "15 percent painted edge must not expose an unpainted central page")
        wait(1.25)
        precondition(v.currentFrameSize?.width == 160 && pixel(v,y:80) == 0xff000000,
                     "legitimate black center with colored edge must progress at anchored deadline")
        v.discardFrame()
        try v.present(surface(128,128,0xff0088ff))
        let centeredVideo = surface(160,160,0xff000000)
        for y in 64..<96 {
            let row = IOSurfaceGetBaseAddress(centeredVideo).advanced(by:y * IOSurfaceGetBytesPerRow(centeredVideo)).assumingMemoryBound(to:UInt32.self)
            for x in 16..<144 { row[x] = 0xff0088ff }
        }
        try v.present(centeredVideo)
        precondition(v.currentFrameSize?.width == 160, "centered painted video covering16 percent must present immediately")
        for (width,height,blackWidth,blackHeight) in [(2472,1676,2328,1578),(2680,1800,2528,1702)] {
            let capturedLayout = surface(width,height,0xffffffff)
            for y in 0..<blackHeight {
                let row = IOSurfaceGetBaseAddress(capturedLayout).advanced(by:y * IOSurfaceGetBytesPerRow(capturedLayout)).assumingMemoryBound(to:UInt32.self)
                for x in 0..<blackWidth { row[x] = 0xff000000 }
            }
            v.discardFrame(); v.hiddenTopRows = 172
            try v.present(surface(1920,1316,0xff0088ff))
            try v.present(capturedLayout)
            precondition(pixel(v) == 0xff0088ff, "captured right/bottom edge-strip layout must retain painted body during resize")
            wait(1.25)
            precondition(v.currentFrameSize?.width == CGFloat(width) && pixel(v,y:300) == 0xff000000,
                         "an identical legitimate dark pane with white edges must display at deadline")
            wait(1.1)
            try v.present(surface(width,height,0xff0088ff)); try v.present(capturedLayout)
            precondition(pixel(v,y:300) == 0xff000000, "captured dark-pane layout must display immediately at stable geometry")
        }
        v.hiddenTopRows = 0
        v.discardFrame(); v.hiddenTopRows = 172
        try v.present(surface(1984,1358,0xff0088ff))
        let largeJump = surface(2824,1878,0xffffffff)
        for y in 0..<1358 {
            let row = IOSurfaceGetBaseAddress(largeJump).advanced(by:y * IOSurfaceGetBytesPerRow(largeJump)).assumingMemoryBound(to:UInt32.self)
            for x in 0..<1984 { row[x] = 0xff000000 }
        }
        try v.present(largeJump)
        precondition(v.currentFrameSize?.width == 1984, "large painted expansion must not expose a cleared preceding screen region")
        wait(1.25)
        precondition(v.currentFrameSize?.width == 2824 && pixel(v,y:300) == 0xff000000,
                     "legitimate dark previous-region layout must retain bounded progress")
        v.hiddenTopRows = 0
        for (width,height) in [(120,80),(80,120),(64,64)] {
            v.discardFrame(); try v.present(surface(160,160,0xff0088ff))
            try v.present(surface(width,height,0xff000000))
            precondition(v.currentFrameSize?.width == 160, "shrinking or changing aspect must retain valid preceding content through a clear")
            try v.present(surface(width,height,0xff0088ff)); wait(1.25)
            precondition(pixel(v) == 0xff0088ff, "paint after aspect change must cancel old delayed clear")
        }
        v.discardFrame(); try v.present(surface(64,64,0xff0088ff))
        let tinyIntersection = surface(512,512,0xffffffff)
        for y in 0..<64 {
            let row = IOSurfaceGetBaseAddress(tinyIntersection).advanced(by:y * IOSurfaceGetBytesPerRow(tinyIntersection)).assumingMemoryBound(to:UInt32.self)
            for x in 0..<64 { row[x] = 0xff000000 }
        }
        try v.present(tinyIntersection)
        precondition(v.currentFrameSize?.width == 512, "a tiny cleared corner is insufficient to delay a substantially painted enlargement")
        v.discardFrame(); v.hiddenTopRows = 172
        try v.present(surface(128,128,0xff0088ff))
        let emptyCroppedOverlap = surface(128,256,0xffffffff)
        for y in 0..<128 {
            let row = IOSurfaceGetBaseAddress(emptyCroppedOverlap).advanced(by:y * IOSurfaceGetBytesPerRow(emptyCroppedOverlap)).assumingMemoryBound(to:UInt32.self)
            for x in 0..<128 { row[x] = 0xff000000 }
        }
        try v.present(emptyCroppedOverlap)
        precondition(v.currentFrameSize?.height == 256, "fully cropped old region cannot count as meaningful cleared content")
        v.hiddenTopRows = 0
        v.discardFrame(); try v.present(surface(160,120,0xff0088ff))
        let aspectSwap = surface(120,160,0xffffffff)
        for y in 0..<120 {
            let row = IOSurfaceGetBaseAddress(aspectSwap).advanced(by:y * IOSurfaceGetBytesPerRow(aspectSwap)).assumingMemoryBound(to:UInt32.self)
            for x in 0..<120 { row[x] = 0xff000000 }
        }
        try v.present(aspectSwap)
        precondition(v.currentFrameSize?.width == 160, "mixed shrinking/expanding axes must protect the shared old region")
        try v.present(surface(120,160,0xff0088ff)); wait(1.25)
        precondition(pixel(v) == 0xff0088ff, "mixed-axis repaint must cancel its clear")
        for width in [8,24] {
            v.discardFrame()
            try v.present(surface(64,64,0xff0088ff))
            let paintedEdges = surface(width,8,0xffffffff)
            for y in 0..<8 {
                let row = IOSurfaceGetBaseAddress(paintedEdges).advanced(by:y * IOSurfaceGetBytesPerRow(paintedEdges)).assumingMemoryBound(to:UInt32.self)
                for x in width / 4..<width * 3 / 4 { row[x] = 0xff000000 }
            }
            try v.present(paintedEdges)
            precondition(v.currentFrameSize?.width == CGFloat(width), "scalar tails must enforce overall colored budget even with a black center")
        }
        let tail = surface(7,1,0xff000000)
        IOSurfaceGetBaseAddress(tail).assumingMemoryBound(to: UInt32.self)[6] = 0x000088ff
        try v.present(tail)
        precondition(v.currentFrameSize?.width == 7, "significant nonzero RGB tail must present even with alpha0")
        let sibling = try HostGPUFrameView(gpuFrame: NSRect(x: 0, y: 0, width: 64, height: 64))
        sibling.discardFrame()
        try sibling.present(surface(64,64,0xff0088ff))
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff000000, "stationary dark content must display outside topology changes")
        try sibling.present(surface(64,64,0xff0088ff))
        sibling.prepareForSharedDesktopResize()
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff0088ff, "shared desktop clear must preserve the stationary sibling's painted pixels")
        try sibling.present(surface(64,64,0xff449900))
        wait(1.3)
        precondition(pixel(sibling) == 0xff449900, "sibling repaint must cancel the held clear")
        sibling.prepareForSharedDesktopResize()
        try sibling.present(surface(64,64,0xff000000))
        for _ in 0..<13 { sibling.prepareForSharedDesktopResize(); wait(0.1) }
        precondition(pixel(sibling) == 0xff000000, "repeated shared topology activity must not extend a dark candidate's deadline")
        sibling.discardFrame()
        try sibling.present(surface(64,64,0xff0088ff))
        let delayed = sibling.beginSharedDesktopResize()
        wait(1.0)
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff0088ff, "delayed guest modeset must hold a stationary sibling while the operation is in flight")
        wait(1.3)
        precondition(pixel(sibling) == 0xff000000, "an in-flight operation must not extend the candidate deadline")
        sibling.endSharedDesktopResize(delayed)
        wait(0.8)
        try sibling.present(surface(64,64,0xff0088ff))
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff000000, "completed shared operation must release eligibility")
        let first = sibling.beginSharedDesktopResize(), second = sibling.beginSharedDesktopResize()
        sibling.endSharedDesktopResize(first)
        wait(0.8)
        try sibling.present(surface(64,64,0xff0088ff))
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff0088ff, "ending one shared operation must preserve another operation's eligibility")
        sibling.endSharedDesktopResize(second)
        wait(1.3)
        try sibling.present(surface(64,64,0xff0088ff))
        sibling.endSharedDesktopResize(second)
        sibling.endSharedDesktopResize(UUID())
        try sibling.present(surface(64,64,0xff000000))
        precondition(pixel(sibling) == 0xff000000, "duplicate or unknown operation completion must not rearm a finished handoff")
        print("BROMURE_SHARED_SIBLING_HANDOFF_PASS")
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
