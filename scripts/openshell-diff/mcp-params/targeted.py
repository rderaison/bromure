import json, itertools
out=[]
def add(v,p,r="2025-11-25"): out.append(json.dumps({"v":v,"r":r,"p":p}))
keys=["a/b","/b","a/","a.b/c","1a/b","a-/b","a/b-","a/-b","a/b_c","a..b/c","a/b/c","é/b","a/é","ab","a-b.c/d-e_f.g","A1/Z9","a/_b","a/b.","x","a.b","a1.b2/","-/x","a/b c","a/1","a.1b/c", "a.b1/c"]
base={"protocolVersion":"x","clientInfo":{"name":"n","version":"v"}}
for k in keys:
    for val in [{}, None, 1, [], {"x":1}]:
        add("Initialize", dict(base, capabilities={"extensions":{k:val}}))
    # meta key filtering can't break things, but nonobject meta must fail
for m in [None, 1, "s", [], {}, {"bad key":1}, {"progressToken": None}, {"progressToken": 1.5}, {"progressToken": -3}, {"progressToken": 2**63}, {"progressToken": [1]}]:
    add("ListTools", {"_meta": m}); add("Cancelled", {"requestId": 1, "_meta": m})
# numbers
nums=[0,1,-1,1.0,1.5,-0.5,2**31,2**32-1,2**32,2**63-1,2**63,2**64-1,2**64,10**30,-2**63,-2**63-1,1e3,True,None,"1"]
for n in nums:
    add("CallTool", {"name":"t","task":{"ttl":n}})
    add("Progress", {"progressToken":n,"progress":n})
    add("Cancelled", {"requestId":n})
    add("CreateMessage", {"messages":[],"maxTokens":n})
    add("TaskStatus", {"taskId":"t","status":"working","createdAt":"c","lastUpdatedAt":"l","ttl":n,"pollInterval":n})
    for t in ["integer","number","string"]:
        add("Elicit", {"message":"m","requestedSchema":{"type":"object","properties":{"x":{"type":t,"minimum":n,"minLength":n,"default":n}}}})
# tags
for t in [0,1,2,-1,1.0,"ref/prompt","ref/resource","x",None,True]:
    add("Complete", {"ref":{"type":t,"name":"n","uri":"u"},"argument":{"name":"a","value":"v"}})
    add("Complete", {"ref":[t,"n"],"argument":["a","v"]})
    for idx in [t]:
        add("CreateMessage", {"messages":[{"role":"user","content":{"type":idx,"text":"x","data":"d","mimeType":"m","id":"i","name":"n","input":1,"toolUseId":"u","content":[]}}],"maxTokens":1})
        add("CreateMessage", {"messages":[{"role":"user","content":[[idx,"x"]]}],"maxTokens":1})
        add("CallTool", {"name":"n","inputResponses":{"a":{"content":{"type":idx,"text":"x","data":"d","mimeType":"m","id":"i","name":"n","input":1,"toolUseId":"u","content":[]},"model":"m","role":"user"}}})
# unit enums
for lv in ["info",{"info":None},{"info":{}},{"info":[]},{"info":1},{"x":None},{},{"info":None,"debug":None},["info"],"INFO",None]:
    add("SetLogLevel", {"level":lv}); add("ListTasks", {"status":lv})
    add("CreateMessage", {"messages":[{"role":lv,"content":{"type":"text","text":"x","annotations":{"audience":[lv]}}}],"maxTokens":1})
    add("CallTool", {"name":"n","inputResponses":{"a":{"roots":[],"action":lv}}})
# seq forms
for arr in [[],["n"],["n","v"],["n","v",None],["n","v",None,None,None,None],["n","v",None,None,None,None,None],["n","v",None,None,None,None,None,None],["n","v",None,None,None,None,{}]]:
    add("Initialize", dict(base, capabilities={}, clientInfo=arr))
    add("CallTool", {"name":"n","inputResponses":{"a":[arr]}})
for pr in [{"type":"string","enum":None},{"type":"string","enum":["a"]},{"type":"array","items":["string",["a"]]},{"type":"array","items":["string"]},{"type":7},[1],"x",None,{"type":"boolean","default":1}]:
    add("Elicit", {"message":"m","requestedSchema":{"type":"object","properties":{"p":pr}}}, "2025-06-18")
    add("Elicit", {"message":"m","requestedSchema":{"type":"object","properties":{"p":pr}}}, "2025-11-25")
# data/null checks
add("LoggingMessage", {"level":"info","data":None}); add("LoggingMessage", {"level":"info"})
add("SubscriptionsListen", {"notifications":None}); add("SubscriptionsListen", {"notifications":{}}); add("SubscriptionsListen", {})
add("ResourceUpdated", {"uri":1}); add("ResourceUpdated", {})
add("GetPrompt", {"name":"n","arguments":None}); add("CallTool", {"name":"n","arguments":None})
add("Initialize", dict(base, capabilities={"roots":{"listChanged":None}}))
add("SubscriptionsAcknowledged", {"notifications":{}, "_meta":{"io.modelcontextprotocol/subscriptionId":1.5}})
add("SubscriptionsAcknowledged", {"notifications":{}, "_meta":{"io.modelcontextprotocol/subscriptionId":None}})
print("\n".join(out))
