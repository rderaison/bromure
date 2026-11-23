package delegation

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"sync"
)

// The bromure-delegation MCP server's instructions and tool list, generated
// from Sources/AgentCoding/DelegationMCPCatalog.swift (same text, same
// order). The hub answers initialize / tools/list with them while no
// Bromure AC relay is parked.

//go:embed catalog_instructions.txt
var catalogInstructions string

//go:embed catalog_tools.json
var catalogToolsJSON []byte

var (
	toolsOnce    sync.Once
	toolsCompact json.RawMessage
)

// Instructions is DelegationMCPCatalog.instructions.
func Instructions() string { return catalogInstructions }

// Tools is DelegationMCPCatalog.tools as a JSON array, keys in the Swift
// source's order.
func Tools() json.RawMessage {
	toolsOnce.Do(func() {
		var b bytes.Buffer
		if err := json.Compact(&b, catalogToolsJSON); err != nil {
			panic("delegation: bad embedded catalog: " + err.Error())
		}
		toolsCompact = b.Bytes()
	})
	return toolsCompact
}
