import Foundation
import SandboxEngine

/// Catalog steps the user said never to install ("Skip Permanently" on the
/// new-packages prompt, or Skip in Base Image details). Kept per Mac, not
/// per image: a new image or a rebuild leaves them out too, and no launch
/// asks about them again. Installing one from Base Image details takes it
/// off the list.
struct PostinstallSkips {
    static let defaultsKey = "postinstallSkippedStepUUIDs"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var uuids: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func contains(_ uuid: String) -> Bool { uuids.contains(uuid) }

    func skip(_ ids: some Sequence<String>) {
        store(uuids.union(ids))
    }

    func unskip(_ ids: some Sequence<String>) {
        store(uuids.subtracting(ids))
    }

    private func store(_ set: Set<String>) {
        if set.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(set.sorted(), forKey: Self.defaultsKey) }
    }
}

extension ImageCatalog {
    /// The steps a base image of this app gets, in execution order: this
    /// app version's, less the ones skipped for good.
    func baseImageSteps(skipping skipped: Set<String> = PostinstallSkips().uuids) -> [PostinstallStep] {
        sortedSteps.filter { !skipped.contains($0.uuid) }
    }

    /// The steps the new-packages prompt offers: neither applied to the
    /// image nor skipped.
    func pendingBaseImageSteps(appliedUUIDs: some Sequence<String>,
                               skipping skipped: Set<String> = PostinstallSkips().uuids) -> [PostinstallStep] {
        pendingSteps(appliedUUIDs: Set(appliedUUIDs).union(skipped))
    }
}

/// One catalog step as Base Image details shows it.
struct PostinstallStepStatus: Identifiable, Equatable {
    enum State: Equatable { case installed, skipped, notInstalled }
    let step: PostinstallStep
    let state: State
    var id: String { step.uuid }

    /// Every step this app runs, in execution order, with where it stands
    /// on the image: applied, skipped for good, or neither (the prompt
    /// offers it at the next launch).
    static func rows(catalog: ImageCatalog, applied: some Sequence<String>,
                     skipped: Set<String>) -> [PostinstallStepStatus] {
        let applied = Set(applied)
        return catalog.sortedSteps.map { s in
            let state: State = applied.contains(s.uuid) ? .installed
                : skipped.contains(s.uuid) ? .skipped : .notInstalled
            return PostinstallStepStatus(step: s, state: state)
        }
    }
}
