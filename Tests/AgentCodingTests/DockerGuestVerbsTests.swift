import Foundation
import Testing
#if canImport(ACLinux)
@testable import ACLinux
#else
@testable import bromure_ac
#endif

/// The Docker dashboard's guest verbs: ids and volume names that can't
/// break out of the guest's command line, a run command whose every user
/// field is single-quoted, and the fat-client route's actions.
@Suite("Docker guest verbs")
struct DockerGuestVerbsTests {
    @Test func idsAndVolumeNames() {
        #expect(DockerGuestVerbs.sanitizedID(" web-1 ") == "web-1")
        #expect(DockerGuestVerbs.sanitizedID("ghcr.io/o/img:1@sha256") != nil)
        for bad in ["", "a;b", "a b", "$(x)", "a\nb", "a'b"] { #expect(DockerGuestVerbs.sanitizedID(bad) == nil, "\(bad)") }
        #expect(DockerGuestVerbs.sanitizedVolumeName("data_1.v-2") == "data_1.v-2")
        for bad in ["", "-x", ".x", "a/b", "a:b", "a b"] { #expect(DockerGuestVerbs.sanitizedVolumeName(bad) == nil, "\(bad)") }
    }

    @Test func theRunVerbQuotesEveryField() throws {
        var spec = DockerGuestVerbs.RunSpec(image: "nginx:1")
        spec.name = "web"
        spec.ports = ["8080:80", " "]
        spec.env = ["A=it's"]
        spec.volumes = ["/a:/b"]
        spec.inheritProxy = true
        let verb = try #require(DockerGuestVerbs.runVerb(spec: spec))
        #expect(verb == #"docker-run proxy 0 - nginx:1 docker run -d --name 'web' -p '8080:80' -e 'A=it'\''s' -v '/a:/b' 'nginx:1'"#)
        spec.interactive = true; spec.name = ""
        let it = try #require(DockerGuestVerbs.runVerb(spec: spec))
        #expect(it.hasPrefix("docker-run proxy 1 bromure-") && it.contains("docker run -it --name 'bromure-"), "a generated name to nest the tab under")
        #expect(DockerGuestVerbs.runVerb(spec: .init(image: "  ")) == nil)
        spec.env = ["A=1\nB=2"]
        #expect(!(DockerGuestVerbs.runVerb(spec: spec) ?? "\n").contains("\n"), "one line")
    }

    @Test func theRouteActions() {
        typealias A = DockerGuestVerbs.AutomationAction
        func act(_ d: [String: Any]) -> A { DockerGuestVerbs.automationAction(d) }
        #expect(act(["action": "stop", "container": "abc"]) == .send("docker-stop abc"))
        #expect(act(["action": "logs", "container": "a;b"]) == .refused("bad container id"))
        #expect(act(["action": "attach", "container": "abc", "shell": "bash"]) == .send("docker-attach abc bash"))
        #expect(act(["action": "attach", "container": "abc", "shell": "sh -c x"]) == .send("docker-attach abc sh"), "a bad shell falls back")
        #expect(act(["action": "binfmt"]) == .send("docker-binfmt"))
        #expect(act(["action": "binfmt-off"]) == .send("docker-binfmt-off"))
        #expect(act(["action": "volume-create", "volume": "v1"]) == .send("docker-volume-create v1"))
        #expect(act(["action": "volume-remove", "volume": "../x"]) == .refused("bad volume name"))
        #expect(act(["action": "run", "image": ""]) == .refused("missing image"))
        #expect(act(["action": "run", "image": "alpine"]) == .send("docker-run none 0 - alpine docker run -d 'alpine'"))
        #expect(act(["action": "watch", "on": true]) == .watch(true))
        #expect(act(["action": "watch"]) == .watch(false))
        #expect(act(["action": "nope"]) == .refused("unknown docker action: nope"))
    }
}
