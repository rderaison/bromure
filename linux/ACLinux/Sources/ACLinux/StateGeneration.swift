import Foundation
import NIOConcurrencyHelpers

/// /state's ordering stamps (macOS: ACAutomationServer's mutation
/// generation and epoch): a mutating request bumps the generation as it
/// starts and again just before its response goes out, so a client that
/// acts then reads (the fat client does) orders the snapshots it gets by
/// it; the epoch says which daemon run, so a restarted one isn't read as
/// "older".
enum StateGeneration {
    private static let generation = NIOLockedValueBox(0)
    /// This daemon run.
    static let epoch = UUID().uuidString

    // @port ACAutomationServer.static noteMutation() h=7ab26af6c3e91896 @30634ab2
    static func noteMutation() { generation.withLockedValue { $0 &+= 1 } }

    // @port ACAutomationServer.static var currentMutationGeneration h=f1ea6f6d05967f1f @30634ab2
    static var current: Int { generation.withLockedValue { $0 } }

    /// Guest commands and file ops (`…/exec`, `…/file`, `…/type`) are POSTs
    /// that change nothing /state reports.
    // @port ACAutomationServer.static isMutating(_: String, path: String) h=c64449911d84fd43 @30634ab2
    static func isMutating(_ method: String, path: String) -> Bool {
        guard method != "GET", method != "HEAD" else { return false }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return !(bare.hasSuffix("/exec") || bare.hasSuffix("/file") || bare.hasSuffix("/type"))
    }
}
