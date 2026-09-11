import Foundation
import Testing
@testable import bromure_ac

// The case that motivated heredoc-aware command cards: modern agents write files
// through `bash` running an interpreter heredoc (or `cat > f <<EOF`), not the
// structured Write tool. Left whole those render as one opaque monospace wall;
// these pin the split into (launcher, highlighted body) + the write-target scan.
@Suite("Heredoc-aware shell command rendering")
struct HeredocParserTests {

    // A faithful reduction of the real transcript command: a python heredoc that
    // reads two files, rewrites them in place, and writes them back via
    // `open(var,'w')` where the paths are bound to locals earlier in the script.
    private let pythonWrite = """
    python3 - <<'PY'
    p='/home/ubuntu/.claude/projects/-home-ubuntu-comelit/memory/homebridge-onvif-luxsensor.md'
    s=open(p).read()
    s=s.replace('old desc','new desc')
    s=s.rstrip('\\n')+'''

    **v1.5.0 (deployed 2026-09-02): measured radiation is primary.**
    '''
    open(p,'w').write(s)
    idx='/home/ubuntu/.claude/projects/-home-ubuntu-comelit/memory/MEMORY.md'
    m=open(idx).read().replace('a','b')
    open(idx,'w').write(m)
    print('memory ok')
    PY
    """

    @Test("python3 heredoc: launcher split out, body highlighted as python")
    func pythonHeredocSplit() {
        let segs = HeredocParser.segments(pythonWrite)
        #expect(segs.count == 2)

        guard case .shell(let launcher) = segs[0] else {
            Issue.record("first segment should be the shell launcher"); return
        }
        #expect(launcher == "python3 - <<'PY'")

        guard case .heredoc(let target, let language, let content) = segs[1] else {
            Issue.record("second segment should be the heredoc body"); return
        }
        #expect(target == nil)                       // no redirect → inline script
        #expect(language == "python")                // inferred from `python3`
        #expect(content.contains("open(p,'w').write(s)"))
        #expect(content.contains("print('memory ok')"))
        #expect(!content.contains("PY"))             // terminator consumed, not shown
    }

    @Test("write-scan resolves open(var,'w') through local path bindings")
    func pythonWriteTargets() {
        let targets = FileWriteScan.targets(in: pythonWrite)
        #expect(targets.count == 2)
        #expect(targets.contains { $0.hasSuffix("homebridge-onvif-luxsensor.md") })
        #expect(targets.contains { $0.hasSuffix("MEMORY.md") })
    }

    // `cat > path <<EOF` is the other ubiquitous idiom — here the heredoc body IS
    // the file, so the target names the block and the language comes from its ext.
    private let catWrite = """
    cat > /etc/app/config.yaml <<'EOF'
    server:
      port: 8080
    EOF
    echo done
    """

    @Test("cat > file heredoc: target + language from the redirect path")
    func catHeredoc() {
        let segs = HeredocParser.segments(catWrite)
        #expect(segs.count == 3)                      // launcher, body, trailing echo

        guard case .heredoc(let target, let language, let content) = segs[1] else {
            Issue.record("second segment should be the heredoc body"); return
        }
        #expect(target == "/etc/app/config.yaml")
        #expect(language == "yaml")                   // from the .yaml extension
        #expect(content == "server:\n  port: 8080")

        guard case .shell(let tail) = segs[2] else {
            Issue.record("third segment should be the trailing command"); return
        }
        #expect(tail == "echo done")

        #expect(FileWriteScan.targets(in: catWrite).contains("/etc/app/config.yaml"))
    }

    @Test("delimiter name is the last-resort language hint")
    func delimiterHint() {
        let sql = """
        psql mydb <<SQL
        select 1;
        SQL
        """
        guard case .heredoc(_, let language, _) = HeredocParser.segments(sql).first(where: {
            if case .heredoc = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a heredoc segment"); return
        }
        // psql interpreter already implies sql; the point is a non-"code" result.
        #expect(language == "sql")
    }

    @Test("a plain command stays a single shell segment")
    func noHeredoc() {
        let segs = HeredocParser.segments("grep -rn 'foo' src/ | head")
        #expect(segs.count == 1)
        #expect(segs.first == .shell("grep -rn 'foo' src/ | head"))
        #expect(FileWriteScan.targets(in: "grep -rn 'foo' src/ | head").isEmpty)
    }
}
