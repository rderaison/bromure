import Foundation
import OnnxRuntimeBindings

// What PromptInjectionClassifier needs that's Apple's: onnxruntime's
// Objective-C package, and Foundation's sentence boundaries. Linux has its
// own (onnxruntime's C API, loaded with dlopen).

/// A detector model on onnxruntime's Objective-C package: what
/// PromptInjectionClassifier did inline before it ran models through
/// InjectionSession.
final class ORTInjectionSession: InjectionSession {
    private let env: ORTEnv
    private let session: ORTSession
    let inputNames: Set<String>

    init(modelPath: String) throws {
        // ONNX session on the CPU execution provider by default. The CoreML
        // EP balloons resident memory ~5x (a 288 MB model → ~5 GB; both
        // detectors → ~9 GB): it partitions a transformer into ~160 subgraphs
        // and keeps the ORT graph AND the compiled CoreML copies in RAM.
        // Detection is off the hot path and verdict-cached (each unique span
        // is scored once per session), so the ANE speed isn't worth that
        // footprint sitting next to the VM. CPU holds both models in ~2 GB at
        // identical accuracy. Opt back into CoreML with
        // BROMURE_INJECTION_COREML=1; BROMURE_NO_COREML still forces CPU.
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(.all)
        let useCoreML = ORTIsCoreMLExecutionProviderAvailable()
            && ProcessInfo.processInfo.environment["BROMURE_INJECTION_COREML"] == "1"
            && ProcessInfo.processInfo.environment["BROMURE_NO_COREML"] == nil
        if useCoreML {
            let coreml = ORTCoreMLExecutionProviderOptions()
            coreml.enableOnSubgraphs = true
            try opts.appendCoreMLExecutionProvider(with: coreml)
        }
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)
        self.env = env
        self.session = session
        self.inputNames = Set(try session.inputNames())
    }

    func run(_ inputs: [String: [Int64]], shape: [Int]) throws -> [Float] {
        let dims = shape.map { $0 as NSNumber }
        var values: [String: ORTValue] = [:]
        for (name, arr) in inputs {
            let data = NSMutableData(bytes: arr, length: arr.count * MemoryLayout<Int64>.size)
            values[name] = try ORTValue(tensorData: data, elementType: .int64, shape: dims)
        }
        let outputs = try session.run(
            withInputs: values,
            outputNames: Set(try session.outputNames()),
            runOptions: nil)
        guard let logitsValue = outputs.values.first else { return [] }
        let data = try logitsValue.tensorData() as Data
        let count = data.count / MemoryLayout<Float>.size
        var logits = [Float](repeating: 0, count: count)
        _ = logits.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        return logits
    }
}

enum InjectionRuntime {
    /// The detector session for the model at `modelPath`.
    static func session(modelPath: String) throws -> any InjectionSession {
        try ORTInjectionSession(modelPath: modelPath)
    }
}

extension PromptInjectionClassifier {
    /// The text's sentences, each split at its line breaks, trimmed, the
    /// empty ones dropped (the fine pass's windows are built from them).
    static func sentences(in body: String) -> [String] {
        var sentences: [String] = []
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            for line in body[r].split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
            }
        }
        return sentences
    }
}
