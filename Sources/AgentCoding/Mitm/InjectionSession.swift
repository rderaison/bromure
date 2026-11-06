import Foundation

/// One loaded detector model as PromptInjectionClassifier runs it: the
/// inputs the exported graph declares, and its output's float values for
/// int64 inputs that share one shape. Built by `InjectionRuntime.session`,
/// which each platform supplies (macOS: onnxruntime's Objective-C package,
/// InjectionSessionORT.swift).
protocol InjectionSession: AnyObject {
    var inputNames: Set<String> { get }
    func run(_ inputs: [String: [Int64]], shape: [Int]) throws -> [Float]
}
