import Crypto
import Foundation
import SwiftParser
import SwiftSyntax

/// One function-like declaration with a body: a func, init, deinit,
/// subscript, or computed/observed property.
public struct FunctionRecord: Codable, Equatable, Sendable {
    /// `Type.name(label: Type, …)` — stable across moves between files (the
    /// shared-core refactor moves a lot); `@<file>` is appended only when two
    /// declarations in the scanned roots would otherwise collide.
    public var id: String
    public let file: String
    public let line: Int
    /// SHA-256 of the body's tokens (trivia — whitespace, comments — left
    /// out), first 16 hex digits.
    public let hash: String
    public let lines: Int
    /// Which builds the declaration is in, from its file's build membership
    /// and every enclosing `#if`.
    public let inMacOS: Bool
    public let inLinux: Bool
    /// The `// @port …` lines in its leading trivia.
    public let ports: [PortAnnotation]
    /// `// @port-skip <reason>` in its leading trivia: deliberately not
    /// needed on Linux (only meaningful on a macOS-only declaration).
    public let skipReason: String?
    /// The enclosing types, outermost first (extensions name the extended
    /// type): what an inheritance skip rule matches.
    public var container: [String] = []
}

/// `// @port <macOS id> h=<hash> @<commit>`: this Linux declaration
/// implements that macOS function as it was at <commit>, when its body
/// hashed to <hash>.
public struct PortAnnotation: Codable, Equatable, Sendable {
    public let macID: String
    public let hash: String
    public let commit: String?
}

public enum Inventory {
    /// Every function-like declaration in `files`. `linuxBuild(file)` says
    /// whether a file is compiled into the Linux build at all.
    public static func scan(files: [String], root: URL, linuxBuild: (String) -> Bool) throws -> [FunctionRecord] {
        try scanWithTypes(files: files, root: root, linuxBuild: linuxBuild).records
    }

    /// The records, plus what each type (or extension of it) inherits from
    /// or conforms to, across all the files.
    public static func scanWithTypes(files: [String], root: URL, linuxBuild: (String) -> Bool) throws
        -> (records: [FunctionRecord], inherits: [String: Set<String>]) {
        var all: [FunctionRecord] = []
        var inherits: [String: Set<String>] = [:]
        for rel in files {
            let url = root.appendingPathComponent(rel)
            let text = try String(contentsOf: url, encoding: .utf8)
            let (r, i) = scanFile(source: text, file: rel, fileInLinuxBuild: linuxBuild(rel))
            all += r
            inherits.merge(i) { $0.union($1) }
        }
        return (disambiguate(all), inherits)
    }

    public static func scan(source: String, file: String, fileInLinuxBuild: Bool,
                            fileInMacOSBuild: Bool = true) -> [FunctionRecord] {
        scanFile(source: source, file: file, fileInLinuxBuild: fileInLinuxBuild,
                 fileInMacOSBuild: fileInMacOSBuild).records
    }

    public static func scanFile(source: String, file: String, fileInLinuxBuild: Bool,
                                fileInMacOSBuild: Bool = true)
        -> (records: [FunctionRecord], inherits: [String: Set<String>]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: file, tree: tree)
        let v = Collector(file: file, converter: converter,
                          fileIn: [.macOS: fileInMacOSBuild, .linux: fileInLinuxBuild])
        v.walk(tree)
        return (v.records, v.inherits)
    }

    /// The types that inherit (directly, or through another type in the
    /// scan) from one of `bases`.
    public static func descendants(of bases: Set<String>, in inherits: [String: Set<String>]) -> Set<String> {
        var out = Set<String>()
        var changed = true
        while changed {
            changed = false
            for (t, sup) in inherits where !out.contains(t) {
                if !sup.isDisjoint(with: bases) || !sup.isDisjoint(with: out) { out.insert(t); changed = true }
            }
        }
        return out
    }

    /// Same id twice: keep the first plain only when the two are the two
    /// platform branches of one `#if` (that's a pair, not a collision);
    /// otherwise suffix every member with its file.
    static func disambiguate(_ records: [FunctionRecord]) -> [FunctionRecord] {
        var byID: [String: [Int]] = [:]
        for (i, r) in records.enumerated() { byID[r.id, default: []].append(i) }
        var out = records
        for (_, idx) in byID where idx.count > 1 {
            let files = Set(idx.map { records[$0].file })
            guard files.count > 1 else { continue }
            // The path below Sources/: two modules can both have a Profile.swift.
            for i in idx {
                let f = records[i].file
                out[i].id = records[i].id + "@" + (f.hasPrefix("Sources/") ? String(f.dropFirst(8)) : f)
            }
        }
        return out
    }

    /// The body's token texts, joined by single spaces: formatting and
    /// comments don't change the hash, code does.
    static func bodyHash(_ node: some SyntaxProtocol) -> String {
        bodyHash(node, excluding: [])
    }

    /// The hash with each `excluded` segment replaced by its label: a parent
    /// whose hook closures or switch cases are tracked as entries of their
    /// own doesn't change when only one of them does.
    static func bodyHash(_ node: some SyntaxProtocol, excluding: [Segment]) -> String {
        var parts: [String] = []
        let segs = excluding.sorted { $0.node.position < $1.node.position }
        var i = 0
        var marked = -1   // the segment whose label is already in `parts`
        for t in node.tokens(viewMode: .sourceAccurate) {
            while i < segs.count, t.position >= segs[i].node.endPosition { i += 1 }
            if i < segs.count, t.position >= segs[i].node.position {
                if marked != i { parts.append("\u{1}" + segs[i].label); marked = i }
                continue
            }
            parts.append(t.text)
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: " ").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A part of a long function tracked as an entry of its own.
    struct Segment {
        let label: String
        let node: Syntax
    }

    /// Bodies longer than this are split into segments.
    static let splitAboveLines = 120

    /// The long function's own top-level statements that are worth their
    /// own entry: `x.onFoo = { … }` hook closures, and the cases of a
    /// top-level `switch`. Labels repeated within one function get `#2`, `#3`.
    static func segments(of body: CodeBlockSyntax) -> [Segment] {
        var out: [Segment] = []
        var seen: [String: Int] = [:]
        func add(_ label: String, _ node: some SyntaxProtocol) {
            let n = (seen[label] ?? 0) + 1
            seen[label] = n
            out.append(Segment(label: n == 1 ? label : "\(label) #\(n)", node: Syntax(node)))
        }
        for item in body.statements {
            if let seq = item.item.as(SequenceExprSyntax.self) {
                let els = Array(seq.elements)
                if els.count == 3, els[1].is(AssignmentExprSyntax.self), els[2].is(ClosureExprSyntax.self) {
                    add(els[0].trimmedDescription.replacingOccurrences(of: " ", with: ""), item)
                }
            } else if let sw = item.item.as(ExpressionStmtSyntax.self)?.expression.as(SwitchExprSyntax.self)
                        ?? item.item.as(SwitchExprSyntax.self) {
                for c in sw.cases {
                    guard let sc = c.as(SwitchCaseSyntax.self) else { continue }
                    add(sc.label.trimmedDescription.replacingOccurrences(of: "\n", with: " "), sc)
                }
            }
        }
        return out
    }

    static func annotations(in trivia: Trivia) -> (ports: [PortAnnotation], skip: String?) {
        var ports: [PortAnnotation] = []
        var skip: String?
        for piece in trivia {
            guard case .lineComment(let text) = piece else { continue }
            let body = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("@port-skip") {
                skip = String(body.dropFirst("@port-skip".count)).trimmingCharacters(in: .whitespaces)
                if skip?.isEmpty == true { skip = "unspecified" }
            } else if body.hasPrefix("@port ") {
                if let a = parsePort(String(body.dropFirst("@port ".count))) { ports.append(a) }
            }
        }
        return (ports, skip)
    }

    /// `<id> h=<hash> @<commit>`; the id may contain spaces (parameter types).
    static func parsePort(_ s: String) -> PortAnnotation? {
        guard let h = s.range(of: " h=", options: .backwards) else { return nil }
        let id = s[..<h.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = s[h.upperBound...].split(separator: " ")
        guard let hash = rest.first, !id.isEmpty else { return nil }
        let commit = rest.dropFirst().first.map { String($0.drop(while: { $0 == "@" })) }
        return PortAnnotation(macID: id, hash: String(hash), commit: commit)
    }
}

private final class Collector: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    var records: [FunctionRecord] = []
    /// Type → what its declaration and extensions inherit from.
    var inherits: [String: Set<String>] = [:]
    /// Enclosing type names (extensions contribute their extended type).
    var typeStack: [String] = []
    /// Whether every enclosing `#if` clause is active, per platform.
    var active: [Platform: [Bool]]

    init(file: String, converter: SourceLocationConverter, fileIn: [Platform: Bool]) {
        self.file = file
        self.converter = converter
        self.active = [.macOS: [fileIn[.macOS] ?? true], .linux: [fileIn[.linux] ?? false]]
        super.init(viewMode: .sourceAccurate)
    }

    private func isIn(_ p: Platform) -> Bool { active[p]!.allSatisfy { $0 } }

    // MARK: #if — each clause is active when its condition holds and no
    // earlier clause's did.
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        var earlier: [Platform: Bool] = [.macOS: false, .linux: false]
        for clause in node.clauses {
            var now: [Platform: Bool] = [:]
            for p in Platform.allCases {
                let holds = clause.condition.map { ConditionEvaluator.evaluate($0, for: p) } ?? true
                now[p] = holds && !earlier[p]!
                earlier[p] = earlier[p]! || holds
            }
            for p in Platform.allCases { active[p]!.append(now[p]!) }
            if let elements = clause.elements { walk(elements) }
            for p in Platform.allCases { active[p]!.removeLast() }
        }
        return .skipChildren
    }

    // MARK: types
    private func enter(_ name: String, _ clause: InheritanceClauseSyntax? = nil) {
        typeStack.append(name)
        // Generic arguments and module qualifiers aside: `SwiftUI.View`, `NSViewRepresentable`.
        let sup = (clause?.inheritedTypes ?? []).map {
            $0.type.trimmedDescription.components(separatedBy: "<")[0].components(separatedBy: ".").last ?? ""
        }
        inherits[name, default: []].formUnion(sup)
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.inheritanceClause); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.inheritanceClause); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text, node.inheritanceClause); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.extendedType.trimmedDescription, node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    // MARK: function-likes. Their bodies are hashed whole (local functions
    // and closures included), so the walk doesn't descend into them.
    private func params(_ clause: FunctionParameterClauseSyntax) -> String {
        clause.parameters.map { p in
            "\(p.firstName.text): \(p.type.trimmedDescription.replacingOccurrences(of: " ", with: ""))"
        }.joined(separator: ", ")
    }

    private static func lines(_ node: some SyntaxProtocol) -> Int {
        node.trimmedDescription.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
    }

    private func record(_ name: String, decl: some SyntaxProtocol, body: (some SyntaxProtocol)?) {
        guard let body else { return }
        let prefix = typeStack.isEmpty ? "" : typeStack.joined(separator: ".") + "."
        let loc = converter.location(for: decl.positionAfterSkippingLeadingTrivia)
        let ann = Inventory.annotations(in: decl.leadingTrivia)
        let lineCount = Self.lines(body)
        let segments = lineCount > Inventory.splitAboveLines
            ? (Syntax(body).as(CodeBlockSyntax.self).map(Inventory.segments) ?? []) : []
        let id = prefix + name
        records.append(FunctionRecord(
            id: id, file: file, line: loc.line,
            hash: Inventory.bodyHash(body, excluding: segments),
            lines: lineCount - segments.reduce(0) { $0 + Self.lines($1.node) },
            inMacOS: isIn(.macOS), inLinux: isIn(.linux),
            ports: ann.ports, skipReason: ann.skip, container: typeStack))
        // Each segment: its own entry, `<parent id> / <label>`. A Linux
        // port annotates the code that implements it the same way.
        for seg in segments {
            let segAnn = Inventory.annotations(in: seg.node.leadingTrivia)
            records.append(FunctionRecord(
                id: id + " / " + seg.label, file: file,
                line: converter.location(for: seg.node.positionAfterSkippingLeadingTrivia).line,
                hash: Inventory.bodyHash(seg.node), lines: Self.lines(seg.node),
                inMacOS: isIn(.macOS), inLinux: isIn(.linux),
                ports: segAnn.ports, skipReason: segAnn.skip ?? ann.skip, container: typeStack))
        }
    }

    /// `static ` / `class ` members are other declarations than the
    /// instance ones they often forward to.
    private func staticPrefix(_ mods: DeclModifierListSyntax) -> String {
        mods.contains { $0.name.text == "static" || $0.name.text == "class" } ? "static " : ""
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record("\(staticPrefix(node.modifiers))\(node.name.text)(\(params(node.signature.parameterClause)))",
               decl: node, body: node.body)
        return .skipChildren
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record("init(\(params(node.signature.parameterClause)))", decl: node, body: node.body)
        return .skipChildren
    }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record("deinit", decl: node, body: node.body)
        return .skipChildren
    }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        record("subscript(\(params(node.parameterClause)))", decl: node, body: node.accessorBlock)
        return .skipChildren
    }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Computed and observed properties carry code; stored ones don't
        // (their initializers are hashed with the type's other members only
        // when they're a closure call — rare enough to leave out).
        for b in node.bindings {
            guard let accessors = b.accessorBlock else { continue }
            // A protocol requirement (`{ get }`, `{ get set }`) has no code.
            if case .accessors(let list) = accessors.accessors, list.allSatisfy({ $0.body == nil }) { continue }
            record("\(staticPrefix(node.modifiers))var \(b.pattern.trimmedDescription)", decl: node, body: accessors)
        }
        return .skipChildren
    }
    // Function bodies at top level of a closure-free context only.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}
