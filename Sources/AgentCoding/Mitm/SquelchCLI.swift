import Foundation

/// `cmd 2>&1 | bromure-ac __squelch "cmd" [--stats]` — print what the model
/// would read of `cmd`'s output with Squelch on (stdin → stdout), or with
/// `--stats` only the family and the sizes. Standalone: no servers, no VMs.
enum SquelchCLI {
    static func run(_ args: [String]) {
        let stats = args.contains("--stats")
        let command = args.first { $0 != "--stats" }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let family = command.map(Squelch.family(of:)) ?? Squelch.sniff(input)
        guard let r = Squelch.trim(command: command, output: input) else {
            if stats {
                print("family \(family.rawValue): left as it is (\(input.utf8.count) bytes)")
            } else {
                print(input, terminator: "")
            }
            return
        }
        if stats {
            let saved = r.rawBytes - r.keptBytes
            print(String(format: "family %@: %d → %d bytes, ~%d tokens saved (%.0f%%)", r.family.rawValue,
                         r.rawBytes, r.keptBytes, saved / 4, 100 * Double(saved) / Double(max(1, r.rawBytes))))
            for (k, v) in r.dropped.sorted(by: { $0.value > $1.value }) { print("  \(k): \(v)") }
        } else {
            print(r.text, terminator: r.text.hasSuffix("\n") ? "" : "\n")
        }
    }
}
