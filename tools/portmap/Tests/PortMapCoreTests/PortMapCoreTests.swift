import Testing
@testable import PortMapCore

@Suite("portmap ledger")
struct PortMapCoreTests {
    static let config = PortConfig(macosRoots: [], linuxBuild: [], linuxRoots: [],
                                   skip: [.init(path: "Sources/AgentCoding/*View.swift", id: nil, reason: "ui")])

    @Test("ids name the type and labelled parameter types; the body hash ignores comments and formatting")
    func idsAndHashes() {
        let a = Inventory.scan(source: """
            struct Proxy {
                func handle(_ fd: Int32, host: String) -> Bool {
                    return fd > 0 // a comment
                }
                var name: String { "p" }
                init(port: Int) {}
            }
            extension Proxy { func close() { } }
            """, file: "a.swift", fileInLinuxBuild: false)
        #expect(a.map(\.id) == ["Proxy.handle(_: Int32, host: String)", "Proxy.var name", "Proxy.init(port: Int)", "Proxy.close()"])
        let b = Inventory.scan(source: """
            struct Proxy {
                func handle(_ fd: Int32, host: String) -> Bool {
                    // reformatted
                    return   fd >   0
                }
            }
            """, file: "a.swift", fileInLinuxBuild: false)
        #expect(a[0].hash == b[0].hash)
        let c = Inventory.scan(source: "struct Proxy { func handle(_ fd: Int32, host: String) -> Bool { return fd >= 0 } }",
                               file: "a.swift", fileInLinuxBuild: false)
        #expect(a[0].hash != c[0].hash)
    }

    @Test("#if decides which build a function is in, #else included")
    func conditions() {
        let r = Inventory.scan(source: """
            #if os(macOS)
            func mac() {}
            #elseif os(Linux)
            func lnx() {}
            #else
            func other() {}
            #endif
            #if canImport(AppKit) && !os(iOS)
            func appkit() {}
            #endif
            #if DEBUG
            func debugBoth() {}
            #endif
            func plain() {}
            """, file: "s.swift", fileInLinuxBuild: true)
        let m = Dictionary(uniqueKeysWithValues: r.map { ($0.id, ($0.inMacOS, $0.inLinux)) })
        #expect(m["mac()"]! == (true, false))
        #expect(m["lnx()"]! == (false, true))
        #expect(m["other()"]! == (false, false))
        #expect(m["appkit()"]! == (true, false))
        #expect(m["debugBoth()"]! == (true, true))
        #expect(m["plain()"]! == (true, true))
    }

    @Test("status: shared, ported, stale, skipped, todo, orphans and unclaimed Linux code")
    func statuses() {
        let mac = Inventory.scan(source: """
            func both() {}
            #if os(macOS)
            func boot() { start() }
            func suspend() { save() }
            // @port-skip ui
            func drawSidebar() {}
            func todo() {}
            #else
            // @port boot() h=\(Inventory.scan(source: "func boot() { start() }", file: "x", fileInLinuxBuild: false)[0].hash) @abc123
            func boot() { qemu() }
            #endif
            """, file: "Sources/SandboxEngine/VM.swift", fileInLinuxBuild: true)
        let linux = Inventory.scan(source: """
            // @port suspend() h=0000000000000000 @abc123
            func qemuSuspend() {}
            // @port gone() h=1111111111111111 @abc123
            func leftover() {}
            func helper() {}
            // @port-skip linux-only plumbing
            func tapSetup() {}
            """, file: "Sources/ACLinux/QEMU.swift", fileInLinuxBuild: true, fileInMacOSBuild: false)
        let view = Inventory.scan(source: "struct V { var body: Int { 1 } }",
                                  file: "Sources/AgentCoding/SidebarView.swift", fileInLinuxBuild: false)
        let r = Ledger.assemble(mac: mac + view, linuxOnly: linux, config: Self.config)
        let s = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.mac.id, $0.status) })
        #expect(s["both()"] == .shared)
        #expect(s["boot()"] == .ported)
        #expect(s["suspend()"] == .stale)
        #expect(s["drawSidebar()"] == .skipped)
        #expect(s["V.var body"] == .skipped)
        #expect(s["todo()"] == .todo)
        #expect(r.orphans.map(\.id) == ["leftover()"])
        #expect(r.unclaimedLinux.map(\.id) == ["helper()"])
    }

    @Test("globs: * stays in a path component, ** crosses them")
    func globs() {
        #expect(Glob("Sources/AgentCoding/*View.swift").matches("Sources/AgentCoding/SidebarView.swift"))
        #expect(!Glob("Sources/AgentCoding/*View.swift").matches("Sources/AgentCoding/sub/SidebarView.swift"))
        #expect(Glob("Sources/**/*.swift").matches("Sources/a/b/c.swift"))
        #expect(Glob("Sources/**/*.swift").matches("Sources/c.swift"))
    }

    @Test("a long function's hook closures and switch cases are entries of their own")
    func segments() {
        let filler = String(repeating: "        let _ = 1\n", count: Inventory.splitAboveLines)
        func src(_ hook: String, _ caseBody: String) -> String {
            "struct S { func wire(server: Server) {\n\(filler)        server.onA = { \(hook) }\n        server.onB = { b() }\n        switch x {\n        case 1: \(caseBody)\n        default: break\n        }\n    } }"
        }
        let a = Inventory.scan(source: src("a()", "one()"), file: "s.swift", fileInLinuxBuild: false)
        let b = Inventory.scan(source: src("a2()", "one()"), file: "s.swift", fileInLinuxBuild: false)
        let ids = a.map(\.id)
        #expect(ids == ["S.wire(server: Server)", "S.wire(server: Server) / server.onA",
                        "S.wire(server: Server) / server.onB", "S.wire(server: Server) / case 1:",
                        "S.wire(server: Server) / default:"])
        // A change inside one hook: only that entry's hash moves.
        let ha = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0.hash) })
        let hb = Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0.hash) })
        #expect(ha["S.wire(server: Server)"] == hb["S.wire(server: Server)"])
        #expect(ha["S.wire(server: Server) / server.onA"] != hb["S.wire(server: Server) / server.onA"])
        #expect(ha["S.wire(server: Server) / server.onB"] == hb["S.wire(server: Server) / server.onB"])
    }

    @Test("protocol requirements aren't functions; static members and same-named files in two modules stay apart")
    func collisions() {
        let r = Inventory.scan(source: """
            protocol P { var x: Int { get } ; var y: Int { get set } }
            extension P { var x: Int { 1 } }
            struct S { func f() { Self.f() } ; static func f() {} }
            """, file: "Sources/A/p.swift", fileInLinuxBuild: false)
        #expect(r.map(\.id) == ["P.var x", "S.f()", "S.static f()"])
        let a = Inventory.scan(source: "struct Q { func g() {} }", file: "Sources/A/Profile.swift", fileInLinuxBuild: false)
        let b = Inventory.scan(source: "struct Q { func g() { _ = 1 } }", file: "Sources/B/Profile.swift", fileInLinuxBuild: false)
        #expect(Inventory.disambiguate(a + b).map(\.id) == ["Q.g()@A/Profile.swift", "Q.g()@B/Profile.swift"])
    }

    @Test("an inheritance rule skips a UI type, its subclasses, and its extensions in other files")
    func inheritanceSkip() {
        let a = Inventory.scanFile(source: """
            struct Card: View { var body: some View { Text("") } }
            class Base: NSViewController { func load() {} }
            class Sub: Base { func more() {} }
            struct Model { func compute() {} }
            """, file: "Sources/A/a.swift", fileInLinuxBuild: false)
        let b = Inventory.scanFile(source: "extension Card { func helper() {} }",
                                   file: "Sources/A/b.swift", fileInLinuxBuild: false)
        var cfg = Self.config
        cfg.skipInheriting = [.init(bases: ["View", "NSViewController"], reason: "ui")]
        let r = Ledger.assemble(mac: a.records + b.records, linuxOnly: [], config: cfg,
                                inherits: a.inherits.merging(b.inherits) { $0.union($1) })
        let s = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.mac.id, $0.status) })
        #expect(s["Card.var body"] == .skipped)
        #expect(s["Card.helper()"] == .skipped)
        #expect(s["Base.load()"] == .skipped)
        #expect(s["Sub.more()"] == .skipped)
        #expect(s["Model.compute()"] == .todo)
    }
}
