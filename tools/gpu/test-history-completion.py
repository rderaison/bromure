#!/usr/bin/env python3
"""Run the actual native completion block using Foundation and fake text fields.

Also check source routing/guard invariants. No AppKit event-loop, VM, or native
focus acceptance is claimed. Requires Swift 6; --emit is review-only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

PRELUDE = r'''
import Foundation

struct Entry { let url: String }
final class Field { var stringValue = "" }
final class Editor {
    var string = ""
    var selection: NSRange?
    func setSelectedRange(_ range: NSRange) { selection = range }
}
final class Parent { var text = "" }
final class Completion {
    let parent = Parent()
    let field = Field()
    let editor = Editor()
    func apply(typed: String, urls: [String]) {
        let matches = urls.map { Entry(url: $0) }
'''

TESTS = r'''
    }
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
func check(_ name: String, _ typed: String, _ urls: [String], _ expected: String?) throws {
    let fixture = Completion()
    fixture.apply(typed: typed, urls: urls)
    guard let expected else {
        try require(fixture.editor.selection == nil && fixture.field.stringValue.isEmpty
                    && fixture.editor.string.isEmpty && fixture.parent.text.isEmpty,
                    "\(name): rejected completion mutated field")
        print("COMPLETION_CASE_PASS \(name)")
        return
    }
    let value = fixture.field.stringValue
    try require(Array(value.utf16) == Array(expected.utf16), "\(name): wrong exact UTF16 value \(value)")
    try require(fixture.editor.string == value && fixture.parent.text == value,
                "\(name): editor/model mismatch")
    let count = (typed as NSString).length
    try require(Array(value.utf16.prefix(count)) == Array(typed.utf16),
                "\(name): typed prefix changed normalization/case")
    guard let selection = fixture.editor.selection else { throw Failure("\(name): no suffix selection") }
    try require(selection.location == count && selection.length > 0
                && selection.location + selection.length == (value as NSString).length,
                "\(name): invalid UTF16 selection \(selection)")
    try require((value as NSString).substring(with: selection) == String(value.dropFirst(typed.count)),
                "\(name): selection did not cover suffix")
    print("COMPLETION_CASE_PASS \(name)")
}
@main struct Main {
    static func main() throws {
        try check("case", "EXa", ["https://example.test/path"], "EXample.test/path")
        try check("full-scheme", "https://EXa", ["https://example.test/path"], "https://EXample.test/path")
        try check("scheme-mismatch", "http://exa", ["https://example.test/path"], nil)
        try check("www-fallback", "exa", ["https://www.example.test/path"], "example.test/path")
        try check("www-preserved", "www.exa", ["https://www.example.test/path"], "www.example.test/path")
        try check("www-full-scheme", "https://exa", ["https://www.example.test/path"], nil)
        try check("ranked-first", "exa", ["https://example.test/first", "https://example.test/second"], "example.test/first")
        try check("skip-nonprefix", "exa", ["https://other.test/example", "https://example.test/next"], "example.test/next")
        try check("exact-no-suffix", "example.test", ["https://example.test"], nil)
        try check("no-match", "absent", ["https://example.test"], nil)
        try check("empty-reply", "exa", [], nil)
        try check("canonical-shorter-candidate", "e\u{301}x", ["https://éxample.test"], "e\u{301}xample.test")
        try check("canonical-longer-candidate", "ÉX", ["https://e\u{301}xample.test"], "ÉXample.test")
        try check("surrogate-pair", "😀x", ["https://😀xyz.test"], "😀xyz.test")
        try check("japanese", "日本", ["https://日本語.test"], "日本語.test")
        // The former lowercase-prefix/typed-offset implementation could
        // subtract 4 UTF16 units from a 3-unit candidate for this input.
        try check("casefold-length-shrink", "i\u{307}i\u{307}", ["https://İİx"], "i\u{307}i\u{307}x")
        print("BROMURE_HISTORY_COMPLETION_ACTUAL_BLOCK_PASS")
    }
}
'''


def source_parts(view, bridge):
    start = view.index('                let candidates = matches.flatMap')
    end_marker = '                self.parent.text = value'
    end = view.index(end_marker, start) + len(end_marker)
    block = view[start:end] + '\n'
    method = bridge[bridge.index('    public func historySuggestions('):
                    bridge.index('    private var pendingHistoryRequests:')]
    assert 'return await parent.historySuggestions(query: query)' in method
    assert method.index('guard currentFD >= 0') < method.index('withCheckedContinuation')
    assert 'writeCommand(["cmd": "query_history"' in method
    assert not re.search(r'\bsend\s*\(', method)
    assert 'commandGate' not in method and 'windowId' not in method and 'windowID' not in method
    assert 'pendingSuggestions.count < 32' in method
    assert 'UUID().uuidString' in method
    assert 'pendingSuggestions.removeValue(forKey: id)?.reply([])' in method
    reply = bridge[bridge.index('        case "history_suggestions":'):bridge.index('        case "history":')]
    assert 'obj["query"] as? String == request.query' in reply
    assert 'obj["status"] as? String == "ok"' in reply
    assert 'pendingSuggestions.removeValue(forKey: id)' in reply
    stop = bridge[bridge.index('    public func stop() {'):bridge.index('    // MARK: - Host → guest commands')]
    assert 'pendingSuggestions.removeAll()' in stop and 'replies.forEach { $0([]) }' in stop
    change = view[view.index('        func controlTextDidChange('):start]
    assert 'completionTask?.cancel(); completionGeneration += 1' in change
    assert 'self.completionGeneration == generation' in change
    assert '!Task.isCancelled' in change and 'self.parent.isEditing' in change
    assert 'field.stringValue == typed' in change
    assert change.count('!editor.hasMarkedText()') == 2
    assert change.count('editor.selectedRange().length == 0') == 2
    assert 'keyCode != 51' in change and 'keyCode != 117' in change
    return block, method


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--view', type=Path, default=ROOT/'Sources/Browser/NativeTabBarView.swift')
    parser.add_argument('--bridge', type=Path, default=ROOT/'Sources/BrowserBridges/TabBridge.swift')
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--emit', type=Path)
    parser.add_argument('--output-json', type=Path)
    args = parser.parse_args()
    view, bridge = args.view.read_text(), args.bridge.read_text()
    block, method = source_parts(view, bridge)
    generated = PRELUDE + block + TESTS
    digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
    result = dict(viewSHA256=digest(view), bridgeSHA256=digest(bridge),
                  blockSHA256=digest(block), methodSHA256=digest(method),
                  generatedSHA256=digest(generated), sourceRoutingChecks=True,
                  scope='Actual completion block, Foundation, fake fields; routing and edit guards checked statically, not native input')
    if args.emit:
        args.emit.write_text(generated)
        print(json.dumps(dict(result, emitted=str(args.emit))))
        return
    compiler = shutil.which(args.swiftc)
    if not compiler:
        raise RuntimeError('Swift unavailable; --emit never claims execution PASS')
    with tempfile.TemporaryDirectory(prefix='bromure-history-completion-') as directory:
        source = Path(directory)/'fixture.swift'
        executable = Path(directory)/'fixture'
        source.write_text(generated)
        subprocess.run([compiler, '-swift-version', '6', '-parse-as-library', str(source), '-o', str(executable)], check=True, timeout=90)
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        print(run.stdout, end=''); print(run.stderr, end='')
        run.check_returncode()
        if 'BROMURE_HISTORY_COMPLETION_ACTUAL_BLOCK_PASS' not in run.stdout:
            raise RuntimeError('completion marker missing')
        result.update(passed=True, stdout=run.stdout, stderr=run.stderr)
        if args.output_json:
            args.output_json.write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
