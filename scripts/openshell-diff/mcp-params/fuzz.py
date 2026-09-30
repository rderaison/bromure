import json, random, sys, copy
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20000

impl = {"name":"c","version":"1","title":"t","description":"d","icons":[{"src":"s","mimeType":"image/png","sizes":["1x1"],"theme":"dark"}],"websiteUrl":"u","_meta":{"a/b":1}}
caps = {"roots":{"listChanged":True,"deprecated":{"since":"x","removeIn":"y","message":"m","replacement":"r"}},
        "sampling":{"tools":{},"context":{},"deprecated":{}},"elicitation":{"form":{},"url":{}},
        "tasks":{"list":{},"cancel":{},"requests":{"sampling":{"createMessage":{}},"elicitation":{"create":{}}}},
        "experimental":{"x":{"y":1}},"extensions":{"io.x/y":{"a":1}}}
reqmeta = {"progressToken":"t","io.modelcontextprotocol/protocolVersion":"2026-07-28",
           "io.modelcontextprotocol/clientInfo":impl,"io.modelcontextprotocol/clientCapabilities":caps,
           "io.modelcontextprotocol/logLevel":"info","bad key!":5,"x.y/z":{}}
ann = {"audience":["user","assistant"],"priority":0.5,"lastModified":"now"}
sc_text = {"type":"text","text":"hi","annotations":ann,"_meta":{}}
sc_img = {"type":"image","data":"d","mimeType":"m","annotations":ann}
sc_tool_use = {"type":"tool_use","id":"1","name":"n","input":{"a":1}}
sc_tool_res = {"type":"tool_result","toolUseId":"1","content":[sc_text, sc_img],"structuredContent":{"a":1},"isError":False}
cm_result = {"content":[sc_text, sc_tool_res],"model":"m","role":"assistant","stopReason":"end","_meta":{}}
roots_result = {"roots":[{"uri":"file:///","name":"r","_meta":{}}],"_meta":{}}
elicit_result = {"action":"accept","content":{"a":"s","b":1,"c":1.5,"d":True,"e":["x"]},"_meta":{}}
input_responses = {"a":cm_result,"b":roots_result,"c":elicit_result}
schema = {"type":"object","properties":{
    "s":{"type":"string","title":"t","description":"d","format":"email","pattern":"p","minLength":1,"maxLength":5,"default":"x"},
    "e":{"type":"string","enum":["a","b"],"default":"a"},
    "i":{"type":"integer","minimum":-5,"maximum":5,"default":1},
    "n":{"type":"number","minimum":0.5,"maximum":2,"default":1.5},
    "b":{"type":"boolean","default":True},
    "m":{"type":"array","items":{"type":"string","enum":["x","y"]},"uniqueItems":True,"default":["x"]},
    "r":{"whatever":1}}, "required":["s"]}
sub_filter = {"toolsListChanged":True,"promptsListChanged":False,"resourcesListChanged":True,"resourceSubscriptions":["u"],"taskIds":["t"]}

T = {
 "Object": [{"a":1}],
 "Initialize": [{"protocolVersion":"2025-06-18","capabilities":caps,"clientInfo":impl,"_meta":{"k":1}},
                {"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"a","version":"b"}}],
 "Complete": [{"ref":{"type":"ref/prompt","name":"p"},"argument":{"name":"a","value":"v"},"context":{"arguments":{"a":"b"}},"_meta":{}},
              {"ref":{"type":"ref/resource","uri":"u"},"argument":{"name":"a","value":"v"}}],
 "SetLogLevel": [{"level":"debug","_meta":reqmeta}],
 "GetPrompt": [{"name":"p","arguments":{"a":"b"},"inputResponses":input_responses,"requestState":"s","_meta":reqmeta}],
 "ListPrompts": [{"cursor":"c","_meta":reqmeta}, {}],
 "ListResources": [{"cursor":"c","_meta":reqmeta}],
 "ListResourceTemplates": [{"cursor":"c","_meta":reqmeta}],
 "ReadResource": [{"uri":"u","inputResponses":input_responses,"requestState":"s","_meta":reqmeta}],
 "SubscribeResource": [{"uri":"u","_meta":reqmeta}],
 "UnsubscribeResource": [{"uri":"u","_meta":reqmeta}],
 "CallTool": [{"name":"t","arguments":{"x":1},"inputResponses":input_responses,"requestState":"s","_meta":reqmeta,"task":{"ttl":5}}],
 "ListTools": [{"cursor":"c","_meta":reqmeta}],
 "CreateMessage": [{"messages":[{"role":"user","content":sc_text},{"role":"assistant","content":[sc_tool_use, sc_tool_res],"_meta":{}}],
                    "maxTokens":100,"systemPrompt":"s","temperature":0.5,"stopSequences":["x"],
                    "modelPreferences":{"speedPriority":1,"intelligencePriority":0.5,"costPriority":0,"hints":[{"name":"c"}]},
                    "includeContext":"thisServer","metadata":{"a":1},
                    "tools":[{"name":"t","title":"t","description":"d","inputSchema":{},"outputSchema":{},"icons":[{"src":"s"}],
                              "annotations":{"title":"x","readOnlyHint":True,"destructiveHint":False,"idempotentHint":True,"openWorldHint":False},
                              "execution":{"taskSupport":"optional"}}],
                    "toolChoice":{"mode":"auto","name":"n"},"task":{"ttl":1},"_meta":{}}],
 "ListRoots": [{"_meta":reqmeta}],
 "Elicit": [{"mode":"form","message":"m","requestedSchema":schema,"_meta":reqmeta},
            {"mode":"url","elicitationId":"e","message":"m","url":"https://x","_meta":reqmeta}],
 "GetTask": [{"taskId":"t","_meta":reqmeta}],
 "GetTaskResult": [{"taskId":"t","_meta":reqmeta}],
 "ListTasks": [{"status":"input_required","cursor":"c","_meta":reqmeta}],
 "CancelTask": [{"taskId":"t","reason":"r","_meta":reqmeta}],
 "Discover": [{"_meta":reqmeta}],
 "SubscriptionsListen": [{"notifications":sub_filter,"_meta":{}}],
 "Cancelled": [{"requestId":1,"reason":"r","_meta":{}},{"requestId":"x"}],
 "Progress": [{"progressToken":"t","progress":1,"total":2.5,"message":"m","_meta":{}}],
 "LoggingMessage": [{"level":"info","logger":"l","data":{"a":1},"_meta":{}}],
 "ResourceUpdated": [{"uri":"u"}],
 "TaskStatus": [{"taskId":"t","status":"working","statusMessage":"m","createdAt":"c","lastUpdatedAt":"l","ttl":5,"pollInterval":1,"_meta":{}}],
 "ElicitationComplete": [{"elicitationId":"e","_meta":{}}],
 "SubscriptionsAcknowledged": [{"_meta":{"io.modelcontextprotocol/subscriptionId":"s"},"notifications":sub_filter}],
}
REVS = ["2025-03-26","2025-06-18","2025-11-25","2026-07-28"]
KEYS = ["type","name","uri","_meta","text","enum","items","level","data","content","role","roots","action","requestId","notifications","0","a/b","io.modelcontextprotocol/logLevel","progressToken"]

def rand_scalar():
    return random.choice([None, True, False, 0, 1, 2, 3, 4, 5, -1, -5, 1.0, 1.5, -0.5, 2**32-1, 2**32, 2**63-1, 2**63, 2**64-1, -2**63, 10**20, "", "x",
                          "info","user","assistant","text","tool_result","ref/prompt","ref/resource","string","integer","number","boolean","array",
                          "accept","working","form","url","dark","auto","none","thisServer","optional","a/b","bad key","-x","io.x/y"])
def rand_value(depth=0):
    r = random.random()
    if depth > 2 or r < 0.6: return rand_scalar()
    if r < 0.8: return [rand_value(depth+1) for _ in range(random.randint(0,3))]
    return {random.choice(KEYS): rand_value(depth+1) for _ in range(random.randint(0,3))}

def paths(v, prefix=()):
    yield prefix
    if isinstance(v, dict):
        for k, x in v.items(): yield from paths(x, prefix + (k,))
    elif isinstance(v, list):
        for i, x in enumerate(v): yield from paths(x, prefix + (i,))

def get(v, p):
    for k in p: v = v[k]
    return v
def setp(root, p, val):
    if not p: return val
    get(root, p[:-1])[p[-1]] = val
    return root

def mutate(v):
    ps = list(paths(v))
    p = random.choice(ps)
    cur = get(v, p)
    op = random.random()
    if op < 0.25 and p:
        par = get(v, p[:-1])
        if isinstance(par, dict): del par[p[-1]]
        else: par.pop(p[-1])
        return v
    if op < 0.5:
        return setp(v, p, rand_value())
    if op < 0.62 and isinstance(cur, dict):
        # seq form: object -> array of its values, maybe truncated/extended
        vals = list(cur.values())
        if "type" in cur and random.random() < 0.5:
            vals = [cur["type"]] + [x for k, x in cur.items() if k != "type"]
        r = random.random()
        if r < 0.3 and vals: vals = vals[:random.randint(0, len(vals))]
        elif r < 0.5: vals = vals + [rand_value()]
        return setp(v, p, vals)
    if op < 0.72 and isinstance(cur, dict):
        cur[random.choice(KEYS)] = rand_value()
        return v
    if op < 0.8 and isinstance(cur, dict) and "type" in cur:
        cur["type"] = random.choice([0, 1, 2, 3, 4, 5, -1, 1.0, "text", "image", "audio", "tool_use", "tool_result", "ref/prompt", "ref/resource", "string", "array", "x", None])
        return v
    if op < 0.88 and isinstance(cur, str):
        # wrap unit enum string into {name: null} or {name: x}
        return setp(v, p, {cur: random.choice([None, None, 1, {}])})
    if op < 0.94:
        return setp(v, p, [cur])
    return setp(v, p, rand_value())

out = sys.stdout
for i in range(N):
    v = random.choice(list(T.keys()))
    base = copy.deepcopy(random.choice(T[v]))
    for _ in range(random.choice([0,1,1,2,3,5])):
        base = mutate(base)
    if not isinstance(base, dict):
        continue
    out.write(json.dumps({"v":v,"r":random.choice(REVS),"p":base}) + "\n")
