import Foundation

/// Exact port of the typed `params` validation in tower-mcp-types 0.22.2
/// (`inspection/mcp.rs` → `validate_params`), i.e. whether
/// `serde_json::from_value::<T>(params)` succeeds for the method's params
/// struct, plus the hand-written checks `validate_params` adds on top.
///
/// The port models serde's data model rather than a JSON schema, so it keeps
/// serde's less obvious acceptances:
///
/// - every derived struct also deserializes from a JSON *array* ("seq form"):
///   elements map to the fields in declaration order, trailing fields may be
///   omitted only when they carry `#[serde(default)]` (an `Option` without
///   `default` is required in seq form), and surplus elements fail;
/// - `Option<T>` fields are optional in object form even without `default`;
///   a non-`Option` field without `default` (including `serde_json::Value`)
///   is required;
/// - externally tagged unit enums (`LogLevel`, `TaskStatus`, …) accept
///   `"info"` and also `{"info": null}`;
/// - internally tagged enums accept `[tag, field…]` arrays, and when they
///   are reached through buffered `Content` (inside an untagged enum) the tag
///   may also be a non-negative integer variant index;
/// - `_meta` fields using `meta_object_serde` accept `null`, reject any
///   non-object, silently drop keys that fail `validate_meta_key`, then
///   decode the remaining object into the target type;
/// - unknown fields are ignored everywhere (no `deny_unknown_fields` in the
///   crate), and there is no `flatten` on any reachable type.
///
/// Known, irreducible divergence: JSONSerialization collapses the JSON text
/// `-0` into the integer 0, while serde_json parses it as the float `-0.0`
/// (so Rust rejects `-0` for an integer field and this port accepts it).
///
/// `CreateMessage`, `ListRoots`, `Elicit`, `LoggingMessage`, `ResourceUpdated`,
/// `ElicitationComplete` and `SubscriptionsAcknowledged` are server→client
/// methods the proxy rejects on direction before params are validated; they
/// are nevertheless ported with the same machinery and differential-checked.
public enum OpenShellMCPParams {
    /// nil when tower-mcp-types' `validate_params` would accept `params` for
    /// `validator` under `revision` ("2025-03-26" | "2025-06-18" | "2025-11-25" | "2026-07-28");
    /// otherwise a short human-readable reason (exact wording doesn't matter).
    /// `params` is the JSON-decoded params object (JSONSerialization output: [String: Any],
    /// NSNumber, NSNull, String, [Any]); callers already checked it is an object.
    ///
    /// The 2026-07-28 request `_meta` requirement (`validate_2026_request_meta`)
    /// is deliberately not applied here.
    public static func validate(validator: String, params: [String: Any], revision: String) -> String? {
        let value = SerdeJSON.object(params)
        switch validator {
        case "Object": return nil
        case "Initialize": return decode(MCPTypes.initializeParams, value)
        case "Complete": return decode(MCPTypes.completeParams, value)
        case "SetLogLevel": return decode(MCPTypes.setLogLevelParams, value)
        case "GetPrompt": return decode(MCPTypes.getPromptParams, value)
        case "ListPrompts": return decode(MCPTypes.listPromptsParams, value)
        case "ListResources": return decode(MCPTypes.listResourcesParams, value)
        case "ListResourceTemplates": return decode(MCPTypes.listResourceTemplatesParams, value)
        case "ReadResource": return decode(MCPTypes.readResourceParams, value)
        case "SubscribeResource": return decode(MCPTypes.subscribeResourceParams, value)
        case "UnsubscribeResource": return decode(MCPTypes.unsubscribeResourceParams, value)
        case "CallTool": return decode(MCPTypes.callToolParams, value)
        case "ListTools": return decode(MCPTypes.listToolsParams, value)
        case "CreateMessage": return decode(MCPTypes.createMessageParams, value)
        case "ListRoots": return decode(MCPTypes.listRootsParams, value)
        case "Elicit":
            if revision == "2025-06-18" {
                return decode(MCPTypes.elicitFormParams, value)
            }
            return decode(MCPTypes.elicitRequestParams, value)
        case "GetTask": return decode(MCPTypes.getTaskInfoParams, value)
        case "GetTaskResult": return decode(MCPTypes.getTaskResultParams, value)
        case "ListTasks": return decode(MCPTypes.listTasksParams, value)
        case "CancelTask": return decode(MCPTypes.cancelTaskParams, value)
        case "Discover": return decode(MCPTypes.discoverParams, value)
        case "SubscriptionsListen":
            if let error = decode(MCPTypes.subscriptionsListenParams, value) { return error }
            // `parsed.notifications.is_none()`: absent or JSON null.
            if params["notifications"] == nil || SerdeJSON(params["notifications"]!) == .null {
                return "required `notifications` field is missing"
            }
            return nil
        case "Cancelled":
            if let error = decode(MCPTypes.cancelledParams, value) { return error }
            if params["requestId"] == nil || SerdeJSON(params["requestId"]!) == .null {
                return "required non-null `requestId` field is missing"
            }
            return nil
        case "Progress": return decode(MCPTypes.progressParams, value)
        case "LoggingMessage":
            // `params.get("data").is_none()` — a JSON null counts as present.
            if params["data"] == nil { return "required `data` field is missing" }
            return decode(MCPTypes.loggingMessageParams, value)
        case "ResourceUpdated":
            // No typed decode at all: only `uri` must be a string.
            if let uri = params["uri"], case .string = SerdeJSON(uri) { return nil }
            return "required `uri` field must be a string"
        case "TaskStatus": return decode(MCPTypes.taskStatusParams, value)
        case "ElicitationComplete": return decode(MCPTypes.elicitationCompleteParams, value)
        case "SubscriptionsAcknowledged": return decode(MCPTypes.subscriptionsAcknowledgedParams, value)
        default:
            return "unknown params validator \(validator)"
        }
    }

    private static func decode(_ type: SerdeType, _ value: SerdeJSON) -> String? {
        SerdeDecoder.decode(type, value, context: .value)
    }
}

// MARK: - JSON value model (serde_json::Value)

/// A serde_json::Value, with numbers split the way serde_json stores them:
/// non-negative integers (u64), negative integers (i64), and floats.
fileprivate enum SerdeJSON: Equatable {
    case null
    case bool(Bool)
    case posInt(UInt64)
    case negInt(Int64)
    case float(Double)
    case string(String)
    case array([SerdeJSON])
    case object([(key: String, value: SerdeJSON)])

    static func == (lhs: SerdeJSON, rhs: SerdeJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.posInt(a), .posInt(b)): return a == b
        case let (.negInt(a), .negInt(b)): return a == b
        case let (.float(a), .float(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    static func object(_ dict: [String: Any]) -> SerdeJSON {
        .object(dict.map { (key: $0.key, value: SerdeJSON($0.value)) })
    }

    /// Classify a JSONSerialization-produced value. Booleans are
    /// CFBoolean-backed NSNumbers and must be told apart from 0/1; floats are
    /// told apart from integers by the NSNumber's storage type (JSON `1.0` is a
    /// double, as in serde_json). NSDecimalNumber only appears for literals
    /// that do not fit u64/i64 or have more precision than a double — all of
    /// which serde_json parses as f64.
    init(_ any: Any) {
        if any is NSNull {
            self = .null
            return
        }
        if let string = any as? String {
            self = .string(string)
            return
        }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
                return
            }
            if number is NSDecimalNumber || CFNumberIsFloatType(number) {
                self = .float(number.doubleValue)
                return
            }
            let objCType = String(cString: number.objCType)
            switch objCType {
            case "Q", "L", "I", "S", "C":
                self = .posInt(number.uint64Value)
            default:
                let signed = number.int64Value
                self = signed >= 0 ? .posInt(UInt64(signed)) : .negInt(signed)
            }
            return
        }
        if let array = any as? [Any] {
            self = .array(array.map { SerdeJSON($0) })
            return
        }
        if let dict = any as? [String: Any] {
            self = SerdeJSON.object(dict)
            return
        }
        // Not producible by JSONSerialization; treat as an opaque string so
        // it fails every non-string type check.
        self = .string(String(describing: any))
    }

    var kindName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .posInt, .negInt: return "integer"
        case .float: return "floating point"
        case .string: return "string"
        case .array: return "sequence"
        case .object: return "map"
        }
    }

    func member(_ key: String) -> SerdeJSON? {
        guard case .object(let entries) = self else { return nil }
        return entries.first(where: { $0.key == key })?.value
    }
}

// MARK: - serde data-model descriptors

/// One field of a derived struct (or struct variant).
fileprivate struct SerdeField {
    /// Wire name after `rename` / `rename_all`.
    let key: String
    let type: SerdeType
    /// `#[serde(default)]` / `default = "…"`: may be absent (object form) or
    /// omitted from the tail (seq form).
    let hasDefault: Bool

    init(_ key: String, _ type: SerdeType, default hasDefault: Bool = false) {
        self.key = key
        self.type = type
        self.hasDefault = hasDefault
    }
}

fileprivate final class SerdeStruct {
    let name: String
    let fields: [SerdeField]
    init(_ name: String, _ fields: [SerdeField]) {
        self.name = name
        self.fields = fields
    }
}

fileprivate struct SerdeVariant {
    let name: String
    let fields: [SerdeField]
}

fileprivate indirect enum SerdeType {
    case string
    case bool
    case u32
    case u64
    case i64
    case f64
    /// `serde_json::Value`: anything, including null.
    case any
    case option(SerdeType)
    case vec(SerdeType)
    /// HashMap / BTreeMap / IndexMap / serde_json::Map keyed by String.
    case map(SerdeType)
    /// Externally tagged enum whose variants are all unit variants.
    case unitEnum(String, [String])
    case structure(SerdeStruct)
    /// `#[serde(untagged)]` enum of newtype variants, tried in order.
    case untagged(String, [SerdeType])
    /// `#[serde(tag = "…")]` enum of struct variants.
    case internallyTagged(String, tag: String, variants: [SerdeVariant])
    /// Field with `with = "meta_object_serde"` wrapping `Option<T>`.
    case metaObject(SerdeType)
    /// Field with `with = "extension_map_serde"` (Option<HashMap<String, Value>>).
    case extensionMap
    /// Custom `Deserialize for PrimitiveSchemaDefinition`.
    case primitiveSchema
    /// Deferred reference, for recursive types.
    case lazy(() -> SerdeType)
}

// MARK: - decoder

fileprivate enum SerdeDecoder {
    /// Which serde Deserializer is feeding the value. For the reachable types
    /// it matters in exactly two places:
    /// - an internally tagged enum's tag goes through `deserialize_identifier`,
    ///   which serde_json::Value only honours for strings, while serde's
    ///   buffered `Content` (either flavour) also accepts a u64 variant index;
    /// - a unit enum variant's payload goes through `deserialize_unit`, which
    ///   the owned `ContentDeserializer` (used for the fields of an internally
    ///   tagged variant) also satisfies with an empty map, unlike
    ///   serde_json::Value and `ContentRefDeserializer` (untagged enums).
    enum Context {
        /// serde_json::Value (`from_value`).
        case value
        /// `ContentRefDeserializer` — untagged enum variants.
        case contentRef
        /// `ContentDeserializer` — internally tagged enum variant fields.
        case contentOwned
    }

    static func decode(_ type: SerdeType, _ value: SerdeJSON, context: Context) -> String? {
        switch type {
        case .lazy(let resolve):
            return decode(resolve(), value, context: context)

        case .string:
            if case .string = value { return nil }
            return invalid(value, "a string")

        case .bool:
            if case .bool = value { return nil }
            return invalid(value, "a boolean")

        case .u32:
            switch value {
            case .posInt(let n): return n <= UInt64(UInt32.max) ? nil : "invalid value: integer `\(n)`, expected u32"
            case .negInt(let n): return "invalid value: integer `\(n)`, expected u32"
            default: return invalid(value, "u32")
            }

        case .u64:
            switch value {
            case .posInt: return nil
            case .negInt(let n): return "invalid value: integer `\(n)`, expected u64"
            default: return invalid(value, "u64")
            }

        case .i64:
            switch value {
            case .posInt(let n): return n <= UInt64(Int64.max) ? nil : "invalid value: integer `\(n)`, expected i64"
            case .negInt: return nil
            default: return invalid(value, "i64")
            }

        case .f64:
            switch value {
            case .posInt, .negInt, .float: return nil
            default: return invalid(value, "f64")
            }

        case .any:
            return nil

        case .option(let inner):
            if value == .null { return nil }
            return decode(inner, value, context: context)

        case .vec(let element):
            guard case .array(let items) = value else { return invalid(value, "a sequence") }
            for (index, item) in items.enumerated() {
                if let error = decode(element, item, context: context) { return "[\(index)]: \(error)" }
            }
            return nil

        case .map(let element):
            guard case .object(let entries) = value else { return invalid(value, "a map") }
            for entry in entries {
                if let error = decode(element, entry.value, context: context) { return "\(entry.key): \(error)" }
            }
            return nil

        case .unitEnum(let name, let variants):
            switch value {
            case .string(let variant):
                return variants.contains(variant) ? nil : "unknown variant `\(variant)` of \(name)"
            case .object(let entries):
                guard entries.count == 1 else {
                    return "invalid value: map, expected map with a single key (\(name))"
                }
                guard variants.contains(entries[0].key) else {
                    return "unknown variant `\(entries[0].key)` of \(name)"
                }
                // unit_variant(): the payload deserializes as `()` — null, or
                // (owned Content only) an empty map.
                let payload = entries[0].value
                if payload == .null { return nil }
                if context == .contentOwned, case .object(let inner) = payload, inner.isEmpty { return nil }
                return invalid(payload, "unit variant payload (null)")
            default:
                return invalid(value, "string or map (\(name))")
            }

        case .structure(let def):
            switch value {
            case .object(let entries):
                return decodeStructMap(def.name, def.fields, entries, context: context)
            case .array(let items):
                return decodeStructSeq(def.name, def.fields, items, context: context)
            default:
                return invalid(value, "struct \(def.name)")
            }

        case .untagged(let name, let variants):
            for variant in variants where decode(variant, value, context: .contentRef) == nil {
                return nil
            }
            return "data did not match any variant of untagged enum \(name)"

        case .internallyTagged(let name, let tag, let variants):
            return decodeInternallyTagged(name, tag: tag, variants: variants, value, context: context)

        case .metaObject(let inner):
            switch value {
            case .null:
                return nil
            case .object(let entries):
                // Tolerant on key names: nonconforming keys are dropped, then
                // the rest is decoded with serde_json::from_value.
                let kept = entries.filter { validateMetaKey($0.key) }
                return decode(inner, .object(kept), context: .value).map { "_meta: \($0)" }
            default:
                return "_meta must be a JSON object"
            }

        case .extensionMap:
            switch value {
            case .null:
                return nil
            case .object(let entries):
                for entry in entries {
                    if !entry.key.contains("/") {
                        return "extension identifier \"\(entry.key)\" requires a prefix"
                    }
                    if !validateMetaKey(entry.key) {
                        return "extension identifier \"\(entry.key)\" is malformed"
                    }
                    guard case .object = entry.value else {
                        return "extension \"\(entry.key)\" settings must be a JSON object"
                    }
                }
                return nil
            default:
                return invalid(value, "a map")
            }

        case .primitiveSchema:
            // `value.get("type").and_then(Value::as_str)`; `get` on a
            // non-object is None, which falls through to Raw.
            var schemaType: String?
            if case .string(let s)? = value.member("type") { schemaType = s }
            let hasEnum = value.member("enum") != nil
            let target: SerdeType
            switch (schemaType, hasEnum) {
            case ("string"?, true): target = MCPTypes.singleSelectEnumSchema
            case ("string"?, false): target = MCPTypes.stringSchema
            case ("integer"?, _): target = MCPTypes.integerSchema
            case ("number"?, _): target = MCPTypes.numberSchema
            case ("boolean"?, _): target = MCPTypes.booleanSchema
            case ("array"?, _): target = MCPTypes.multiSelectEnumSchema
            default: return nil // Raw(Value)
            }
            return decode(target, value, context: .value)
        }
    }

    /// Object form of a derived struct visitor (`visit_map`).
    private static func decodeStructMap(
        _ name: String,
        _ fields: [SerdeField],
        _ entries: [(key: String, value: SerdeJSON)],
        context: Context
    ) -> String? {
        for field in fields {
            if let present = entries.first(where: { $0.key == field.key }) {
                if let error = decode(field.type, present.value, context: context) {
                    return "\(field.key): \(error)"
                }
            } else if !field.hasDefault && !isOption(field.type) {
                // serde's `missing_field` succeeds only for Option (visit_none).
                return "missing field `\(field.key)` in \(name)"
            }
        }
        return nil
    }

    /// Seq form of a derived struct visitor (`visit_seq`) followed by the
    /// deserializer's "no elements left over" check.
    private static func decodeStructSeq(
        _ name: String,
        _ fields: [SerdeField],
        _ items: [SerdeJSON],
        context: Context
    ) -> String? {
        for (index, field) in fields.enumerated() {
            if index < items.count {
                if let error = decode(field.type, items[index], context: context) {
                    return "[\(index)] \(field.key): \(error)"
                }
            } else if !field.hasDefault {
                return "invalid length \(index), expected \(name) with \(fields.count) elements"
            }
        }
        if items.count > fields.count {
            return "invalid length \(items.count), expected fewer elements in array (\(name))"
        }
        return nil
    }

    private enum VariantLookup {
        case success(SerdeVariant)
        case failure(String)
    }

    private static func decodeInternallyTagged(
        _ name: String,
        tag: String,
        variants: [SerdeVariant],
        _ value: SerdeJSON,
        context: Context
    ) -> String? {
        func resolve(_ tagValue: SerdeJSON) -> VariantLookup {
            switch tagValue {
            case .string(let s):
                if let variant = variants.first(where: { $0.name == s }) { return .success(variant) }
                return .failure("unknown variant `\(s)` of \(name)")
            case .posInt(let n) where context != .value:
                if n < UInt64(variants.count) { return .success(variants[Int(n)]) }
                return .failure("invalid value: integer `\(n)`, expected variant index 0 <= i < \(variants.count)")
            default:
                return .failure(invalid(tagValue, "variant identifier") ?? "invalid tag")
            }
        }

        switch value {
        case .object(let entries):
            guard let tagEntry = entries.first(where: { $0.key == tag }) else {
                return "missing field `\(tag)` in \(name)"
            }
            switch resolve(tagEntry.value) {
            case .failure(let error): return error
            case .success(let variant):
                let rest = entries.filter { $0.key != tag }
                return decodeStructMap("\(name)::\(variant.name)", variant.fields, rest, context: .contentOwned)
            }
        case .array(let items):
            guard let first = items.first else { return "missing field `\(tag)` in \(name)" }
            switch resolve(first) {
            case .failure(let error): return error
            case .success(let variant):
                return decodeStructSeq("\(name)::\(variant.name)", variant.fields, Array(items.dropFirst()), context: .contentOwned)
            }
        default:
            return invalid(value, "internally tagged enum \(name)")
        }
    }

    private static func isOption(_ type: SerdeType) -> Bool {
        switch type {
        case .option: return true
        case .lazy(let resolve): return isOption(resolve())
        default: return false
        }
    }

    private static func invalid(_ value: SerdeJSON, _ expected: String) -> String? {
        "invalid type: \(value.kindName), expected \(expected)"
    }

    /// Port of `validate_meta_key` (ASCII byte rules; a multi-byte UTF-8
    /// character is never alphanumeric, `-`, `_` or `.`).
    static func validateMetaKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        let slash = bytes.firstIndex(of: UInt8(ascii: "/"))
        let name: ArraySlice<UInt8> = slash.map { bytes[($0 + 1)...] } ?? bytes[...]

        func isAlpha(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        func isAlnum(_ b: UInt8) -> Bool { isAlpha(b) || isDigit(b) }

        if let slash {
            let prefix = bytes[..<slash]
            if prefix.isEmpty { return false }
            for label in prefix.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false) {
                guard let first = label.first, let last = label.last else { return false }
                if !isAlpha(first) || !isAlnum(last) { return false }
                if !label.allSatisfy({ isAlnum($0) || $0 == UInt8(ascii: "-") }) { return false }
            }
        }

        if let first = name.first, let last = name.last {
            if !isAlnum(first) || !isAlnum(last) { return false }
            let allowed: Set<UInt8> = [UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ".")]
            if !name.allSatisfy({ isAlnum($0) || allowed.contains($0) }) { return false }
        }
        return true
    }
}

// MARK: - tower-mcp-types 0.22.2 type table

/// The serde shape of every type reachable from the params structs named in
/// `validate_params`, transcribed field by field from `protocol.rs`.
/// Field order is declaration order (it is the seq-form element order).
fileprivate enum MCPTypes {
    private static func s(_ name: String, _ fields: [SerdeField]) -> SerdeType {
        .structure(SerdeStruct(name, fields))
    }

    private static let optString = SerdeType.option(.string)
    private static let metaValue = SerdeType.metaObject(.any)
    private static let metaRequest = SerdeType.metaObject(.lazy { MCPTypes.requestMeta })

    private static func metaField(_ type: SerdeType) -> SerdeField {
        SerdeField("_meta", type, default: true)
    }

    // MARK: shared leaves

    static let logLevel = SerdeType.unitEnum(
        "LogLevel", ["emergency", "alert", "critical", "error", "warning", "notice", "info", "debug"])
    static let taskStatus = SerdeType.unitEnum(
        "TaskStatus", ["working", "input_required", "completed", "failed", "cancelled"])
    static let contentRole = SerdeType.unitEnum("ContentRole", ["user", "assistant"])
    static let iconTheme = SerdeType.unitEnum("IconTheme", ["light", "dark"])
    static let includeContext = SerdeType.unitEnum("IncludeContext", ["allServers", "thisServer", "none"])
    static let taskSupportMode = SerdeType.unitEnum("TaskSupportMode", ["required", "optional", "forbidden"])
    static let elicitMode = SerdeType.unitEnum("ElicitMode", ["form", "url"])
    static let elicitAction = SerdeType.unitEnum("ElicitAction", ["accept", "decline", "cancel"])

    /// `RequestId` / `ProgressToken`: untagged { String(String), Number(i64) }.
    static let requestId = SerdeType.untagged("RequestId", [.string, .i64])
    static let progressToken = SerdeType.untagged("ProgressToken", [.string, .i64])

    static let toolIcon = s("ToolIcon", [
        SerdeField("src", .string),
        SerdeField("mimeType", optString),
        SerdeField("sizes", .option(.vec(.string))),
        SerdeField("theme", .option(iconTheme)),
    ])

    static let implementation = s("Implementation", [
        SerdeField("name", .string),
        SerdeField("version", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("icons", .option(.vec(toolIcon))),
        SerdeField("websiteUrl", optString),
        metaField(metaValue),
    ])

    static let deprecationInfo = s("DeprecationInfo", [
        SerdeField("since", optString, default: true),
        SerdeField("removeIn", optString, default: true),
        SerdeField("message", optString, default: true),
        SerdeField("replacement", optString, default: true),
    ])

    private static func emptyStruct(_ name: String) -> SerdeType { s(name, []) }

    // MARK: capabilities

    static let rootsCapability = s("RootsCapability", [
        SerdeField("listChanged", .bool, default: true),
        SerdeField("deprecated", .option(deprecationInfo), default: true),
    ])

    static let samplingCapability = s("SamplingCapability", [
        SerdeField("tools", .option(emptyStruct("SamplingToolsCapability")), default: true),
        SerdeField("context", .option(emptyStruct("SamplingContextCapability")), default: true),
        SerdeField("deprecated", .option(deprecationInfo), default: true),
    ])

    static let elicitationCapability = s("ElicitationCapability", [
        SerdeField("form", .option(emptyStruct("ElicitationFormCapability")), default: true),
        SerdeField("url", .option(emptyStruct("ElicitationUrlCapability")), default: true),
    ])

    static let clientTasksCapability = s("ClientTasksCapability", [
        SerdeField("list", .option(emptyStruct("ClientTasksListCapability")), default: true),
        SerdeField("cancel", .option(emptyStruct("ClientTasksCancelCapability")), default: true),
        SerdeField("requests", .option(s("ClientTasksRequestsCapability", [
            SerdeField("sampling", .option(s("ClientTasksSamplingCapability", [
                SerdeField("createMessage", .option(emptyStruct("ClientTasksSamplingCreateMessageCapability")), default: true),
            ])), default: true),
            SerdeField("elicitation", .option(s("ClientTasksElicitationCapability", [
                SerdeField("create", .option(emptyStruct("ClientTasksElicitationCreateCapability")), default: true),
            ])), default: true),
        ])), default: true),
    ])

    static let clientCapabilities = s("ClientCapabilities", [
        SerdeField("roots", .option(rootsCapability), default: true),
        SerdeField("sampling", .option(samplingCapability), default: true),
        SerdeField("elicitation", .option(elicitationCapability), default: true),
        SerdeField("tasks", .option(clientTasksCapability), default: true),
        SerdeField("experimental", .option(.map(.any)), default: true),
        SerdeField("extensions", .extensionMap, default: true),
    ])

    /// `RequestMeta` (decoded from the filtered `_meta` object via from_value).
    static let requestMeta = s("RequestMeta", [
        SerdeField("progressToken", .option(progressToken)),
        SerdeField("io.modelcontextprotocol/protocolVersion", optString),
        SerdeField("io.modelcontextprotocol/clientInfo", .option(implementation)),
        SerdeField("io.modelcontextprotocol/clientCapabilities", .option(clientCapabilities)),
        SerdeField("io.modelcontextprotocol/logLevel", .option(logLevel)),
    ])

    static let notificationMeta = s("NotificationMeta", [
        SerdeField("io.modelcontextprotocol/subscriptionId", .option(requestId), default: true),
    ])

    // MARK: sampling

    static let contentAnnotations = s("ContentAnnotations", [
        SerdeField("audience", .option(.vec(contentRole))),
        SerdeField("priority", .option(.f64)),
        SerdeField("lastModified", optString),
    ])

    /// `SamplingContent`: `tag = "type"`, `rename_all = "lowercase"` on the
    /// variants (fields keep their own names / explicit renames).
    static let samplingContent: SerdeType = .internallyTagged("SamplingContent", tag: "type", variants: [
        SerdeVariant(name: "text", fields: [
            SerdeField("text", .string),
            SerdeField("annotations", .option(contentAnnotations), default: true),
            metaField(metaValue),
        ]),
        SerdeVariant(name: "image", fields: [
            SerdeField("data", .string),
            SerdeField("mimeType", .string),
            SerdeField("annotations", .option(contentAnnotations), default: true),
            metaField(metaValue),
        ]),
        SerdeVariant(name: "audio", fields: [
            SerdeField("data", .string),
            SerdeField("mimeType", .string),
            SerdeField("annotations", .option(contentAnnotations), default: true),
            metaField(metaValue),
        ]),
        SerdeVariant(name: "tool_use", fields: [
            SerdeField("id", .string),
            SerdeField("name", .string),
            SerdeField("input", .any),
            metaField(metaValue),
        ]),
        SerdeVariant(name: "tool_result", fields: [
            SerdeField("toolUseId", .string),
            SerdeField("content", .vec(.lazy { MCPTypes.samplingContent })),
            SerdeField("structuredContent", .option(.any), default: true),
            SerdeField("isError", .option(.bool), default: true),
            metaField(metaValue),
        ]),
    ])

    static let samplingContentOrArray = SerdeType.untagged(
        "SamplingContentOrArray", [samplingContent, .vec(samplingContent)])

    static let samplingMessage = s("SamplingMessage", [
        SerdeField("role", contentRole),
        SerdeField("content", samplingContentOrArray),
        metaField(metaValue),
    ])

    static let modelPreferences = s("ModelPreferences", [
        SerdeField("speedPriority", .option(.f64), default: true),
        SerdeField("intelligencePriority", .option(.f64), default: true),
        SerdeField("costPriority", .option(.f64), default: true),
        SerdeField("hints", .vec(s("ModelHint", [
            SerdeField("name", optString, default: true),
        ])), default: true),
    ])

    static let toolAnnotations = s("ToolAnnotations", [
        SerdeField("title", optString),
        SerdeField("readOnlyHint", .bool, default: true),
        SerdeField("destructiveHint", .bool, default: true),
        SerdeField("idempotentHint", .bool, default: true),
        SerdeField("openWorldHint", .bool, default: true),
    ])

    static let toolExecution = s("ToolExecution", [
        SerdeField("taskSupport", .option(taskSupportMode), default: true),
    ])

    static let samplingTool = s("SamplingTool", [
        SerdeField("name", .string),
        SerdeField("title", optString, default: true),
        SerdeField("description", optString),
        SerdeField("inputSchema", .any),
        SerdeField("outputSchema", .option(.any), default: true),
        SerdeField("icons", .option(.vec(toolIcon)), default: true),
        SerdeField("annotations", .option(toolAnnotations), default: true),
        SerdeField("execution", .option(toolExecution), default: true),
    ])

    static let toolChoice = s("ToolChoice", [
        SerdeField("mode", .string),
        SerdeField("name", optString),
    ])

    static let taskRequestParams = s("TaskRequestParams", [
        SerdeField("ttl", .option(.u64), default: true),
    ])

    static let createMessageParams = s("CreateMessageParams", [
        SerdeField("messages", .vec(samplingMessage)),
        SerdeField("maxTokens", .u32),
        SerdeField("systemPrompt", optString, default: true),
        SerdeField("temperature", .option(.f64), default: true),
        SerdeField("stopSequences", .vec(.string), default: true),
        SerdeField("modelPreferences", .option(modelPreferences), default: true),
        SerdeField("includeContext", .option(includeContext), default: true),
        SerdeField("metadata", .option(.map(.any)), default: true),
        SerdeField("tools", .option(.vec(samplingTool)), default: true),
        SerdeField("toolChoice", .option(toolChoice), default: true),
        SerdeField("task", .option(taskRequestParams), default: true),
        metaField(metaValue),
    ])

    static let createMessageResult = s("CreateMessageResult", [
        SerdeField("content", samplingContentOrArray),
        SerdeField("model", .string),
        SerdeField("role", contentRole),
        SerdeField("stopReason", optString, default: true),
        metaField(metaValue),
    ])

    // MARK: roots / elicitation results (InputResponse)

    static let root = s("Root", [
        SerdeField("uri", .string),
        SerdeField("name", optString, default: true),
        metaField(metaValue),
    ])

    static let listRootsResult = s("ListRootsResult", [
        SerdeField("roots", .vec(root)),
        metaField(metaValue),
    ])

    /// `ElicitFieldValue`: untagged { String, Number(f64), Integer(i64), Boolean, StringArray }.
    static let elicitFieldValue = SerdeType.untagged(
        "ElicitFieldValue", [.string, .f64, .i64, .bool, .vec(.string)])

    static let elicitResult = s("ElicitResult", [
        SerdeField("action", elicitAction),
        SerdeField("content", .option(.map(elicitFieldValue)), default: true),
        metaField(metaValue),
    ])

    /// `InputResponse`: untagged { CreateMessageResult, ListRootsResult, ElicitResult }.
    static let inputResponse = SerdeType.untagged(
        "InputResponse", [createMessageResult, listRootsResult, elicitResult])

    /// `InputResponses = BTreeMap<String, InputResponse>`.
    static let inputResponses = SerdeType.map(inputResponse)

    // MARK: elicitation request

    static let stringSchema = s("StringSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("format", optString),
        SerdeField("pattern", optString),
        SerdeField("minLength", .option(.u64)),
        SerdeField("maxLength", .option(.u64)),
        SerdeField("default", optString),
    ])

    static let integerSchema = s("IntegerSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("minimum", .option(.i64)),
        SerdeField("maximum", .option(.i64)),
        SerdeField("default", .option(.i64)),
    ])

    static let numberSchema = s("NumberSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("minimum", .option(.f64)),
        SerdeField("maximum", .option(.f64)),
        SerdeField("default", .option(.f64)),
    ])

    static let booleanSchema = s("BooleanSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("default", .option(.bool)),
    ])

    static let singleSelectEnumSchema = s("SingleSelectEnumSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("enum", .vec(.string)),
        SerdeField("default", optString),
    ])

    static let multiSelectEnumSchema = s("MultiSelectEnumSchema", [
        SerdeField("type", .string),
        SerdeField("title", optString),
        SerdeField("description", optString),
        SerdeField("items", s("MultiSelectEnumItems", [
            SerdeField("type", .string),
            SerdeField("enum", .vec(.string)),
        ])),
        SerdeField("uniqueItems", .option(.bool)),
        SerdeField("default", .option(.vec(.string))),
    ])

    static let elicitFormSchema = s("ElicitFormSchema", [
        SerdeField("type", .string),
        SerdeField("properties", .map(.primitiveSchema)),
        SerdeField("required", .vec(.string), default: true),
    ])

    static let elicitFormParams = s("ElicitFormParams", [
        SerdeField("mode", .option(elicitMode), default: true),
        SerdeField("message", .string),
        SerdeField("requestedSchema", elicitFormSchema),
        metaField(metaRequest),
    ])

    static let elicitUrlParams = s("ElicitUrlParams", [
        SerdeField("mode", .option(elicitMode), default: true),
        SerdeField("elicitationId", .string),
        SerdeField("message", .string),
        SerdeField("url", .string),
        metaField(metaRequest),
    ])

    static let elicitRequestParams = SerdeType.untagged(
        "ElicitRequestParams", [elicitFormParams, elicitUrlParams])

    // MARK: request params

    static let initializeParams = s("InitializeParams", [
        SerdeField("protocolVersion", .string),
        SerdeField("capabilities", clientCapabilities),
        SerdeField("clientInfo", implementation),
        metaField(metaValue),
    ])

    /// `CompletionReference`: `tag = "type"`, explicit variant renames.
    static let completionReference = SerdeType.internallyTagged("CompletionReference", tag: "type", variants: [
        SerdeVariant(name: "ref/prompt", fields: [SerdeField("name", .string)]),
        SerdeVariant(name: "ref/resource", fields: [SerdeField("uri", .string)]),
    ])

    static let completeParams = s("CompleteParams", [
        SerdeField("ref", completionReference),
        SerdeField("argument", s("CompletionArgument", [
            SerdeField("name", .string),
            SerdeField("value", .string),
        ])),
        SerdeField("context", .option(s("CompletionContext", [
            SerdeField("arguments", .option(.map(.string)), default: true),
        ])), default: true),
        metaField(metaValue),
    ])

    static let setLogLevelParams = s("SetLogLevelParams", [
        SerdeField("level", logLevel),
        metaField(metaRequest),
    ])

    static let getPromptParams = s("GetPromptParams", [
        SerdeField("name", .string),
        SerdeField("arguments", .map(.string), default: true),
        SerdeField("inputResponses", .option(inputResponses), default: true),
        SerdeField("requestState", optString, default: true),
        metaField(metaRequest),
    ])

    private static func cursorParams(_ name: String) -> SerdeType {
        s(name, [
            SerdeField("cursor", optString, default: true),
            metaField(metaRequest),
        ])
    }

    static let listPromptsParams = cursorParams("ListPromptsParams")
    static let listResourcesParams = cursorParams("ListResourcesParams")
    static let listResourceTemplatesParams = cursorParams("ListResourceTemplatesParams")
    static let listToolsParams = cursorParams("ListToolsParams")

    static let readResourceParams = s("ReadResourceParams", [
        SerdeField("uri", .string),
        SerdeField("inputResponses", .option(inputResponses), default: true),
        SerdeField("requestState", optString, default: true),
        metaField(metaRequest),
    ])

    static let subscribeResourceParams = s("SubscribeResourceParams", [
        SerdeField("uri", .string),
        metaField(metaRequest),
    ])

    static let unsubscribeResourceParams = s("UnsubscribeResourceParams", [
        SerdeField("uri", .string),
        metaField(metaRequest),
    ])

    static let callToolParams = s("CallToolParams", [
        SerdeField("name", .string),
        SerdeField("arguments", .any, default: true),
        SerdeField("inputResponses", .option(inputResponses), default: true),
        SerdeField("requestState", optString, default: true),
        metaField(metaRequest),
        SerdeField("task", .option(taskRequestParams), default: true),
    ])

    static let listRootsParams = s("ListRootsParams", [metaField(metaRequest)])

    static let getTaskInfoParams = s("GetTaskInfoParams", [
        SerdeField("taskId", .string),
        metaField(metaRequest),
    ])

    static let getTaskResultParams = s("GetTaskResultParams", [
        SerdeField("taskId", .string),
        metaField(metaRequest),
    ])

    static let listTasksParams = s("ListTasksParams", [
        SerdeField("status", .option(taskStatus), default: true),
        SerdeField("cursor", optString, default: true),
        metaField(metaRequest),
    ])

    /// `protocol::CancelTaskParams` (not `tasks::CancelTaskParams`).
    static let cancelTaskParams = s("CancelTaskParams", [
        SerdeField("taskId", .string),
        SerdeField("reason", optString, default: true),
        metaField(metaRequest),
    ])

    static let discoverParams = s("DiscoverParams", [metaField(metaRequest)])

    static let subscriptionFilter = s("SubscriptionFilter", [
        SerdeField("toolsListChanged", .option(.bool), default: true),
        SerdeField("promptsListChanged", .option(.bool), default: true),
        SerdeField("resourcesListChanged", .option(.bool), default: true),
        SerdeField("resourceSubscriptions", .option(.vec(.string)), default: true),
        SerdeField("taskIds", .option(.vec(.string)), default: true),
    ])

    static let subscriptionsListenParams = s("SubscriptionsListenParams", [
        SerdeField("notifications", .option(subscriptionFilter), default: true),
        metaField(metaValue),
    ])

    // MARK: notification params

    static let cancelledParams = s("CancelledParams", [
        SerdeField("requestId", .option(requestId), default: true),
        SerdeField("reason", optString),
        metaField(metaValue),
    ])

    static let progressParams = s("ProgressParams", [
        SerdeField("progressToken", progressToken),
        SerdeField("progress", .f64),
        SerdeField("total", .option(.f64)),
        SerdeField("message", optString),
        metaField(metaValue),
    ])

    static let loggingMessageParams = s("LoggingMessageParams", [
        SerdeField("level", logLevel),
        SerdeField("logger", optString),
        SerdeField("data", .any, default: true),
        metaField(metaValue),
    ])

    static let taskStatusParams = s("TaskStatusParams", [
        SerdeField("taskId", .string),
        SerdeField("status", taskStatus),
        SerdeField("statusMessage", optString),
        SerdeField("createdAt", .string),
        SerdeField("lastUpdatedAt", .string),
        SerdeField("ttl", .option(.u64)),
        SerdeField("pollInterval", .option(.u64)),
        metaField(metaValue),
    ])

    static let elicitationCompleteParams = s("ElicitationCompleteParams", [
        SerdeField("elicitationId", .string),
        metaField(metaValue),
    ])

    static let subscriptionsAcknowledgedParams = s("SubscriptionsAcknowledgedParams", [
        metaField(.metaObject(notificationMeta)),
        SerdeField("notifications", subscriptionFilter),
    ])
}
