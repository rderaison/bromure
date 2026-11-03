import Foundation

/// Kubernetes clusters and container registries on a Linux server: the
/// shared models and their store (KubeCluster.swift, at
/// `<state>/kube/clusters.json`), listed for a fat client as macOS lists
/// them. The engine that boots their node VMs isn't ported yet, so every
/// change is refused, saying so; the client's pane shows an empty list
/// rather than an error.
extension Daemon {
    static let kubeUnavailable = "Kubernetes clusters and container registries aren't available on this Linux server yet."

    /// `/k8s…` and `/registries…`; nil for any other path.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    func kubeRoute(_ method: String, _ path: String) async -> ControlResponse? {
        switch (method, path) {
        case ("GET", "/k8s"): return await kubeList()
        case ("POST", "/k8s"): return kubeCreate()
        case (_, let p) where p.hasPrefix("/k8s/"): return kubeCommand()
        case ("POST", "/registries"): return registryCreate()
        case (_, let p) where p.hasPrefix("/registries/"): return registryCommand()
        default: return nil
        }
    }

    /// The clusters, registries, connectors and their status.
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("GET", "/k8s"): h=dde246cbd63efa97 @7dd92fdf
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onListKubeClusters h=0c729e20e2122b7f @32a528c5
    func kubeList() async -> ControlResponse {
        let snap = await MainActor.run { SessionStores.shared?.kube.snapshot() ?? ["clusters": [], "status": [:]] }
        return ControlResponse(200, JSONValue(foundation: snap) ?? .object([:]))
    }

    // partial: refused (no cluster engine on Linux yet)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/k8s"): h=f99ca82a9e3186a6 @7dd92fdf
    func kubeCreate() -> ControlResponse {
        ControlResponse(400, ["ok": false, "error": .string(Self.kubeUnavailable)])
    }

    // partial: refused (no cluster engine on Linux yet)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case (let m, let p) where p.hasPrefix("/k8s/"): h=ecf14d0915d2df82 @7dd92fdf
    // @port ACAppDelegate.automationKubeCommand(id: String?, doc: [String:Any]) h=ccdfe10f6c32148f @32a528c5
    func kubeCommand() -> ControlResponse {
        ControlResponse(400, ["ok": false, "error": .string(Self.kubeUnavailable)])
    }

    // partial: refused (no registry engine on Linux yet)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case ("POST", "/registries"): h=a2c8ce826a1eaa9a @7dd92fdf
    func registryCreate() -> ControlResponse {
        ControlResponse(400, ["ok": false, "error": .string(Self.kubeUnavailable)])
    }

    // partial: refused (no registry engine on Linux yet)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool) / case (let m, let p) where p.hasPrefix("/registries/"): h=52a7426dba2a3e85 @7dd92fdf
    // @port ACAppDelegate.automationRegistryCommand(id: String?, doc: [String:Any]) h=769838b3e51c3441 @32a528c5
    func registryCommand() -> ControlResponse {
        ControlResponse(400, ["ok": false, "error": .string(Self.kubeUnavailable)])
    }
}
