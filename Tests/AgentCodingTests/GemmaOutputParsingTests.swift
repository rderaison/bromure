import Foundation
import Testing
@testable import bromure_ac

// MARK: - Gemma 4 output parsing
//
// Gemma 4 wraps reasoning in a thought channel (`<|channel>thought … <channel|>`)
// and emits tool calls in its own native format
// (`<|tool_call>call:Name{arg:<|"|>value<|"|>}<tool_call|>`). Both leaked to the
// agent verbatim ("tools don't work"). Handling is gated on Gemma-type models:
// the engine strips channels only for gemma repos, and the rescue path parses
// the call format only with `gemma: true` (set from the request's model name).

@Suite("GemmaOutputParsing")
struct GemmaOutputParsingTests {

    // The exact leaked output observed live (hello-world Write call).
    static let leaked = """
    <|channel>thought
    The user wants to create a "Hello, World!" program in C and save it to a file named hello.c.

    Plan:
    1. Write the C code for "Hello, World!".
    2. Write this code to hello.c in the current directory.
    3. (Optional but helpful) Provide instructions on how to compile and run it.

    I'll start by writing the file.<channel|><|tool_call>call:Write{content:<|"|>#include <stdio.h>

    int main() {
        printf("Hello, World!\\n");
        return 0;
    }
    <|"|>,file_path:<|"|>/home/ubuntu/hello.c<|"|>}<tool_call|>
    """

    // MARK: Thought-channel stripping

    @Test("Thought channel is stripped; the answer survives")
    func stripBasic() {
        let s = "<|channel>thought\nlet me think about this<channel|>Here is the answer."
        #expect(MLXEngine.stripGemmaChannels(s) == "Here is the answer.")
    }

    @Test("Channel strip leaves tool-call markup intact")
    func stripKeepsToolCalls() {
        let out = MLXEngine.stripGemmaChannels(Self.leaked)
        #expect(!out.contains("<|channel>"))
        #expect(!out.contains("The user wants to create"))
        #expect(out.contains("<|tool_call>call:Write{"))
        #expect(out.contains("<tool_call|>"))
    }

    @Test("Unterminated thought is dropped; text without markers passes through")
    func stripEdges() {
        #expect(MLXEngine.stripGemmaChannels("answer<|channel>thought\ntrailing...") == "answer")
        #expect(MLXEngine.stripGemmaChannels("plain text") == "plain text")
    }

    @Test("Gemma handling is gated on the repo name")
    func gemmaGate() {
        #expect(MLXEngine.isGemmaModel("mlx-community/gemma-4-12B-it-8bit"))
        #expect(MLXEngine.isGemmaModel("mlx-community/gemma-4-12b-coder-fable5-composer2.5-4bit"))
        #expect(!MLXEngine.isGemmaModel("mlx-community/Qwen3-8B-4bit-DWQ"))
    }

    // MARK: Native tool-call rescue

    @Test("The observed leaked Write call parses: name + verbatim string args")
    func rescueObservedLeak() {
        let (cleaned, blocks) = ToolCallRepair.rescueGemmaCalls(Self.leaked)
        #expect(blocks.count == 1)
        let b = blocks[0]
        #expect(b["name"] as? String == "Write")
        let input = b["input"] as! [String: Any]
        #expect(input["file_path"] as? String == "/home/ubuntu/hello.c")
        let content = input["content"] as? String ?? ""
        #expect(content.contains("#include <stdio.h>"))
        #expect(content.contains("printf(\"Hello, World!\\n\");"))   // braces/quotes verbatim
        #expect(!cleaned.contains("<|tool_call>"))
        #expect(!cleaned.contains("<tool_call|>"))
    }

    @Test("Bare scalars: ints, doubles, bools, null")
    func rescueScalars() {
        let s = "<|tool_call>call:Config{n:3,ratio:0.5,on:true,off:false,none:null}<tool_call|>"
        let (_, blocks) = ToolCallRepair.rescueGemmaCalls(s)
        let input = blocks[0]["input"] as! [String: Any]
        #expect(input["n"] as? Int == 3)
        #expect(input["ratio"] as? Double == 0.5)
        #expect(input["on"] as? Bool == true)
        #expect(input["off"] as? Bool == false)
        #expect(input["none"] is NSNull)
    }

    @Test("Multiple calls in one blob; surrounding prose kept")
    func rescueMultiple() {
        let s = """
        First: <|tool_call>call:Read{file_path:<|"|>/etc/hosts<|"|>}<tool_call|> then \
        <|tool_call>call:Bash{command:<|"|>ls -la, then wc -l<|"|>}<tool_call|> done.
        """
        let (cleaned, blocks) = ToolCallRepair.rescueGemmaCalls(s)
        #expect(blocks.count == 2)
        #expect(blocks[0]["name"] as? String == "Read")
        #expect(blocks[1]["name"] as? String == "Bash")
        // A comma inside a quoted value must not split arguments.
        #expect((blocks[1]["input"] as! [String: Any])["command"] as? String == "ls -la, then wc -l")
        #expect(cleaned.contains("First:"))
        #expect(cleaned.contains("done."))
    }

    @Test("A truncated (unterminated) call stays visible as text")
    func rescueTruncated() {
        let s = "<|tool_call>call:Write{content:<|\"|>partial file conte"
        let (cleaned, blocks) = ToolCallRepair.rescueGemmaCalls(s)
        #expect(blocks.isEmpty)
        #expect(cleaned == s)
    }

    @Test("Rescue is gated: without gemma the markup is untouched")
    func rescueGate() {
        let s = "<|tool_call>call:Read{file_path:<|\"|>/tmp/x<|\"|>}<tool_call|>"
        let off = ToolCallRepair.rescue(text: s, toolNames: ["Read"])
        #expect(off.blocks.isEmpty)
        let on = ToolCallRepair.rescue(text: s, toolNames: ["Read"], gemma: true)
        #expect(on.blocks.count == 1)
        #expect(on.blocks[0]["name"] as? String == "Read")
    }

    @Test("repair() promotes a leaked Gemma call to tool_use with stop_reason")
    func repairEndToEnd() {
        let message: [String: Any] = [
            "content": [["type": "text", "text": Self.leaked]],
            "stop_reason": "end_turn",
        ]
        let repaired = ToolCallRepair.repair(message: message, toolNames: ["Write"], gemma: true)
        let content = repaired["content"] as! [[String: Any]]
        #expect(content.contains { ($0["type"] as? String) == "tool_use" })
        #expect(repaired["stop_reason"] as? String == "tool_use")
        // The thought text was already stripped engine-side; what remains as
        // text (if anything) must carry no Gemma markup.
        for b in content where (b["type"] as? String) == "text" {
            let t = b["text"] as? String ?? ""
            #expect(!t.contains("<|tool_call>"))
        }
    }
}
