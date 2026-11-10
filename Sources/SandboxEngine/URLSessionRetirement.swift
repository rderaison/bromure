import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The end of a URLSession made for one job (a download with its own
/// delegate): invalidated once its tasks finish.
///
/// On Linux the session is also kept alive for good. swift-corelibs-foundation
/// tears down libcurl's multi handle when the session is freed, and a socket
/// curl still watches then (an idle HTTP/2 connection, kept for reuse) calls
/// back into the half-freed handle: the runtime aborts the process ("_MultiHandle
/// deallocated with non-zero retain count"). A session that is never freed
/// never gets there; curl closes the idle connection itself when the server
/// drops it. Requests a long-lived owner makes should share one session instead.
public enum URLSessionRetirement {
    #if os(Linux)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var retired: [URLSession] = []
    #endif

    public static func retire(_ session: URLSession) {
        session.finishTasksAndInvalidate()
        keepAlive(session)
    }

    #if os(Linux)
    private static func keepAlive(_ session: URLSession) {
        lock.lock(); retired.append(session); lock.unlock()
    }
    #else
    private static func keepAlive(_ session: URLSession) {}
    #endif
}
