import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-532): "net.flow uploads process argv and tool commands with
/// no secret redaction". A flow's argv (per process) and its tool command,
/// and tool.use / command.run commands, went to the local timeline and the
/// org event stream as typed — `curl -u user:password`, bearer headers,
/// pasted tokens included.
@Suite("Command lines lose their secrets before they're recorded or uploaded")
struct CommandLineRedactorTests {
    @Test("passwords, header values, secret flags, URL userinfo and known tokens are taken out")
    func redact() {
        let r = CommandLineRedactor.redact
        #expect(r("curl -u alice:hunter2 https://x.example") == "curl -u alice:*** https://x.example")
        #expect(r("curl -ualice:hunter2 https://x.example") == "curl -ualice:*** https://x.example")
        // -u closing a cluster of short flags, its argument next or glued.
        #expect(r("curl -su alice:hunter2 https://x") == "curl -su alice:*** https://x")
        #expect(r("curl -fsSLu alice:hunter2 https://x") == "curl -fsSLu alice:*** https://x")
        #expect(r("curl -sLuuser:hunter2 https://x") == "curl -sLuuser:*** https://x")
        #expect(r("curl -kU proxy:pw -x http://p:3128 https://x") == "curl -kU proxy:*** -x http://p:3128 https://x")
        #expect(r("curl -4u alice:pw https://x") == "curl -4u alice:*** https://x")
        #expect(r("curl -6fsSLu alice:pw https://x") == "curl -6fsSLu alice:*** https://x")
        #expect(r("curl -0u alice:pw https://x") == "curl -0u alice:*** https://x")
        #expect(r("curl -#u alice:pw https://x") == "curl -#u alice:*** https://x")
        // A cluster without -u, or -u not last, is something else.
        #expect(r("curl -fsSL https://x/a:b") == "curl -fsSL https://x/a:b")
        #expect(r("tar -uvf a.tar b:c") == "tar -uvf a.tar b:c")
        #expect(r("mkdir -p a:b && ssh -p 22 host") == "mkdir -p a:b && ssh -p 22 host")
        #expect(r(#"curl -H "Authorization: Bearer abc.def.ghi" https://api.example"#)
                == #"curl -H "Authorization: Bearer ***" https://api.example"#)
        #expect(r("curl -H 'X-Api-Key: k123' x") == "curl -H 'X-Api-Key: ***' x")
        #expect(r("git clone https://bob:s3cret@github.com/acme/app") == "git clone https://bob:***@github.com/acme/app")
        #expect(r("mysql --password hunter2 db") == "mysql --password *** db")
        #expect(r("deploy --token=abc123 now") == "deploy --token=*** now")
        #expect(r("API_KEY=abc123 DB_PASSWORD=pw ./run") == "API_KEY=*** DB_PASSWORD=*** ./run")
        #expect(r("curl 'https://x.example/cb?access_token=zzz&id=1'") == "curl 'https://x.example/cb?access_token=***&id=1'")
        let gh = r("gh auth login --with-token ghp_" + String(repeating: "a", count: 36))
        #expect(!gh.contains("ghp_aaaa") && gh.contains("[GitHub token #"))
        // Nothing secret: left alone.
        #expect(r("curl -sS https://pypi.org/simple/requests/") == "curl -sS https://pypi.org/simple/requests/")
        #expect(r("git log --author=bob -n 5") == "git log --author=bob -n 5")
    }

    /// Finding (CWE-670): "Command redaction erases rsync paths, PWD, and
    /// token: URLs that are not secrets".
    @Test("remote paths, the working directory and token-named URLs aren't secrets; real ones still go")
    func notSecrets() {
        let r = CommandLineRedactor.redact
        for kept in ["rsync -u host:/var/data dest", "rsync -u backup:~/data .",
                     "rsync -u host:src/file dest", "rsync -u user@host::module/file dest",
                     "rsync -u 'host:src/file' dest", "curl -s https://x; rsync -u host:src dest",
                     "PWD=/Users/someone/proj make -j", "OLDPWD=/tmp cd -",
                     "curl https://api.example/v1/tokens:list", "grep -r passwordless docs/",
                     "git push -u origin HEAD:main"] {
            #expect(r(kept) == kept, "\(kept)")
        }
        #expect(r("DB_PWD=hunter2 ./run") == "DB_PWD=*** ./run")
        #expect(r("API_TOKEN=abc API_TOKEN_V2=def ./run") == "API_TOKEN=*** API_TOKEN_V2=*** ./run")
        #expect(r("accessToken=abc client_secret=def") == "accessToken=*** client_secret=***")
        #expect(r(#"curl -d '{"token": "x"}' 'https://x/cb?access_token=zzz&id=1'"#)
                == #"curl -d '{"token": "***"}' 'https://x/cb?access_token=***&id=1'"#)
        #expect(r("curl -u alice:hunter2 https://x") == "curl -u alice:*** https://x")
        // A curl password is masked whatever it starts with, wrapped or not.
        #expect(r("curl -u alice:/s3cret https://x") == "curl -u alice:*** https://x")
        #expect(r("/usr/bin/curl -U bob:~hunter -x p https://x") == "/usr/bin/curl -U bob:*** -x p https://x")
        #expect(r("bash -c 'curl -sS -u alice:/BAiM0RVZnc= https://x'") == "bash -c 'curl -sS -u alice:*** https://x'")
        #expect(r("wget --user=bob:pw https://x") == "wget --user=bob:*** https://x")
        // The curl command reaches past quoted or escaped separators and
        // redirects; only a real command boundary ends it.
        for (cmd, out) in [
            ("curl 'https://x?a=1&b=2' -u alice:/s3cret", "curl 'https://x?a=1&b=2' -u alice:***"),
            (#"curl https://x?a=1\&b=2 -u alice:/s3cret"#, #"curl https://x?a=1\&b=2 -u alice:***"#),
            ("curl https://x?a=1&b=2 -u alice:/s3cret", "curl https://x?a=1&b=2 -u alice:***"),   // space-joined argv
            ("curl -d 'a;b' -u alice:/s3cret https://x", "curl -d 'a;b' -u alice:*** https://x"),
            ("curl -s https://x 2>&1 -u alice:/s3cret", "curl -s https://x 2>&1 -u alice:***"),
            ("curl &>/tmp/out -u alice:/s3cret https://x", "curl &>/tmp/out -u alice:*** https://x"),
            ("curl -s \\\n  -u alice:/s3cret https://x", "curl -s \\\n  -u alice:*** https://x"),
            ("curl -u alice:a 'https://x?a=1&b=2' -u bob:/second", "curl -u alice:*** 'https://x?a=1&b=2' -u bob:***"),
            ("CURL -u alice:/s3cret", "CURL -u alice:***"),
            // A substitution or a parenthesis in a URL nests; after it, the curl command resumes.
            ("curl https://en.wikipedia.org/wiki/Foo_(bar) -u alice:/s3cret", "curl https://en.wikipedia.org/wiki/Foo_(bar) -u alice:***"),
            ("curl -o $(mktemp) -u alice:/s3cret https://x", "curl -o $(mktemp) -u alice:*** https://x"),
            ("curl `date` -u alice:/s3cret https://x", "curl `date` -u alice:*** https://x"),
            ("curl <(echo x) -u alice:/s3cret", "curl <(echo x) -u alice:***"),
            ("curl -o >(tee /tmp/x) -u alice:/s3cret https://x", "curl -o >(tee /tmp/x) -u alice:*** https://x"),
            ("curl >| /tmp/out -u alice:/s3cret", "curl >| /tmp/out -u alice:***"),
            ("echo $(rsync -u host:src/file x) done", "echo $(rsync -u host:src/file x) done"),
            ("curl $(rsync -u host:src/file x)", "curl $(rsync -u host:src/file x)"),
            ("curl -u alice:secret && rsync -u host:src/file", "curl -u alice:*** && rsync -u host:src/file"),
        ] {
            #expect(r(cmd) == out, "\(cmd)")
        }
    }

    /// Finding (CWE-532): "Cookie flags and secrets past the first space are
    /// still stored and uploaded" — every value stopped at the first space or
    /// quote, and curl's own cookie flags weren't recognized.
    @Test("cookies (header, -b, --cookie) and quoted secrets with spaces are taken out whole")
    func valuesPastTheFirstSpace() {
        let r = CommandLineRedactor.redact
        #expect(r("curl -H 'Cookie: session=SECRET; csrf=OTHER' https://x.example")
                == "curl -H 'Cookie: ***' https://x.example")
        #expect(r(#"curl -H "Authorization: Bearer abc def" x"#) == #"curl -H "Authorization: Bearer ***" x"#)
        #expect(r("curl --cookie 'session=SECRET; csrf=OTHER' x") == "curl --cookie '***' x")
        #expect(r("curl -b 'session=SECRET' x") == "curl -b '***' x")
        #expect(r("curl -b session=SECRET x") == "curl -b *** x")
        #expect(r("curl --cookie=session=SECRET x") == "curl --cookie=*** x")
        #expect(r(#"curl -u "alice:my hunter2" x"#) == #"curl -u "alice:***" x"#)
        #expect(r(#"tool --password="my hunter2" go"#) == #"tool --password="***" go"#)
        #expect(r("tool --token 'a b c' go") == "tool --token '***' go")
        #expect(r(#"API_KEY="hunter2 extra" ./run"#) == #"API_KEY="***" ./run"#)
        #expect(r(#"curl -d '{"password": "a b", "user": "bob"}' x"#) == #"curl -d '{"password": "***", "user": "bob"}' x"#)
        // The sentry's argv: arguments joined by spaces, quotes gone.
        #expect(r("curl -H Cookie: session=SECRET; csrf=OTHER https://x.example")
                == "curl -H Cookie: *** https://x.example")
        #expect(r("curl --cookie session=SECRET; csrf=OTHER https://x.example") == "curl --cookie *** https://x.example")
        // Not cookies: a cookie file, a cookie jar, a git branch.
        #expect(r("curl -b cookies.txt -c jar.txt x") == "curl -b cookies.txt -c jar.txt x")
        #expect(r("curl --cookie-jar /tmp/jar x") == "curl --cookie-jar /tmp/jar x")
        #expect(r("git checkout -b fix-login && git push") == "git checkout -b fix-login && git push")
        // Finding (CWE-532): "Clustered curl -b leaves cookie values in the
        // timeline and the org upload" — -b closing a short-flag cluster.
        for (cmd, out) in [
            ("curl -sb 'session=SECRET' x", "curl -sb '***' x"),
            ("curl -fsSLb 'session=SECRET' x", "curl -fsSLb '***' x"),
            ("curl -4b 'session=SECRET' x", "curl -4b '***' x"),
            ("curl -sbsession=SECRET x", "curl -sb*** x"),
            ("curl -bsession=SECRET x", "curl -b*** x"),
            ("curl -sb session=SECRET; csrf=OTHER https://x", "curl -sb *** https://x"),   // the sentry's argv
            ("/usr/bin/curl -Sb 'session=SECRET' x", "/usr/bin/curl -Sb '***' x"),
            // A `b` in the cookie's own name: curl's argument starts at the first one.
            ("curl -sbab=SECRET x", "curl -sb*** x"),
            ("curl -bAWSALB=SECRET x", "curl -b*** x"),
            ("curl -sbAWSALB=SECRET x", "curl -sb*** x"),
            ("curl -sbtokenb=SECRET x", "curl -sb*** x"),
        ] {
            #expect(r(cmd) == out, "\(cmd)")
        }
        // Finding (CWE-532): "A curl -B cluster is read as -b, so the real
        // cookie is uploaded" — -B is --use-ascii and takes no argument, so
        // the real -b after it is the cookie, and the token after -B alone
        // is a URL, not a cookie.
        for (cmd, out) in [
            ("curl -fsSLB -b session=SECRET https://x", "curl -fsSLB -b *** https://x"),
            ("curl -SB -b session=SECRET https://x", "curl -SB -b *** https://x"),
            ("curl -sB -b 'session=SECRET' https://x", "curl -sB -b '***' https://x"),
            ("curl -LB -sb session=SECRET https://x", "curl -LB -sb *** https://x"),
        ] {
            #expect(r(cmd) == out, "\(cmd)")
        }
        // Finding (CWE-532): "Glued equals stays in curl's cookie argument and
        // is uploaded" — curl keeps a glued `=` in -b's argument, so that
        // argument always holds one and is sent as `Cookie: =SECRET`.
        for (cmd, out) in [
            ("curl -b=SECRET x", "curl -b=*** x"),
            ("curl -sb=SECRET x", "curl -sb=*** x"),
            ("curl -fsSLb=SECRET https://x", "curl -fsSLb=*** https://x"),
            ("curl -4b=TOKEN https://x", "curl -4b=*** https://x"),
            ("curl -sb=session=SECRET x", "curl -sb=*** x"),
            ("curl -sb=\"$SECRET\" x", "curl -sb=\"***\" x"),
            ("curl -sb='a=1; b=2' x", "curl -sb='***' x"),
            ("curl -sb=s=1; t=2 x", "curl -sb=*** x"),                       // the sentry's argv
            ("curl -sbab=SECRET x", "curl -sb*** x"),                        // still the first b
        ] {
            #expect(r(cmd) == out, "\(cmd)")
        }
        for kept in ["curl -sb cookies.txt x",                               // a cookie file
                     "curl -fsSLB https://example.com/file?q=1",             // -B takes no argument
                     "/usr/bin/curl -SB 'session=1' x",                      // a URL to curl, never sent as a cookie
                     "ls -lb=x dir",                                         // not curl
                     "git checkout -qb fix-login && git push",               // not curl
                     "tar -czvfb x=1 dir", "ls -lb a=b"] {
            #expect(r(kept) == kept, "\(kept)")
        }
        // curl's other secret-taking options.
        #expect(r("curl --key k.pem --pass hunter2 x") == "curl --key k.pem --pass *** x")
        #expect(r("curl --proxy-pass=hunter2 x") == "curl --proxy-pass=*** x")
        #expect(r("curl --oauth2-bearer abc.def x") == "curl --oauth2-bearer *** x")
        #expect(r("curl --tlspassword hunter2 x") == "curl --tlspassword *** x")
        #expect(r("curl --proxy-tlspassword hunter2 x") == "curl --proxy-tlspassword *** x")
        // A client certificate's passphrase; a bare certificate path stays.
        #expect(r("curl -E client.pem:hunter2 https://x") == "curl -E client.pem:*** https://x")
        #expect(r("curl -kE client.pem:hunter2 https://x") == "curl -kE client.pem:*** https://x")
        #expect(r("curl --cert client.pem:hunter2 https://x") == "curl --cert client.pem:*** https://x")
        #expect(r("curl --proxy-cert=c.pem:hunter2 https://x") == "curl --proxy-cert=c.pem:*** https://x")
        #expect(r("curl -E client.pem https://x") == "curl -E client.pem https://x")
        #expect(r("curl -e https://ref.example:8443/ https://x") == "curl -e https://ref.example:8443/ https://x")
        #expect(r("grep -E a:b file") == "grep -E a:b file")
        // -u binds its first u too: the user shows whole.
        #expect(r("curl -sLuuser:pw https://x") == "curl -sLuuser:*** https://x")
        // A non-BMP character inside an unquoted value doesn't end it.
        #expect(r("deploy --token=ab🔑cd now") == "deploy --token=*** now")
        #expect(r("curl -b s=🍪x; t=2 x") == "curl -b *** x")
        // Several in one line, each whole.
        #expect(r(#"curl -u "a:b c" -H 'Cookie: s=1; t=2' --password 'p q'"#)
                == #"curl -u "a:***" -H 'Cookie: ***' --password '***'"#)
    }

    @Test("a net.flow's argv per process and its tool command are scrubbed; other fields aren't touched")
    func scrubFlow() {
        let data: [String: AnyJSON] = [
            "dst": .string("1.2.3.4"), "host": .string("api.example"),
            "processes": .array([
                .object(["comm": .string("bash"), "argv": .string("bash -c 'curl -u u:pw https://api.example'")]),
                .object(["comm": .string("curl"), "argv": .string("curl -u u:pw https://api.example")]),
            ]),
            "agent": .object(["tool": .string("Bash"), "command": .string("curl -u u:pw https://api.example")]),
            "reason": .string("token=keep-me-this-is-not-a-command-field"),
        ]
        let out = CommandLineRedactor.scrub(data)
        guard case .array(let procs)? = out["processes"] else { Issue.record("no processes"); return }
        for p in procs {
            guard case .object(let o) = p, case .string(let a)? = o["argv"] else { Issue.record("no argv"); continue }
            #expect(!a.contains("u:pw") && a.contains("u:***"))
        }
        guard case .object(let agent)? = out["agent"], case .string(let c)? = agent["command"] else { Issue.record("no command"); return }
        #expect(c == "curl -u u:*** https://api.example")
        if case .string(let host)? = out["host"] { #expect(host == "api.example") }
        if case .string(let reason)? = out["reason"] { #expect(reason.contains("keep-me")) }
    }

    @Test("the emitter scrubs before the timeline records a net.flow (row text and its stored detail)")
    @MainActor func emitterScrubs() async throws {
        let pid = UUID()
        await BACEventEmitter.shared.emit(profileID: pid, eventType: "net.flow", eventData: [
            "proto": .string("tcp"), "dst": .string("10.0.0.5"), "dport": .int(5432), "decision": .string("allow"),
            "processes": .array([.object(["pid": .int(7), "comm": .string("psql"),
                                          "argv": .string("psql postgres://app:pw1@db/x")])]),
            "agent": .object(["tool": .string("Bash"), "tool_use_id": .string("t1"),
                              "command": .string("PGPASSWORD=pw1 psql -h db")]),
            "command": .string("PGPASSWORD=pw1 psql -h db"),
        ])
        let row = try #require(SecurityTimeline.shared.allEvents.last { $0.profileID == pid })
        #expect(!row.condition.contains("pw1"))
        let stored = String(decoding: try JSONEncoder().encode(row.detail ?? [:]), as: UTF8.self)
        #expect(!stored.isEmpty && !stored.contains("pw1"))
        #expect(stored.contains("app:***@db"))
    }
}
