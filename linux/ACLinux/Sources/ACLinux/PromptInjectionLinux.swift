import COrtShim
import Dispatch
import Foundation
import NIOConcurrencyHelpers

// What PromptInjectionClassifier needs from its platform, on Linux (macOS:
// PromptInjectionClassifier+Apple.swift and ClassifierLifecycle.swift):
// onnxruntime's C API, loaded at run time, a serial executor for its queue,
// and sentence boundaries.

extension ClassifierQueue {
    /// A detector's queue: a serial executor over a dispatch queue of its
    /// own (corelibs Dispatch has no DispatchSerialQueue to be one).
    // @port-skip linux-only: macOS's is a DispatchSerialQueue (ClassifierLifecycle.swift)
    final class Executor: SerialExecutor, @unchecked Sendable {
        let queue: DispatchQueue
        // @port-skip linux-only: see Executor
        init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
        // @port-skip linux-only: see Executor
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            let me = asUnownedSerialExecutor()
            queue.async { job.runSynchronously(on: me) }
        }
        // @port-skip linux-only: see Executor
        func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
    }

    // @port ClassifierQueue.static make(_: String) h=9f79f0bb3a56789e @19b04b00
    static func make(_ label: String) -> Executor { Executor(label: "io.bromure.classifier.\(label)") }
}

/// onnxruntime, loaded once (dlopen): the distro's libonnxruntime1.23, or
/// BROMURE_ONNXRUNTIME=<path>. Missing or the wrong API: the detectors
/// don't load (readiness `.absent`), and only the rules pass runs.
// @port-skip linux-only: macOS links onnxruntime's Objective-C package
enum OnnxRuntimeLibrary {
    struct Unavailable: LocalizedError {
        let why: String
        // @port-skip linux-only: see OnnxRuntimeLibrary
        var errorDescription: String? { "onnxruntime isn't available: \(why)" }
    }
    private static let loaded = NIOLockedValueBox<String?>(nil)

    /// The library's version once it's loaded; throws why it can't be.
    // @port-skip linux-only: see OnnxRuntimeLibrary
    static func load() throws -> String {
        try loaded.withLockedValue { v in
            if let v { return v }
            var err = [CChar](repeating: 0, count: 512)
            let rc = ProcessInfo.processInfo.environment["BROMURE_ONNXRUNTIME"].map { p in
                p.withCString { acl_ort_load($0, &err, err.count) }
            } ?? acl_ort_load(nil, &err, err.count)
            guard rc == 0, let version = acl_ort_version() else { throw Unavailable(why: String(cString: err)) }
            let s = String(cString: version)
            v = s
            return s
        }
    }
}

/// A detector model on onnxruntime's C API (the CPU provider, graph
/// optimisations on, as macOS's default).
// @port-skip linux-only: ORTInjectionSession's (PromptInjectionClassifier+Apple.swift) on the C API
final class OrtCInjectionSession: InjectionSession, @unchecked Sendable {
    private let session: OpaquePointer
    let inputNames: Set<String>
    private let names: [String]
    /// Outputs past this many values are refused (64 Mi floats: 256 MiB).
    static let maxOutput = 64 << 20

    // partial: onnxruntime C API, no CoreML execution provider
    // @port ORTInjectionSession.init(modelPath: String, threads: Int32?, output: String?, coreML: Bool) h=aa3d3fd2bef9e9f0 @90004c7f
    init(modelPath: String, threads: Int32 = 0, output: String? = nil) throws {
        _ = try OnnxRuntimeLibrary.load()
        var err = [CChar](repeating: 0, count: 512)
        guard let s = acl_ort_session_create(modelPath, threads, &err, err.count) else {
            throw OnnxRuntimeLibrary.Unavailable(why: String(cString: err))
        }
        if let output, acl_ort_session_use_output(s, output, &err, err.count) < 0 {
            acl_ort_session_release(s)
            throw OnnxRuntimeLibrary.Unavailable(why: String(cString: err))
        }
        session = s
        names = (0..<acl_ort_input_count(s)).compactMap { acl_ort_input_name(s, $0).map { String(cString: $0) } }
        inputNames = Set(names)
    }

    // @port-skip linux-only: see OrtCInjectionSession
    deinit { acl_ort_session_release(session) }

    /// The first output's values for these inputs (int64, all `shape`).
    // @port ORTInjectionSession.run(_: [String:[Int64]], shape: [Int]) h=18409a9214b20050 @90004c7f
    func run(_ inputs: [String: [Int64]], shape: [Int]) throws -> [Float] {
        let fed = inputs.sorted { $0.key < $1.key }
        let count = shape.reduce(1, *)
        guard fed.allSatisfy({ $0.value.count == count }) else { throw OnnxRuntimeLibrary.Unavailable(why: "inputs don't fit the shape") }
        let cnames = fed.map { strdup($0.key) }
        defer { cnames.forEach { free($0) } }
        let bufs = fed.map { f -> UnsafeMutablePointer<Int64> in
            let p = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, f.value.count))
            p.initialize(from: f.value, count: f.value.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        let namePtrs = cnames.map { UnsafePointer($0) }
        let dataPtrs = bufs.map { UnsafePointer($0) as UnsafePointer<Int64>? }
        let dims = shape.map(Int64.init)
        // One run, the output copied at its own size (a token classifier's
        // is a score per token and label: far past a fixed buffer).
        var out: UnsafeMutablePointer<Float>?
        var n = 0
        var err = [CChar](repeating: 0, count: 512)
        let rc = namePtrs.withUnsafeBufferPointer { np in
            dataPtrs.withUnsafeBufferPointer { dp in
                acl_ort_run_int64_alloc(session, np.baseAddress, dp.baseAddress, fed.count, dims, dims.count,
                                        &out, Self.maxOutput, &n, &err, err.count)
            }
        }
        defer { free(out) }
        guard rc == 0, let out else { throw OnnxRuntimeLibrary.Unavailable(why: String(cString: err)) }
        return Array(UnsafeBufferPointer(start: out, count: n))
    }
}

enum InjectionRuntime {
    /// The detector session for the model at `modelPath`.
    // @port InjectionRuntime.static session(modelPath: String) h=8069851ee440c80b @90004c7f
    static func session(modelPath: String) throws -> any InjectionSession {
        try OrtCInjectionSession(modelPath: modelPath)
    }

    /// A token classifier's session (PIIDetector's): on the CPU with
    /// `threads` intra-op threads, reading `output` when the model has it.
    // @port InjectionRuntime.static tokenSession(modelPath: String, threads: Int32, output: String) h=37e4293e846cc074 @90004c7f
    static func tokenSession(modelPath: String, threads: Int32, output: String) throws -> any InjectionSession {
        try OrtCInjectionSession(modelPath: modelPath, threads: threads, output: output)
    }
}

extension PromptInjectionClassifier {
    /// The text's sentences, each split at its line breaks, trimmed, the
    /// empty ones dropped. corelibs Foundation has no sentence enumeration:
    /// a sentence ends at `.`, `!` or `?` followed by whitespace, or at a
    /// line break.
    // partial: an approximation of Foundation's sentence boundaries (abbreviations like "e.g. " end a sentence here); the fine pass's windows can differ slightly from macOS's
    // partial: own splitter instead of enumerateSubstrings(.bySentences)
    // @port PromptInjectionClassifier.static sentences(in: String) h=7a163982cc701c18 @90004c7f
    static func sentences(in body: String) -> [String] {
        var out: [String] = []
        func push(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
        }
        for line in body.split(whereSeparator: \.isNewline) {
            var cur = "", ended = false
            for ch in line {
                if ended, ch.isWhitespace { push(cur); cur = ""; ended = false; continue }
                cur.append(ch)
                ended = ch == "." || ch == "!" || ch == "?"
            }
            push(cur)
        }
        return out
    }
}
