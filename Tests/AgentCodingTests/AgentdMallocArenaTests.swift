import Foundation
import Testing

/// Board report: bromure-agentd.py at 318 MB in a codereview guest. Its own
/// numbers: 52 threads, no connection open, 308 MB anonymous, 165 MB of it in
/// glibc's per-thread arenas. Not Python holding data: malloc keeping large
/// transients it freed, once its mmap threshold had risen. agentd now fixes
/// that threshold, and relays bytes through one reused buffer.
@Suite("agentd keeps large transients out of glibc's arenas, and relays without allocating")
struct AgentdMallocArenaTests {
    private static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")

    private func python(_ script: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", """
            import importlib.util
            s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            """ + "\n" + script]
        p.currentDirectoryURL = Self.dir
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("a fixed mmap threshold, asked first thing; never raises")
    func arenas() throws {
        let out = try python("""
            class Libc:
                def __init__(self, r): self.r, self.calls = r, []
                def mallopt(self, opt, val):
                    if isinstance(self.r, Exception): raise self.r
                    self.calls.append((opt.value, val.value)); return self.r
            ok = Libc(1); m._LIBC[:] = [ok]
            print("took:", m.fix_mmap_threshold(), ok.calls)
            m._LIBC[:] = [Libc(0)]
            print("refused:", m.fix_mmap_threshold())
            m._LIBC[:] = [Libc(AttributeError("mallopt"))]
            print("no such call:", m.fix_mmap_threshold())
            src = open("bromure-agentd.py").read()
            main = src.split("def main():", 1)[1]
            print("first:", main.index("fix_mmap_threshold()") < main.index("signal.signal"))
            print("before services:", main.index("fix_mmap_threshold()") < main.index("start_service("))
            print("no arena cap:", "M_ARENA_MAX" not in src)
            """)
        for line in ["took: True [(-3, 131072)]", "refused: False", "no such call: False",
                     "first: True", "before services: True", "no arena cap: True"] {
            #expect(out.contains(line), Comment(rawValue: out))
        }
    }

    @Test("the relay moves every byte through one buffer, and both pumps use it")
    func relay() throws {
        let out = try python("""
            import os, socket, threading
            a, b = socket.socketpair(); c, d = socket.socketpair()
            data = os.urandom(1_000_000)
            seen = []
            def feed():
                a.sendall(data); a.shutdown(socket.SHUT_WR)
            threading.Thread(target=feed).start()
            got = bytearray()
            def drain():
                while True:
                    x = d.recv(65536)
                    if not x: break
                    got.extend(x)
            t = threading.Thread(target=drain); t.start()
            moved = [0]
            n = m._relay(b, c, on_first=seen.append, moved=moved)
            c.shutdown(socket.SHUT_WR); t.join()
            print("exact:", bytes(got) == data, n == len(data), moved[0] == len(data))
            print("first chunk:", len(seen) == 1 and data.startswith(seen[0]))
            src = open("bromure-agentd.py").read()
            pump = src.split("def _bridge_pump(", 1)[1].split("\\ndef ", 1)[0]
            pipe = src.split("def _loopback_pipe(", 1)[1].split("\\ndef ", 1)[0]
            print("pumps:", "_relay(src, dst)" in pump and ".recv(" not in pump,
                  "_relay(src, dst" in pipe and ".recv(" not in pipe)
            print("report:", m.memory_report().split(",")[1:])
            """)
        for line in ["exact: True True True", "first chunk: True", "pumps: True True"] {
            #expect(out.contains(line), Comment(rawValue: out))
        }
        #expect(out.contains("threads") && out.contains("bridges"), Comment(rawValue: out))
    }
}
