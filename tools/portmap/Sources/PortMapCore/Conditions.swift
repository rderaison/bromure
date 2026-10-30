import SwiftSyntax

/// The two builds a function can be compiled into.
public enum Platform: String, CaseIterable, Codable, Sendable {
    case macOS, linux
}

/// Evaluates an `#if` condition for one platform. Unknown flags (`DEBUG`,
/// custom `-D`s) count as true on both, so a function is never silently
/// dropped from a build it may be in.
enum ConditionEvaluator {
    /// Modules that exist on Apple platforms only.
    static let appleOnlyModules: Set<String> = [
        "AppKit", "SwiftUI", "UIKit", "WebKit", "Virtualization", "Security", "CryptoKit",
        "CommonCrypto", "IOKit", "IOSurface", "ServiceManagement", "Network", "Combine",
        "os", "Darwin", "UniformTypeIdentifiers", "Charts", "MarkdownUI", "GhosttyKit",
        "CVmnet", "MLX", "MLXLLM", "MLXLMCommon", "MLXHuggingFace", "AVKit", "AVFoundation",
        "CoreGraphics", "CoreImage", "QuartzCore", "Metal", "MetalKit", "UserNotifications",
        "LocalAuthentication", "SystemConfiguration", "CoreServices", "Carbon", "Sparkle",
        "OnnxRuntimeBindings", "Observation", "PhotosUI", "QuickLook", "StoreKit",
    ]
    /// Modules that exist on Linux only.
    static let linuxOnlyModules: Set<String> = ["Glibc", "Musl", "FoundationNetworking"]

    static func evaluate(_ expr: ExprSyntax, for platform: Platform) -> Bool {
        if let e = expr.as(PrefixOperatorExprSyntax.self), e.operator.text == "!" {
            return !evaluate(e.expression, for: platform)
        }
        if let e = expr.as(TupleExprSyntax.self), e.elements.count == 1, let only = e.elements.first {
            return evaluate(only.expression, for: platform)
        }
        if let e = expr.as(InfixOperatorExprSyntax.self),
           let op = e.operator.as(BinaryOperatorExprSyntax.self) {
            switch op.operator.text {
            case "&&": return evaluate(e.leftOperand, for: platform) && evaluate(e.rightOperand, for: platform)
            case "||": return evaluate(e.leftOperand, for: platform) || evaluate(e.rightOperand, for: platform)
            default: return true
            }
        }
        // An unfolded `a && b || c` arrives as a sequence: fold it left to
        // right with && binding tighter than ||.
        if let seq = expr.as(SequenceExprSyntax.self) {
            return evaluateSequence(Array(seq.elements), for: platform)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text {
            let arg = call.arguments.first?.expression.trimmedDescription ?? ""
            switch name {
            case "os":
                switch arg {
                case "macOS", "OSX": return platform == .macOS
                case "Linux": return platform == .linux
                default: return false   // iOS, visionOS, Windows… are neither build
                }
            case "canImport":
                let module = arg.components(separatedBy: ".").first ?? arg
                if appleOnlyModules.contains(module) { return platform == .macOS }
                if linuxOnlyModules.contains(module) { return platform == .linux }
                return true
            case "targetEnvironment": return false
            default: return true      // compiler(>=), swift(>=), arch(), hasFeature()
            }
        }
        if let ref = expr.as(BooleanLiteralExprSyntax.self) { return ref.literal.text == "true" }
        return true
    }

    private static func evaluateSequence(_ elements: [ExprSyntax], for platform: Platform) -> Bool {
        // Split on ||, each part a chain of &&.
        var orParts: [[ExprSyntax]] = [[]]
        var i = 0
        while i < elements.count {
            let el = elements[i]
            if let op = el.as(BinaryOperatorExprSyntax.self) {
                if op.operator.text == "||" { orParts.append([]) }
            } else {
                orParts[orParts.count - 1].append(el)
            }
            i += 1
        }
        return orParts.contains { part in part.allSatisfy { evaluate($0, for: platform) } }
    }
}
