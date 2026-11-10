import Foundation

/// The CLI's hidden verification hooks, as macOS's `bromure-ac` main runs
/// them before parsing (standalone: no daemon, no VMs).
public enum HiddenHooks {
    /// Ran one (`__pii-scan`, `__squelch`) for `args` (argv without the
    /// program): true, the CLI is done.
    // @port-skip linux-only: the hidden-hook half of BromureAC.main (see its claim): the hooks a server has, no __exit-hook-test, __bench-scroll or __shot-*
    public static func run(_ args: [String]) -> Bool {
        switch args.first {
        case "__pii-scan": PIIScanCLI.run(Array(args.dropFirst())); return true
        case "__squelch": SquelchCLI.run(Array(args.dropFirst())); return true
        default: return false
        }
    }
}
