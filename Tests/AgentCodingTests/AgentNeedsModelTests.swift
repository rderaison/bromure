import Foundation
import Testing
@testable import bromure_ac

/// "storage_unavailable": a workspace signed in to Nous Portal, its Hermes
/// never given a model, started Hermes on none -- its sessions were saved
/// without a model and couldn't be reopened. The workspace still saves that
/// way; the new-session picker greys Hermes out and says why.
@Suite("An agent that needs a model can't start without one")
struct AgentNeedsModelTests {
    @Test("Hermes listed in the workspace but with no model isn't ready")
    func hermesWithoutModel() {
        let p = Profile(name: "w", tool: .hermes, authMode: .subscription, apiKey: nil)
        #expect(!p.agentsReadyToStart(ModelSettings(), subscribed: [.nous]).contains(.hermes))
        #expect(!p.readyToolSpecs(ModelSettings(), subscribed: [.nous]).contains { $0.tool == .hermes })
    }

    @Test("a model picked for it, or the local engine's, makes it ready")
    func hermesWithModel() {
        var p = Profile(name: "w", tool: .hermes, authMode: .subscription, apiKey: nil)
        p.ompModel = "z-ai/glm-5.3"
        #expect(p.agentsReadyToStart(ModelSettings(), subscribed: [.nous]).contains(.hermes))
        var local = Profile(name: "w", tool: .hermes, authMode: .local, apiKey: nil)
        #expect(!local.hasModel(for: local.allToolSpecs[0]))
        local.activeModelID = "mlx-community/some-model"
        #expect(local.hasModel(for: local.allToolSpecs[0]))
    }

    @Test("only Hermes is held to it: omp and the vendor agents keep their defaults")
    func onlyHermes() {
        #expect(Profile.Tool.allCases.filter(\.needsModelToStart) == [.hermes])
        let omp = Profile(name: "w", tool: .omp, authMode: .token, apiKey: "k")
        #expect(omp.agentsReadyToStart(ModelSettings()).contains(.omp))
        let claude = Profile(name: "w", tool: .claude, authMode: .subscription, apiKey: nil)
        #expect(claude.agentsReadyToStart(ModelSettings()).contains(.claude))
    }

    @Test("the picker greys it out, says why, and Start stays off")
    func picker() throws {
        let top = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/SessionStageViews.swift"), encoding: .utf8)
        #expect(v.contains("let blocked = !configured && t.needsModelToStart"))
        #expect(v.contains(".disabled(blocked)"))
        #expect(v.contains("guard selectedProfile != nil, !agentNeedsModel else { return false }"))
        #expect(v.contains("if agentNeedsModel {"))
        #expect(NewSessionView.needsModelMessage(.hermes).contains("Hermes"))
    }
}
