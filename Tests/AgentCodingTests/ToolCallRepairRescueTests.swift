import Foundation
import Testing
@testable import bromure_ac

/// Rescue-path coverage for ToolCallRepair beyond the basic shapes already in
/// InferenceRoutingTests (`<function …>`, markdown, `<tool_call>{json}`). These
/// exercise the 3.x rescue commits: malformed `<tool_call>` JSON wrappers,
/// parameter-less tool calls (EnterPlanMode), Qwen3 native
/// `<function=…><parameter=…>`, XML-element calls, and bare JSON objects.
@Suite("ToolCallRepair rescue paths (3.x)")
struct ToolCallRepairRescueTests {

    private func first(_ blocks: [[String: Any]]) -> (String, [String: Any])? {
        guard let b = blocks.first, let name = b["name"] as? String,
              let input = b["input"] as? [String: Any] else { return nil }
        return (name, input)
    }

    // MARK: malformed <tool_call> wrapper (name dangling outside the object)

    @Test("Malformed <tool_call> wrapper (name outside JSON) rescued when tool is declared")
    func malformedWrapper() {
        let txt = #"<tool_call>{"arguments":{"command":"ls -la"}}, "name":"Bash"}</tool_call>"#
        let (clean, blocks) = ToolCallRepair.rescue(text: txt, toolNames: ["Bash"])
        let r = first(blocks)
        #expect(r?.0 == "Bash")
        #expect(r?.1["command"] as? String == "ls -la")
        #expect(!clean.contains("Bash"))
    }

    @Test("Malformed <tool_call> wrapper ignored without declared tool names")
    func malformedWrapperGated() {
        let txt = #"<tool_call>{"arguments":{"command":"ls"}}, "name":"Bash"}</tool_call>"#
        // No toolNames → the structured parsers can't read it and the gated
        // wrapper rescue is skipped, so nothing is recovered.
        let (_, blocks) = ToolCallRepair.rescue(text: txt)
        #expect(blocks.isEmpty)
    }

    // MARK: Qwen3-Coder native <function=…><parameter=…>

    @Test("Qwen3 native function call with parameters")
    func qwenNativeWithParams() {
        let txt = """
        <function=Write>
        <parameter=file_path>
        /tmp/hello.txt
        </parameter>
        <parameter=content>
        hello world
        </parameter>
        </function>
        """
        let (_, blocks) = ToolCallRepair.rescue(text: txt, toolNames: ["Write"])
        let r = first(blocks)
        #expect(r?.0 == "Write")
        #expect(r?.1["file_path"] as? String == "/tmp/hello.txt")
        #expect(r?.1["content"] as? String == "hello world")
    }

    @Test("Qwen3 native parameter-less call (EnterPlanMode) rescued when declared")
    func qwenNativeNoParams() {
        let (_, blocks) = ToolCallRepair.rescue(
            text: "<function=EnterPlanMode></function>", toolNames: ["EnterPlanMode"])
        let r = first(blocks)
        #expect(r?.0 == "EnterPlanMode")
        #expect(r?.1.isEmpty == true)   // legitimately no arguments
    }

    @Test("Qwen3 native call with params rescued even without declared tool names")
    func qwenNativeNoToolNames() {
        let txt = "<function=Bash>\n<parameter=command>\nls\n</parameter>\n</function>"
        let (_, blocks) = ToolCallRepair.rescue(text: txt)
        let r = first(blocks)
        #expect(r?.0 == "Bash")
        #expect(r?.1["command"] as? String == "ls")
    }

    @Test("Qwen3 native parameter-less call NOT rescued when name can't be confirmed")
    func qwenNativeNoParamsUngated() {
        // No params AND no toolNames → treated as stray prose, not a call.
        let (_, blocks) = ToolCallRepair.rescue(text: "<function=Foo></function>")
        #expect(blocks.isEmpty)
    }

    @Test("codex apply_patch rescued though it's not in the declared tools")
    func qwenApplyPatchUndeclared() {
        // codex describes apply_patch in the SYSTEM PROMPT, not the request's
        // `tools` array — so it's absent from toolNames even though the model
        // emits it. A call WITH parameters must still be rescued; otherwise it
        // leaks as text and the file is never written (the reported bug).
        let txt = """
        <tool_call>
        <function=apply_patch>
        <parameter=patch>
        *** Begin Patch
        *** Create File: /home/ubuntu/demo/build-and-run.sh
        #!/bin/bash
        echo hi
        *** End Patch
        </parameter>
        </function>
        </tool_call>
        """
        // Other tools are declared (shell/read), apply_patch is not.
        let (clean, blocks) = ToolCallRepair.rescue(text: txt, toolNames: ["shell", "read"])
        let r = first(blocks)
        #expect(r?.0 == "apply_patch")
        #expect((r?.1["patch"] as? String)?.contains("*** Begin Patch") == true)
        #expect((r?.1["patch"] as? String)?.contains("build-and-run.sh") == true)
        #expect(clean.isEmpty)   // the <tool_call> wrapper is stripped too
    }

    // MARK: XML-element calls <ToolName attr="…"/>

    @Test("XML-element call converts attributes to parameters (declared tool)")
    func xmlElement() {
        let (_, blocks) = ToolCallRepair.rescue(
            text: #"<Read file_path="/etc/hosts"/>"#, toolNames: ["Read"])
        let r = first(blocks)
        #expect(r?.0 == "Read")
        #expect(r?.1["file_path"] as? String == "/etc/hosts")
    }

    @Test("XML-element attribute values are HTML-decoded")
    func xmlElementHTMLDecode() {
        let (_, blocks) = ToolCallRepair.rescue(
            text: #"<Bash command="echo &lt;hi&gt; &amp;&amp; ls"/>"#, toolNames: ["Bash"])
        #expect(first(blocks)?.1["command"] as? String == "echo <hi> && ls")
    }

    @Test("XML-element gated: undeclared element name is left as prose")
    func xmlElementGated() {
        let txt = #"Use <thinking step="1"/> tags to reason."#
        let (clean, blocks) = ToolCallRepair.rescue(text: txt, toolNames: ["Read"])
        #expect(blocks.isEmpty)
        #expect(clean.contains("<thinking"))
    }

    // MARK: bare JSON object tool calls

    @Test("Bare JSON object with \"arguments\" is rescued")
    func bareJSONArguments() {
        let (_, blocks) = ToolCallRepair.rescue(
            text: #"{"name":"Bash","arguments":{"command":"pwd"}}"#)
        let r = first(blocks)
        #expect(r?.0 == "Bash")
        #expect(r?.1["command"] as? String == "pwd")
    }

    @Test("Bare JSON object with \"parameters\" (nested braces) is rescued")
    func bareJSONParameters() {
        let txt = #"```json\n{"name":"Write","parameters":{"file_path":"/a","content":"{nested}"}}\n```"#
        let (_, blocks) = ToolCallRepair.rescue(text: txt)
        let r = first(blocks)
        #expect(r?.0 == "Write")
        #expect(r?.1["file_path"] as? String == "/a")
    }

    // MARK: clean text / negative

    @Test("Clean prose yields no rescued calls")
    func cleanProse() {
        let (_, blocks) = ToolCallRepair.rescue(
            text: "I updated the function and ran the tests; all green.",
            toolNames: ["Bash", "Write"])
        #expect(blocks.isEmpty)
    }

    @Test("Code fences + tool_call wrappers are stripped from cleaned text")
    func cleanedStripsWrappers() {
        let txt = "```xml\n<function=Read>\n<parameter=file_path>\n/x\n</parameter>\n</function>\n```"
        let (clean, blocks) = ToolCallRepair.rescue(text: txt, toolNames: ["Read"])
        #expect(blocks.count == 1)
        #expect(!clean.contains("```"))
        #expect(!clean.contains("<function"))
    }
}
