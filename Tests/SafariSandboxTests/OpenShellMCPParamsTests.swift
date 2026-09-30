import Foundation
import Testing
@testable import SandboxEngine

/// Expectations below were produced by running each payload through
/// tower-mcp-types 0.22.2 itself (`serde_json::from_value::<T>` + the extra
/// checks in `inspection::mcp::validate_params`), so they are ground truth
/// for the Rust implementation, including serde's less obvious acceptances
/// (struct seq forms, `{"info": null}` unit variants, Content-only variant
/// indices, `_meta` key filtering).
@Suite("OpenShellMCPParams")
struct OpenShellMCPParamsTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let validator: String
        let label: String
        let accepted: Bool
        let json: String
        let revision: String

        init(_ validator: String, _ label: String, _ accepted: Bool, _ json: String, revision: String = "2025-11-25") {
            self.validator = validator
            self.label = label
            self.accepted = accepted
            self.json = json
            self.revision = revision
        }

        var testDescription: String { "\(validator): \(label)" }
    }

    static let cases: [Case] = [
        Case("Object", "any object", true, #"{"anything": [1, 2]}"#),
        Case("Initialize", "minimal", true, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "missing clientInfo", false, #"{"protocolVersion": "x", "capabilities": {}}"#),
        Case("Initialize", "protocolVersion number", false, #"{"protocolVersion": 1, "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "nested version number", false, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "c", "version": 2}}"#),
        Case("Initialize", "bool field null", false, #"{"protocolVersion": "2025-06-18", "capabilities": {"roots": {"listChanged": null}}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "extension without prefix", false, #"{"protocolVersion": "2025-06-18", "capabilities": {"extensions": {"noprefix": {}}}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "extension settings not object", false, #"{"protocolVersion": "2025-06-18", "capabilities": {"extensions": {"io.x/y": 1}}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "extension ok", true, #"{"protocolVersion": "2025-06-18", "capabilities": {"extensions": {"io.x/y": {}}}, "clientInfo": {"name": "c", "version": "1"}}"#),
        Case("Initialize", "clientInfo seq form", true, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": ["c", "1", null, null, null, null]}"#),
        Case("Initialize", "clientInfo short seq form", false, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": ["c", "1"]}"#),
        Case("Initialize", "_meta not object", false, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}, "_meta": 5}"#),
        Case("Initialize", "_meta bad key dropped", true, #"{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}, "_meta": {"bad key!": 1}}"#),
        Case("Complete", "minimal", true, #"{"ref": {"type": "ref/prompt", "name": "p"}, "argument": {"name": "a", "value": "v"}}"#),
        Case("Complete", "missing argument", false, #"{"ref": {"type": "ref/prompt", "name": "p"}}"#),
        Case("Complete", "unknown tag", false, #"{"ref": {"type": "ref/other", "name": "p"}, "argument": {"name": "a", "value": "v"}}"#),
        Case("Complete", "numeric tag via Value", false, #"{"ref": {"type": 0, "name": "p"}, "argument": {"name": "a", "value": "v"}}"#),
        Case("Complete", "resource missing uri", false, #"{"ref": {"type": "ref/resource", "name": "p"}, "argument": {"name": "a", "value": "v"}}"#),
        Case("Complete", "tagged seq form", true, #"{"ref": ["ref/prompt", "p"], "argument": {"name": "a", "value": "v"}}"#),
        Case("Complete", "context argument number", false, #"{"ref": {"type": "ref/prompt", "name": "p"}, "argument": {"name": "a", "value": "v"}, "context": {"arguments": {"a": 1}}}"#),
        Case("SetLogLevel", "minimal", true, #"{"level": "debug"}"#),
        Case("SetLogLevel", "missing level", false, #"{}"#),
        Case("SetLogLevel", "unknown level", false, #"{"level": "verbose"}"#),
        Case("SetLogLevel", "level map form", true, #"{"level": {"info": null}}"#),
        Case("SetLogLevel", "level map form empty object payload", false, #"{"level": {"info": {}}}"#),
        Case("SetLogLevel", "meta logLevel invalid", false, #"{"level": "info", "_meta": {"io.modelcontextprotocol/logLevel": "nope"}}"#),
        Case("SetLogLevel", "meta progressToken float", false, #"{"level": "info", "_meta": {"progressToken": 1.5}}"#),
        Case("GetPrompt", "minimal", true, #"{"name": "p"}"#),
        Case("GetPrompt", "missing name", false, #"{"arguments": {}}"#),
        Case("GetPrompt", "arguments null", false, #"{"name": "p", "arguments": null}"#),
        Case("GetPrompt", "argument value number", false, #"{"name": "p", "arguments": {"a": 1}}"#),
        Case("GetPrompt", "inputResponse elicit", true, #"{"name": "p", "inputResponses": {"x": {"action": "accept"}}}"#),
        Case("GetPrompt", "inputResponse unknown", false, #"{"name": "p", "inputResponses": {"x": {"action": "maybe"}}}"#),
        Case("GetPrompt", "inputResponse roots", true, #"{"name": "p", "inputResponses": {"x": {"roots": []}}}"#),
        Case("GetPrompt", "inputResponse seq form roots", true, #"{"name": "p", "inputResponses": {"x": [[]]}}"#),
        Case("ListPrompts", "empty", true, #"{}"#),
        Case("ListPrompts", "null cursor + meta", true, #"{"cursor": null, "_meta": {"progressToken": "t", "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}"#),
        Case("ListPrompts", "cursor number", false, #"{"cursor": 5}"#),
        Case("ListPrompts", "meta clientInfo missing version", false, #"{"_meta": {"io.modelcontextprotocol/clientInfo": {"name": "x"}}}"#),
        Case("ListPrompts", "_meta array", false, #"{"_meta": []}"#),
        Case("ListResources", "empty", true, #"{}"#),
        Case("ListResources", "null cursor + meta", true, #"{"cursor": null, "_meta": {"progressToken": "t", "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}"#),
        Case("ListResources", "cursor number", false, #"{"cursor": 5}"#),
        Case("ListResources", "meta clientInfo missing version", false, #"{"_meta": {"io.modelcontextprotocol/clientInfo": {"name": "x"}}}"#),
        Case("ListResources", "_meta array", false, #"{"_meta": []}"#),
        Case("ListResourceTemplates", "empty", true, #"{}"#),
        Case("ListResourceTemplates", "null cursor + meta", true, #"{"cursor": null, "_meta": {"progressToken": "t", "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}"#),
        Case("ListResourceTemplates", "cursor number", false, #"{"cursor": 5}"#),
        Case("ListResourceTemplates", "meta clientInfo missing version", false, #"{"_meta": {"io.modelcontextprotocol/clientInfo": {"name": "x"}}}"#),
        Case("ListResourceTemplates", "_meta array", false, #"{"_meta": []}"#),
        Case("ListTools", "empty", true, #"{}"#),
        Case("ListTools", "null cursor + meta", true, #"{"cursor": null, "_meta": {"progressToken": "t", "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}}"#),
        Case("ListTools", "cursor number", false, #"{"cursor": 5}"#),
        Case("ListTools", "meta clientInfo missing version", false, #"{"_meta": {"io.modelcontextprotocol/clientInfo": {"name": "x"}}}"#),
        Case("ListTools", "_meta array", false, #"{"_meta": []}"#),
        Case("ReadResource", "minimal", true, #"{"uri": "file:///a"}"#),
        Case("ReadResource", "missing uri", false, #"{}"#),
        Case("ReadResource", "uri array", false, #"{"uri": ["file:///a"]}"#),
        Case("ReadResource", "nested meta error", false, #"{"uri": "u", "_meta": {"io.modelcontextprotocol/clientCapabilities": {"roots": {"listChanged": "yes"}}}}"#),
        Case("SubscribeResource", "minimal", true, #"{"uri": "file:///a"}"#),
        Case("SubscribeResource", "missing uri", false, #"{}"#),
        Case("SubscribeResource", "uri array", false, #"{"uri": ["file:///a"]}"#),
        Case("SubscribeResource", "nested meta error", false, #"{"uri": "u", "_meta": {"io.modelcontextprotocol/clientCapabilities": {"roots": {"listChanged": "yes"}}}}"#),
        Case("UnsubscribeResource", "minimal", true, #"{"uri": "file:///a"}"#),
        Case("UnsubscribeResource", "missing uri", false, #"{}"#),
        Case("UnsubscribeResource", "uri array", false, #"{"uri": ["file:///a"]}"#),
        Case("UnsubscribeResource", "nested meta error", false, #"{"uri": "u", "_meta": {"io.modelcontextprotocol/clientCapabilities": {"roots": {"listChanged": "yes"}}}}"#),
        Case("ReadResource", "requestState number", false, #"{"uri": "u", "requestState": 1}"#),
        Case("CallTool", "minimal", true, #"{"name": "t"}"#),
        Case("CallTool", "missing name", false, #"{"arguments": {}}"#),
        Case("CallTool", "arguments null ok", true, #"{"name": "t", "arguments": null}"#),
        Case("CallTool", "arguments string ok", true, #"{"name": "t", "arguments": "x"}"#),
        Case("CallTool", "name number", false, #"{"name": 1}"#),
        Case("CallTool", "ttl negative", false, #"{"name": "t", "task": {"ttl": -1}}"#),
        Case("CallTool", "ttl float", false, #"{"name": "t", "task": {"ttl": 1.5}}"#),
        Case("CallTool", "ttl 1.0", false, #"{"name": "t", "task": {"ttl": 1.0}}"#),
        Case("CallTool", "ttl u64 max", true, #"{"name": "t", "task": {"ttl": 18446744073709551615}}"#),
        Case("CallTool", "ttl beyond u64", false, #"{"name": "t", "task": {"ttl": 18446744073709551616}}"#),
        Case("CallTool", "progressToken beyond i64", false, #"{"name": "t", "_meta": {"progressToken": 9223372036854775808}}"#),
        Case("CallTool", "progressToken i64 min", true, #"{"name": "t", "_meta": {"progressToken": -9223372036854775808}}"#),
        Case("CallTool", "inputResponse createMessage", true, #"{"name": "t", "inputResponses": {"a": {"content": {"type": "text", "text": "x"}, "model": "m", "role": "user"}}}"#),
        Case("CallTool", "sampling tag variant index in Content", true, #"{"name": "t", "inputResponses": {"a": {"content": {"type": 0, "text": "x"}, "model": "m", "role": "user"}}}"#),
        Case("CallTool", "sampling tag index out of range", false, #"{"name": "t", "inputResponses": {"a": {"content": {"type": 5, "text": "x"}, "model": "m", "role": "user"}}}"#),
        Case("CallTool", "unit variant empty map in owned Content", true, #"{"name": "t", "inputResponses": {"a": {"content": {"type": "text", "text": "x", "annotations": {"audience": [{"user": {}}]}}, "model": "m", "role": "user"}}}"#),
        Case("CallTool", "unit variant empty map in Content ref", false, #"{"name": "t", "inputResponses": {"a": {"content": {"type": "text", "text": "x"}, "model": "m", "role": {"user": {}}}}}"#),
        Case("CallTool", "elicit field value mixed array", false, #"{"name": "t", "inputResponses": {"a": {"action": "accept", "content": {"f": [1]}}}}"#),
        Case("CreateMessage", "minimal", true, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 10}"#),
        Case("CreateMessage", "missing maxTokens", false, #"{"messages": []}"#),
        Case("CreateMessage", "maxTokens > u32", false, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 4294967296}"#),
        Case("CreateMessage", "maxTokens u32 max", true, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 4294967295}"#),
        Case("CreateMessage", "maxTokens negative", false, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": -1}"#),
        Case("CreateMessage", "image missing mimeType", false, #"{"messages": [{"role": "user", "content": {"type": "image", "data": "d"}}], "maxTokens": 10}"#),
        Case("CreateMessage", "tool_use missing input", false, #"{"messages": [{"role": "user", "content": [{"type": "tool_use", "id": "1", "name": "n"}]}], "maxTokens": 10}"#),
        Case("CreateMessage", "nested tool_result text number", false, #"{"messages": [{"role": "user", "content": [{"type": "tool_result", "toolUseId": "1", "content": [{"type": "text", "text": 1}]}]}], "maxTokens": 10}"#),
        Case("CreateMessage", "tool inputSchema null ok", true, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 10, "tools": [{"name": "t", "inputSchema": null}]}"#),
        Case("CreateMessage", "tool missing inputSchema", false, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 10, "tools": [{"name": "t"}]}"#),
        Case("CreateMessage", "includeContext allServers", true, #"{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}], "maxTokens": 10, "includeContext": "allServers"}"#),
        Case("ListRoots", "empty", true, #"{}"#),
        Case("ListRoots", "_meta string", false, #"{"_meta": "x"}"#),
        Case("Elicit", "form 2025-06-18", true, #"{"message": "m", "requestedSchema": {"type": "object", "properties": {"a": {"type": "string"}}}}"#, revision: "2025-06-18"),
        Case("Elicit", "url under 2025-06-18 rejected", false, #"{"mode": "url", "elicitationId": "e", "message": "m", "url": "u"}"#, revision: "2025-06-18"),
        Case("Elicit", "url under 2025-11-25 ok", true, #"{"mode": "url", "elicitationId": "e", "message": "m", "url": "u"}"#),
        Case("Elicit", "missing schema", false, #"{"message": "m"}"#),
        Case("Elicit", "integer schema float minimum", false, #"{"message": "m", "requestedSchema": {"type": "object", "properties": {"a": {"type": "integer", "minimum": 1.5}}}}"#),
        Case("Elicit", "enum null counts as present", false, #"{"message": "m", "requestedSchema": {"type": "object", "properties": {"a": {"type": "string", "enum": null}}}}"#),
        Case("Elicit", "non-string type is Raw", true, #"{"message": "m", "requestedSchema": {"type": "object", "properties": {"a": {"type": 7}}}}"#),
        Case("GetTask", "minimal", true, #"{"taskId": "t"}"#),
        Case("GetTask", "missing taskId", false, #"{}"#),
        Case("GetTask", "taskId number", false, #"{"taskId": 7}"#),
        Case("GetTaskResult", "minimal", true, #"{"taskId": "t"}"#),
        Case("GetTaskResult", "missing taskId", false, #"{}"#),
        Case("GetTaskResult", "taskId number", false, #"{"taskId": 7}"#),
        Case("CancelTask", "minimal", true, #"{"taskId": "t"}"#),
        Case("CancelTask", "missing taskId", false, #"{}"#),
        Case("CancelTask", "taskId number", false, #"{"taskId": 7}"#),
        Case("CancelTask", "reason array", false, #"{"taskId": "t", "reason": []}"#),
        Case("ListTasks", "empty", true, #"{}"#),
        Case("ListTasks", "status", true, #"{"status": "input_required"}"#),
        Case("ListTasks", "status camelCase rejected", false, #"{"status": "inputRequired"}"#),
        Case("Discover", "empty", true, #"{}"#),
        Case("Discover", "empty struct nonempty seq", false, #"{"_meta": {"io.modelcontextprotocol/clientCapabilities": {"sampling": {"tools": [1]}}}}"#),
        Case("Discover", "empty struct empty seq", true, #"{"_meta": {"io.modelcontextprotocol/clientCapabilities": {"sampling": {"tools": []}}}}"#),
        Case("SubscriptionsListen", "minimal", true, #"{"notifications": {}}"#),
        Case("SubscriptionsListen", "missing notifications", false, #"{}"#),
        Case("SubscriptionsListen", "null notifications", false, #"{"notifications": null}"#),
        Case("SubscriptionsListen", "taskIds numbers", false, #"{"notifications": {"taskIds": [1]}}"#),
        Case("Cancelled", "minimal", true, #"{"requestId": 1}"#),
        Case("Cancelled", "missing requestId", false, #"{}"#),
        Case("Cancelled", "null requestId", false, #"{"requestId": null}"#),
        Case("Cancelled", "float requestId", false, #"{"requestId": 1.5}"#),
        Case("Cancelled", "negative requestId", true, #"{"requestId": -7, "reason": null}"#),
        Case("Cancelled", "reason number", false, #"{"requestId": "r", "reason": 1}"#),
        Case("Progress", "minimal", true, #"{"progressToken": "t", "progress": 0.5}"#),
        Case("Progress", "missing progress", false, #"{"progressToken": "t"}"#),
        Case("Progress", "bool token", false, #"{"progressToken": true, "progress": 1}"#),
        Case("Progress", "float token", false, #"{"progressToken": 1.0, "progress": 1}"#),
        Case("Progress", "progress string", false, #"{"progressToken": "t", "progress": "1"}"#),
        Case("LoggingMessage", "null data present", true, #"{"level": "info", "data": null}"#),
        Case("LoggingMessage", "missing data", false, #"{"level": "info"}"#),
        Case("LoggingMessage", "bad level", false, #"{"level": "loud", "data": 1}"#),
        Case("LoggingMessage", "logger number", false, #"{"level": "info", "data": 1, "logger": 1}"#),
        Case("ResourceUpdated", "minimal", true, #"{"uri": "u"}"#),
        Case("ResourceUpdated", "missing uri", false, #"{}"#),
        Case("ResourceUpdated", "uri number", false, #"{"uri": 1}"#),
        Case("ResourceUpdated", "meta not checked", true, #"{"uri": "u", "_meta": 7}"#),
        Case("TaskStatus", "minimal (ttl Option absent)", true, #"{"taskId": "t", "status": "working", "createdAt": "c", "lastUpdatedAt": "l"}"#),
        Case("TaskStatus", "missing createdAt", false, #"{"taskId": "t", "status": "working", "lastUpdatedAt": "l"}"#),
        Case("TaskStatus", "bad status", false, #"{"taskId": "t", "status": "done", "createdAt": "c", "lastUpdatedAt": "l"}"#),
        Case("TaskStatus", "negative ttl", false, #"{"taskId": "t", "status": "working", "createdAt": "c", "lastUpdatedAt": "l", "ttl": -1}"#),
        Case("TaskStatus", "float pollInterval", false, #"{"taskId": "t", "status": "working", "createdAt": "c", "lastUpdatedAt": "l", "pollInterval": 2.5}"#),
        Case("ElicitationComplete", "minimal", true, #"{"elicitationId": "e"}"#),
        Case("ElicitationComplete", "missing id", false, #"{}"#),
        Case("ElicitationComplete", "null id", false, #"{"elicitationId": null}"#),
        Case("SubscriptionsAcknowledged", "minimal", true, #"{"notifications": {}}"#),
        Case("SubscriptionsAcknowledged", "missing notifications", false, #"{}"#),
        Case("SubscriptionsAcknowledged", "subscriptionId float", false, #"{"notifications": {}, "_meta": {"io.modelcontextprotocol/subscriptionId": 1.5}}"#),
        Case("SubscriptionsAcknowledged", "nested bool string", false, #"{"notifications": {"toolsListChanged": "y"}}"#),
    ]

    private static func params(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("matches tower-mcp-types validate_params", arguments: cases)
    func matchesRust(_ testCase: Case) throws {
        let result = OpenShellMCPParams.validate(
            validator: testCase.validator,
            params: try Self.params(testCase.json),
            revision: testCase.revision
        )
        if testCase.accepted {
            #expect(result == nil, "expected accept, got: \(result ?? "")")
        } else {
            #expect(result != nil, "expected reject")
        }
    }

    @Test("every validator name is recognised")
    func everyValidatorKnown() {
        let names = [
            "Object", "Initialize", "Complete", "SetLogLevel", "GetPrompt", "ListPrompts", "ListResources",
            "ListResourceTemplates", "ReadResource", "SubscribeResource", "UnsubscribeResource", "CallTool",
            "ListTools", "CreateMessage", "ListRoots", "Elicit", "GetTask", "GetTaskResult", "ListTasks",
            "CancelTask", "Discover", "SubscriptionsListen", "Cancelled", "Progress", "LoggingMessage",
            "ResourceUpdated", "TaskStatus", "ElicitationComplete", "SubscriptionsAcknowledged",
        ]
        for name in names {
            // A garbage payload may be rejected, but never as an unknown validator.
            let result = OpenShellMCPParams.validate(validator: name, params: ["zz": 1], revision: "2025-11-25")
            #expect(result?.hasPrefix("unknown params validator") != true, "\(name)")
        }
        #expect(OpenShellMCPParams.validate(validator: "Nope", params: [:], revision: "2025-11-25") != nil)
    }

    @Test("Swift-literal NSNumbers classify like JSON numbers")
    func swiftLiteralNumbers() {
        // Bool must not pass as an integer, Double 1.0 must not pass as u64.
        #expect(OpenShellMCPParams.validate(validator: "CallTool", params: ["name": "t", "task": ["ttl": 5]], revision: "2025-11-25") == nil)
        #expect(OpenShellMCPParams.validate(validator: "CallTool", params: ["name": "t", "task": ["ttl": true]], revision: "2025-11-25") != nil)
        #expect(OpenShellMCPParams.validate(validator: "CallTool", params: ["name": "t", "task": ["ttl": 1.0]], revision: "2025-11-25") != nil)
        #expect(OpenShellMCPParams.validate(validator: "CallTool", params: ["name": "t", "task": ["ttl": UInt64.max]], revision: "2025-11-25") == nil)
        #expect(OpenShellMCPParams.validate(validator: "Progress", params: ["progressToken": 1, "progress": true], revision: "2025-11-25") != nil)
        #expect(OpenShellMCPParams.validate(validator: "Cancelled", params: ["requestId": NSNull()], revision: "2025-11-25") != nil)
    }
}
