import AppKit

// Bromure Native. Subcommands (run from the same binary):
//   __hook <state>     Claude Code's status hook (see ClaudeHooks)
//   __mcp-delegation   the agents' delegation MCP server (see DelegationHub)
//   __remote-menu      what a plain SSH login gets: a terminal on the agents
//   claude [args…]     start Claude here as a hosted session and attach
//                      (also as `bromure-claude`, a link to this binary)
// No arguments: the menu-bar app.

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
    case "__hook":
        exit(ClaudeHooks.runHook(state: args.count > 2 ? args[2] : "done"))
    case "__remote-menu":
        // An interactive SSH login: straight into the agents' tmux, on a
        // grouped session of its own (like a client terminal view).
        let attach = Tmux.viewAttachCommand(view: "ssh-\(getpid())", window: nil, sizePassive: false)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(attach), nil]
        execv("/bin/sh", argv)
        exit(127)
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
