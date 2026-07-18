import Foundation
import Observation

/// Fat-client counterpart of `TraceStore`: the Trace Inspector's backing store
/// when it's mirroring a remote bromure-ac. Instead of reading local disk it
/// pulls full `TraceRecord`s from the remote's `/trace/records` over the
/// tunneled control socket, and fetches decrypted bodies on demand from
/// `/trace/body`. Purely in-memory — remote traces (and their captured bodies,
/// which may hold the remote's secrets) are never written to the client's disk.
///
/// `recent` is `@Observable`, so the inspector redraws as new records arrive.
/// While the window is open a light poll (`pollInterval`) approximates the live
/// tail the local store gets for free from `record(_:)`.
@MainActor
@Observable
final class RemoteTraceStore: TraceInspectorStore {
    private(set) var recent: [TraceRecord] = []

    /// Bodies fetched from the remote, keyed by "<recordID>.<kind>". `.some(nil)`
    /// marks a body we asked for and the remote had none — so re-selecting the
    /// record doesn't re-hit the network. Cleared with the store.
    private var bodyCache: [String: Data?] = [:]

    private weak var controller: RemoteHostController?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .milliseconds(1500)

    init(controller: RemoteHostController) {
        self.controller = controller
    }

    /// Begin polling the remote for records. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchRecords()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop polling (window closed). The store can be restarted with `start()`.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: TraceInspectorStore

    /// Manual refresh (the inspector's reload button / onAppear). Fire-and-forget
    /// so the button stays responsive; `recent` updates when the fetch lands.
    func reload() {
        Task { [weak self] in await self?.fetchRecords() }
    }

    func fetchBody(for record: TraceRecord, kind: TraceStore.BodyKind) async -> Data? {
        guard record.bodyStored else { return nil }
        let key = "\(record.id.uuidString).\(kind.rawValue)"
        if let cached = bodyCache[key] { return cached }
        let data = await controller?.fetchTraceBody(id: record.id, kind: kind)
        bodyCache[key] = data
        return data
    }

    // MARK: Internals

    private func fetchRecords() async {
        guard let controller else { return }
        let records = await controller.fetchTraceRecords(profileID: nil)
        // The remote already sorts newest-first, but be defensive.
        recent = records.sorted { $0.timestamp > $1.timestamp }
    }
}
