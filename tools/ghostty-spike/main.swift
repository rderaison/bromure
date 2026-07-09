// Phase 0 acceptance spike: prove GhosttyKit can host N concurrent surfaces
// and survive rapid surface create/free cycles (the known-risky teardown
// path). Not shipped — built ad hoc by tools/ghostty-spike/run.sh.
//
// Exit 0 = 4 surfaces ran + soak passed without a crash.

import AppKit
import GhosttyKit

let GRID = 2               // 2x2 surfaces
let SOAK_CYCLES = 50       // rapid create/free cycles
let RUN_SECONDS = 5.0      // let the grid render before the soak

var appHandle: ghostty_app_t?

func makeRuntime() -> ghostty_runtime_config_s {
    var rt = ghostty_runtime_config_s()
    rt.wakeup_cb = { _ in
        DispatchQueue.main.async { if let a = appHandle { ghostty_app_tick(a) } }
    }
    rt.action_cb = { _, _, _ in false }
    rt.read_clipboard_cb = { _, _, _ in false }
    rt.confirm_read_clipboard_cb = { _, _, _, _ in }
    rt.write_clipboard_cb = { _, _, _, _, _ in }
    rt.close_surface_cb = { _, _ in }
    return rt
}

func makeSurface(app: ghostty_app_t, view: NSView, command: String) -> ghostty_surface_t? {
    var cfg = ghostty_surface_config_new()
    cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
    cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(view).toOpaque()))
    cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    return command.withCString { c in
        cfg.command = c
        return ghostty_surface_new(app, &cfg)
    }
}

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    fputs("ghostty_init failed\n", stderr)
    exit(1)
}

let nsapp = NSApplication.shared
nsapp.setActivationPolicy(.accessory)

let cfg = ghostty_config_new()
ghostty_config_finalize(cfg)
var rt = makeRuntime()
guard let app = ghostty_app_new(&rt, cfg) else {
    fputs("ghostty_app_new failed\n", stderr)
    exit(1)
}
appHandle = app

let window = NSWindow(
    contentRect: NSRect(x: 60, y: 60, width: 640, height: 480),
    styleMask: [.titled], backing: .buffered, defer: false)
window.title = "bromure ghostty spike (auto-closes)"

let content = NSView(frame: window.contentLayoutRect)
window.contentView = content

var surfaces: [ghostty_surface_t] = []
let cell = CGSize(width: content.bounds.width / CGFloat(GRID),
                  height: content.bounds.height / CGFloat(GRID))
for i in 0..<(GRID * GRID) {
    let v = NSView(frame: NSRect(
        x: CGFloat(i % GRID) * cell.width,
        y: CGFloat(i / GRID) * cell.height,
        width: cell.width, height: cell.height))
    content.addSubview(v)
    guard let s = makeSurface(app: app, view: v, command: "/bin/bash -c 'top -l 0'") else {
        fputs("surface \(i) creation failed\n", stderr)
        exit(1)
    }
    let backing = v.convertToBacking(v.bounds.size)
    ghostty_surface_set_size(s, UInt32(backing.width), UInt32(backing.height))
    surfaces.append(s)
}
window.orderFront(nil)
print("spike: \(surfaces.count) surfaces created")

// Phase 1: let them render.
DispatchQueue.main.asyncAfter(deadline: .now() + RUN_SECONDS) {
    for s in surfaces { ghostty_surface_free(s) }
    surfaces.removeAll()
    print("spike: grid torn down, starting soak")

    // Phase 2: rapid create/free — the teardown-race hunt. Each cycle
    // creates a surface (spawning a child + renderer/IO threads) and frees
    // it 50ms later, well inside "renderer still starting up" territory.
    var cycle = 0
    func soak() {
        if cycle >= SOAK_CYCLES {
            print("spike: soak passed (\(SOAK_CYCLES) cycles)")
            exit(0)
        }
        cycle += 1
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        content.addSubview(v)
        guard let s = makeSurface(app: app, view: v, command: "/bin/bash -c 'yes'") else {
            fputs("soak cycle \(cycle): creation failed\n", stderr)
            exit(1)
        }
        let backing = v.convertToBacking(v.bounds.size)
        ghostty_surface_set_size(s, UInt32(backing.width), UInt32(backing.height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ghostty_surface_free(s)
            v.removeFromSuperview()
            if cycle % 10 == 0 { print("spike: soak \(cycle)/\(SOAK_CYCLES)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: soak)
        }
    }
    soak()
}

// Watchdog: the whole spike must finish well under a minute.
DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    fputs("spike: watchdog timeout\n", stderr)
    exit(2)
}

nsapp.run()
