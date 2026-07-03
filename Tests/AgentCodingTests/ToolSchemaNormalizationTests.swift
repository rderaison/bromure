import Foundation
import Testing
@testable import bromure_ac

// MARK: - Tool-schema `type` normalization for chat templates
//
// Gemma-family chat templates run `value['type'] | upper` on every parameter
// schema node; a JSON-Schema union type (["string", "null"]) or a type-less
// anyOf/enum-only property aborts the render ("upper filter requires string").
// normalizeSchemaTypes coerces every schema node's `type` to a plain string.

@Suite("ToolSchemaNormalization")
struct ToolSchemaNormalizationTests {

    private func normalize(_ json: String) -> [String: Any] {
        let raw = try! JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        return ToolDef.normalizeSchemaTypes(raw) as! [String: Any]
    }

    @Test("Union type array collapses to its first non-null member")
    func unionType() {
        let out = normalize(#"{"type": ["string", "null"]}"#)
        #expect(out["type"] as? String == "string")
    }

    @Test("All-null union still yields a string type")
    func allNullUnion() {
        let out = normalize(#"{"type": ["null"]}"#)
        #expect(out["type"] as? String == "null")
    }

    @Test("Type-less node with properties infers object")
    func inferObject() {
        let out = normalize(#"{"properties": {"a": {"type": "string"}}}"#)
        #expect(out["type"] as? String == "object")
    }

    @Test("Type-less node with items infers array; anyOf/enum infer string")
    func inferOthers() {
        #expect(normalize(#"{"items": {"type": "integer"}}"#)["type"] as? String == "array")
        #expect(normalize(#"{"enum": ["a", "b"]}"#)["type"] as? String == "string")
        #expect(normalize(#"{"anyOf": [{"type": "integer"}, {"type": "string"}]}"#)["type"] as? String == "string")
    }

    @Test("Union types nested under properties and items are normalized")
    func nestedUnion() {
        let out = normalize(#"""
        {"type": "object", "properties": {
            "path":  {"type": ["string", "null"]},
            "lines": {"type": "array", "items": {"type": ["integer", "null"]}}
        }}
        """#)
        let props = out["properties"] as! [String: Any]
        #expect((props["path"] as! [String: Any])["type"] as? String == "string")
        let items = (props["lines"] as! [String: Any])["items"] as! [String: Any]
        #expect(items["type"] as? String == "integer")
    }

    @Test("A parameter literally named items/enum does not fake a schema")
    func propertyNamesAreOpaque() {
        // `properties` maps *names* to schemas — a parameter named "items"
        // must not make the map itself grow a phantom `type` entry.
        let out = normalize(#"""
        {"type": "object", "properties": {
            "items": {"type": "array", "items": {"type": "string"}},
            "enum":  {"type": "string"}
        }}
        """#)
        let props = out["properties"] as! [String: Any]
        #expect(props["type"] == nil)
        #expect((props["items"] as! [String: Any])["type"] as? String == "array")
    }

    @Test("default/examples/const values pass through verbatim")
    func defaultsAreOpaque() {
        let out = normalize(#"""
        {"type": "object",
         "properties": {"cfg": {"type": "object",
                                "properties": {"x": {"type": "integer"}},
                                "default": {"properties": {"x": 1}}}}}
        """#)
        let props = out["properties"] as! [String: Any]
        let cfg = props["cfg"] as! [String: Any]
        let def = cfg["default"] as! [String: Any]
        // The default's own "properties" key is user data, not a schema map —
        // it must not gain a type.
        #expect(def["type"] == nil)
        #expect((def["properties"] as! [String: Any])["x"] as? Int == 1)
    }

    @Test("Well-formed schemas are untouched")
    func wellFormedPassThrough() {
        let json = #"{"type": "object", "properties": {"q": {"type": "string", "description": "query"}}, "required": ["q"]}"#
        let out = normalize(json)
        #expect(out["type"] as? String == "object")
        let props = out["properties"] as! [String: Any]
        #expect((props["q"] as! [String: Any])["description"] as? String == "query")
        #expect(out["required"] as? [String] == ["q"])
    }

    @Test("asToolSpec strips nulls and normalizes types end-to-end")
    func endToEnd() {
        let tool = ToolDef(
            name: "read_file", description: "Read a file",
            parametersJSONString: #"""
            {"type": "object", "properties": {
                "path":   {"type": ["string", "null"], "default": null},
                "offset": {"anyOf": [{"type": "integer"}, {"type": "string"}]}
            }}
            """#)
        let spec = tool.asToolSpec
        let fn = spec["function"] as! [String: Any]
        let params = fn["parameters"] as! [String: Any]
        let props = params["properties"] as! [String: Any]
        let path = props["path"] as! [String: Any]
        #expect(path["type"] as? String == "string")
        #expect(path["default"] == nil)   // NSNull stripped
        #expect((props["offset"] as! [String: Any])["type"] as? String == "string")
    }
}
