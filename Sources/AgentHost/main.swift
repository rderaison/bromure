import AppKit

// Bromure Sidecar. Subcommands (run from the same binary):
//   __hook <state>     Claude Code's status hook (see ClaudeHooks)
//   __find <args>      GNU find's -printf subset, for the `find` shim (FindCommand)
//   __mcp-delegation   the agents' delegation MCP server (see DelegationHub)
//   __login <tool>     a headless sign-in's link and code, then cancel (a check)
//   __menu-shot <png>  the menu's header row and the menu-bar mark, drawn offscreen
//   __agents           the Manage Agents window alone (no services started)
//   __remote-menu      what a plain SSH login gets: a terminal on the agents
//   claude [args…]     start Claude here as a hosted session and attach
//                      (also as `bromure-claude`, a link to this binary)
// No arguments: the menu-bar app.

AgentHostPaths.migrateFromNative()
AgentHostPaths.migrateFromAgentHost()

let args = CommandLine.arguments
let invokedAs = (args[0] as NSString).lastPathComponent

if invokedAs == "bromure-claude" {
    exit(Launcher.runClaude(args: Array(args.dropFirst())))
}
if args.count >= 2 {
    switch args[1] {
    case "__mcp-delegation":
        exit(DelegationShim.run())
    case "__find":
        exit(FindCommand.run(Array(args.dropFirst(2))))
    case "__hook":
        exit(ClaudeHooks.runHook(state: args.count > 2 ? args[2] : "done"))
    case "__remote-menu":
        // An interactive SSH login: straight into the agents' tmux, on a
        // grouped session of its own (like a client terminal view).
        let attach = Tmux.viewAttachCommand(view: "ssh-\(getpid())", window: nil, sizePassive: false)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(attach), nil]
        execv("/bin/sh", argv)
        exit(127)
    case "__login" where args.count > 2:
        _ = AgentLogin.shared.start(args[2])
        for _ in 0..<60 {
            let st = AgentLogin.shared.state(args[2])
            if let phase = st["phase"] as? String, phase != "starting" {
                print(String(decoding: (try? JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self))
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        AgentLogin.shared.cancel(args[2])
        Thread.sleep(forTimeInterval: 0.5)
        exit(0)
    case "__menu-shot" where args.count > 2:
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let rows: [(SidecarMenuHeader.Status)] = [
                .init(text: "Attached to ark as macdev2-native", tone: .good),
                .init(text: "Waiting for approval on ark", tone: .busy),
                .init(text: "Not signed in to bromure.io", tone: .idle),
            ]
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54 * 3 + 40))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            for (i, st) in rows.enumerated() {
                let v = SidecarMenuHeader.view(status: st)
                v.frame.origin = NSPoint(x: 0, y: 40 + CGFloat(2 - i) * 54)
                canvas.addSubview(v)
            }
            for (i, badge) in [false, true].enumerated() {
                let iv = NSImageView(frame: NSRect(x: 14 + CGFloat(i) * 40, y: 10, width: 30, height: 20))
                iv.image = SidecarMark.menuBarImage(badge: badge)
                iv.contentTintColor = .labelColor
                canvas.addSubview(iv)
            }
            let win = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
        }
        exit(0)
    case "__agents":
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            AgentsWindowController.standalone = true
            AgentsWindowController.shared.show()
            app.run()
        }
        exit(0)
    case "claude":
        exit(Launcher.runClaude(args: Array(args.dropFirst(2))))
    default:
        break
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AgentHostApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
