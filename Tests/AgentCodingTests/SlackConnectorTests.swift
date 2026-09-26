import Foundation
import Testing
@testable import bromure_ac

@Suite("Slack connector")
@MainActor
struct SlackConnectorTests {
    private let paired = ConnectorChannel(kind: .slack, mode: .ownNumber, account: "UBOT",
                                          allowed: ["UME"], connected: true,
                                          workspace: "Acme", workspaceID: "T1")

    private func dm(_ from: String, text: String = "hi", type: String = "im", bot: Bool = false,
                    subtype: String = "", team: String = "T1") -> [String: Any] {
        ["channel": "slack", "from": from, "chat": "D1", "channelType": type, "team": team,
         "bot": bot, "subtype": subtype, "text": text]
    }

    @Test("only the paired member's plain DMs reach the Switchboard")
    func onlyTheUser() {
        #expect(KubeClusterEngine.isFromUser(dm("UME"), channel: paired))
        #expect(!KubeClusterEngine.isFromUser(dm("USOMEONE"), channel: paired))            // anyone else
        #expect(!KubeClusterEngine.isFromUser(dm("UME", type: "channel"), channel: paired)) // a channel
        #expect(!KubeClusterEngine.isFromUser(dm("UME", type: "mpim"), channel: paired))    // a group DM
        #expect(!KubeClusterEngine.isFromUser(dm("UME", bot: true), channel: paired))       // a bot (its own echo)
        #expect(!KubeClusterEngine.isFromUser(dm("UME", subtype: "message_changed"), channel: paired)) // an edit
        #expect(!KubeClusterEngine.isFromUser(dm("UME", team: "T2"), channel: paired))      // Slack Connect, other org
        #expect(!KubeClusterEngine.isFromUser(dm(""), channel: paired))
    }

    @Test("an unpaired app answers nobody")
    func unpaired() {
        var ch = paired
        ch.allowed = []
        #expect(!KubeClusterEngine.isFromUser(dm("UME"), channel: ch))
    }

    @Test("the create-app link carries a Socket Mode, DM-only manifest")
    func manifest() throws {
        let url = try #require(KubeClusterEngine.slackCreateAppURL)
        #expect(url.host == "api.slack.com")
        let q = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(q.first { $0.name == "new_app" }?.value == "1")
        let json = try #require(q.first { $0.name == "manifest_json" }?.value)
        let m = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let settings = m["settings"] as? [String: Any]
        #expect(settings?["socket_mode_enabled"] as? Bool == true)
        #expect(((settings?["event_subscriptions"] as? [String: Any])?["bot_events"] as? [String]) == ["message.im"])
        let scopes = ((m["oauth_config"] as? [String: Any])?["scopes"] as? [String: Any])?["bot"] as? [String]
        #expect(Set(scopes ?? []) == ["chat:write", "im:history", "im:read", "im:write"])   // nothing more
    }

    @Test("a connector saved before Slack still decodes, and channels include Slack")
    func model() throws {
        var c = MessagingConnector()
        c.setChannel(.slack, paired)
        #expect(c.channels.map(\.kind) == [.slack])
        #expect(c.channel(.slack)?.workspace == "Acme")
        let old = #"{"kind":"signal","mode":"linked","allowed":["+1"],"connected":true}"#
        let ch = try JSONDecoder().decode(ConnectorChannel.self, from: Data(old.utf8))
        #expect(ch.workspace == nil && ch.kind == .signal)
        #expect(ConnectorChannel.Kind.slack.displayName == "Slack")
    }
}
