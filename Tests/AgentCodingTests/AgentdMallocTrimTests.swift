import Foundation
import Testing

@Suite("agentd gives freed memory back")
struct AgentdMallocTrimTests {
    @Test("it asks to trim everything, says if that released any, and never raises")
    func trim() async throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", """
            import importlib.util
            s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            class Libc:
                def __init__(self, r): self.r, self.pads = r, []
                def malloc_trim(self, pad):
                    if isinstance(self.r, Exception): raise self.r
                    self.pads.append(pad.value); return self.r
            released = Libc(1); m._LIBC[:] = [released]
            print("released:", m.malloc_trim(), released.pads)
            m._LIBC[:] = [Libc(0)]
            print("nothing:", m.malloc_trim())
            m._LIBC[:] = [Libc(AttributeError("malloc_trim"))]
            print("no such call:", m.malloc_trim())
            print("service listed:", "malloc_trim_service" in open("bromure-agentd.py").read().split("services = [")[1])
            """]
        p.currentDirectoryURL = top.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        for line in ["released: True [0]", "nothing: False", "no such call: False", "service listed: True"] {
            #expect(out.contains(line), Comment(rawValue: out))
        }
    }
}
