package delegation

import (
	"encoding/json"
	"math"
	"strings"
	"time"
)

// shimCall is one JSON-RPC request the shim has in flight.
// DelegationShimCalls.Call.
type shimCall struct {
	id     json.RawMessage
	key    string
	line   []byte
	gen    int
	sentAt time.Time
	limit  time.Duration
	label  string
}

// untimed: a call that carries files, and `delegate`, are never timed out
// (a stream that actually drops still answers them).
const untimed = time.Duration(math.MaxInt64)

// shimCalls is DelegationShimCalls: the calls the shim has in flight, by id
// — what it sends again when its stream was the hub's local fallback
// (nothing done), and answers with an error when a relay stream drops or
// falls silent (maybe done).
type shimCalls struct {
	calls []shimCall
}

// callLimit is how long a call may go unanswered on a relay.
func callLimit(method string, params map[string]any) time.Duration {
	if method != "tools/call" {
		return 60 * time.Second
	}
	name, _ := params["name"].(string)
	args, _ := params["arguments"].(map[string]any)
	files, _ := args["files"].([]any)
	if len(files) > 0 || name == "delegate" {
		return untimed
	}
	if name == "wait" || name == "ask" || name == "request" {
		t := 50.0
		if v, ok := args["timeout_seconds"].(float64); ok {
			t = v
		}
		t = math.Min(math.Max(t, 0), 50) + 40
		return time.Duration(t * float64(time.Second))
	}
	return 300 * time.Second
}

// callKey is a request id's identity ({"k": id}, as the Swift).
func callKey(id json.RawMessage) string {
	var v any
	if json.Unmarshal(id, &v) != nil {
		return string(id)
	}
	b, err := json.Marshal(map[string]any{"k": v})
	if err != nil {
		return string(id)
	}
	return string(b)
}

type rpcMessage struct {
	method    string
	hasMethod bool
	methodStr bool
	id        json.RawMessage
	hasID     bool
	params    map[string]any
}

func parseRPC(line []byte) (rpcMessage, bool) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(line, &raw) != nil || raw == nil {
		return rpcMessage{}, false
	}
	var m rpcMessage
	if r, ok := raw["method"]; ok {
		m.hasMethod = true
		if json.Unmarshal(r, &m.method) == nil {
			m.methodStr = true
		}
	}
	if r, ok := raw["id"]; ok {
		m.hasID = true
		m.id = r
	}
	if r, ok := raw["params"]; ok {
		_ = json.Unmarshal(r, &m.params)
	}
	return m, true
}

// requestKey is the key of a request line's id ("": not a request).
func requestKey(line []byte) string {
	m, ok := parseRPC(line)
	if !ok || !m.methodStr || !m.hasID {
		return ""
	}
	return callKey(m.id)
}

// sent: a request line (a method and an id) is in flight from now.
func (c *shimCalls) sent(line []byte, gen int, now time.Time) {
	m, ok := parseRPC(line)
	if !ok || !m.methodStr || !m.hasID {
		return
	}
	k := callKey(m.id)
	c.removeKey(k)
	label := m.method
	if name, ok := m.params["name"].(string); ok {
		label = m.method + " " + name
	}
	c.calls = append(c.calls, shimCall{
		id: append(json.RawMessage(nil), m.id...), key: k,
		line: append([]byte(nil), line...), gen: gen, sentAt: now,
		limit: callLimit(m.method, m.params), label: label,
	})
}

// answered: a reply line (an id, no method) settles its call.
func (c *shimCalls) answered(line []byte) {
	m, ok := parseRPC(line)
	if !ok || m.hasMethod || !m.hasID {
		return
	}
	c.removeKey(callKey(m.id))
}

func (c *shimCalls) removeKey(k string) {
	out := c.calls[:0]
	for _, x := range c.calls {
		if x.key != k {
			out = append(out, x)
		}
	}
	c.calls = out
}

// takeGen: the calls that went out on gen, removed.
func (c *shimCalls) takeGen(gen int) []shimCall {
	var mine []shimCall
	out := c.calls[:0]
	for _, x := range c.calls {
		if x.gen == gen {
			mine = append(mine, x)
		} else {
			out = append(out, x)
		}
	}
	c.calls = out
	return mine
}

// takeKey: one call, removed (nil: already settled).
func (c *shimCalls) takeKey(k string) *shimCall {
	for i, x := range c.calls {
		if x.key == k {
			c.calls = append(c.calls[:i], c.calls[i+1:]...)
			return &x
		}
	}
	return nil
}

func (c *shimCalls) overdue(now time.Time) []shimCall {
	var out []shimCall
	for _, x := range c.calls {
		if x.limit != untimed && now.Sub(x.sentAt) > x.limit {
			out = append(out, x)
		}
	}
	return out
}

const lostText = "The link to Bromure AC dropped while this call was under way, so it may or may not have been done. Before retrying, check: list_delegations shows each one's state and last message — a reply taken by the lost call is there, not in read_inbox."

// lostReply is what the agent gets for a call lost with its stream.
func lostReply(c shimCall) []byte {
	var out []byte
	if strings.HasPrefix(c.label, "tools/call") {
		out = encodeOrdered([]orderedField{{"jsonrpc", "2.0"}, {"id", c.id},
			{"result", ordered{{"content", []any{ordered{{"type", "text"}, {"text", lostText}}}}, {"isError", true}}}})
	} else {
		out = encodeOrdered([]orderedField{{"jsonrpc", "2.0"}, {"id", c.id},
			{"error", ordered{{"code", -32000}, {"message", lostText}}}})
	}
	return append(out, '\n')
}
