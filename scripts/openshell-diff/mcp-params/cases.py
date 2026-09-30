import json
R="2025-11-25"
C=[]  # (validator, revision, params, label)
def c(v,p,label,r=R): C.append((v,r,p,label))
meta_ok={"progressToken":"t","io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
impl={"name":"c","version":"1"}
# Object
c("Object",{"anything":[1,2]},"any object")
# Initialize
ini={"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":impl}
c("Initialize",ini,"minimal")
c("Initialize",{"protocolVersion":"x","capabilities":{}},"missing clientInfo")
c("Initialize",dict(ini,protocolVersion=1),"protocolVersion number")
c("Initialize",dict(ini,clientInfo={"name":"c","version":2}),"nested version number")
c("Initialize",dict(ini,capabilities={"roots":{"listChanged":None}}),"bool field null")
c("Initialize",dict(ini,capabilities={"extensions":{"noprefix":{}}}),"extension without prefix")
c("Initialize",dict(ini,capabilities={"extensions":{"io.x/y":1}}),"extension settings not object")
c("Initialize",dict(ini,capabilities={"extensions":{"io.x/y":{}}}),"extension ok")
c("Initialize",dict(ini,clientInfo=["c","1",None,None,None,None]),"clientInfo seq form")
c("Initialize",dict(ini,clientInfo=["c","1"]),"clientInfo short seq form")
c("Initialize",dict(ini,_meta=5),"_meta not object")
c("Initialize",dict(ini,_meta={"bad key!":1}),"_meta bad key dropped")
# Complete
comp={"ref":{"type":"ref/prompt","name":"p"},"argument":{"name":"a","value":"v"}}
c("Complete",comp,"minimal")
c("Complete",{"ref":{"type":"ref/prompt","name":"p"}},"missing argument")
c("Complete",dict(comp,ref={"type":"ref/other","name":"p"}),"unknown tag")
c("Complete",dict(comp,ref={"type":0,"name":"p"}),"numeric tag via Value")
c("Complete",dict(comp,ref={"type":"ref/resource","name":"p"}),"resource missing uri")
c("Complete",dict(comp,ref=["ref/prompt","p"]),"tagged seq form")
c("Complete",dict(comp,context={"arguments":{"a":1}}),"context argument number")
# SetLogLevel
c("SetLogLevel",{"level":"debug"},"minimal")
c("SetLogLevel",{},"missing level")
c("SetLogLevel",{"level":"verbose"},"unknown level")
c("SetLogLevel",{"level":{"info":None}},"level map form")
c("SetLogLevel",{"level":{"info":{}}},"level map form empty object payload")
c("SetLogLevel",{"level":"info","_meta":{"io.modelcontextprotocol/logLevel":"nope"}},"meta logLevel invalid")
c("SetLogLevel",{"level":"info","_meta":{"progressToken":1.5}},"meta progressToken float")
# GetPrompt
c("GetPrompt",{"name":"p"},"minimal")
c("GetPrompt",{"arguments":{}},"missing name")
c("GetPrompt",{"name":"p","arguments":None},"arguments null")
c("GetPrompt",{"name":"p","arguments":{"a":1}},"argument value number")
c("GetPrompt",{"name":"p","inputResponses":{"x":{"action":"accept"}}},"inputResponse elicit")
c("GetPrompt",{"name":"p","inputResponses":{"x":{"action":"maybe"}}},"inputResponse unknown")
c("GetPrompt",{"name":"p","inputResponses":{"x":{"roots":[]}}},"inputResponse roots")
c("GetPrompt",{"name":"p","inputResponses":{"x":[[]]}},"inputResponse seq form roots")
# List*
for v in ["ListPrompts","ListResources","ListResourceTemplates","ListTools"]:
    c(v,{},"empty")
    c(v,{"cursor":None,"_meta":meta_ok},"null cursor + meta")
    c(v,{"cursor":5},"cursor number")
    c(v,{"_meta":{"io.modelcontextprotocol/clientInfo":{"name":"x"}}},"meta clientInfo missing version")
    c(v,{"_meta":[]},"_meta array")
# ReadResource / Subscribe / Unsubscribe
for v in ["ReadResource","SubscribeResource","UnsubscribeResource"]:
    c(v,{"uri":"file:///a"},"minimal")
    c(v,{},"missing uri")
    c(v,{"uri":["file:///a"]},"uri array")
    c(v,{"uri":"u","_meta":{"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":"yes"}}}},"nested meta error")
c("ReadResource",{"uri":"u","requestState":1},"requestState number")
# CallTool
c("CallTool",{"name":"t"},"minimal")
c("CallTool",{"arguments":{}},"missing name")
c("CallTool",{"name":"t","arguments":None},"arguments null ok")
c("CallTool",{"name":"t","arguments":"x"},"arguments string ok")
c("CallTool",{"name":1},"name number")
c("CallTool",{"name":"t","task":{"ttl":-1}},"ttl negative")
c("CallTool",{"name":"t","task":{"ttl":1.5}},"ttl float")
c("CallTool",{"name":"t","task":{"ttl":1.0}},"ttl 1.0")
c("CallTool",{"name":"t","task":{"ttl":18446744073709551615}},"ttl u64 max")
c("CallTool",{"name":"t","task":{"ttl":18446744073709551616}},"ttl beyond u64")
c("CallTool",{"name":"t","_meta":{"progressToken":9223372036854775808}},"progressToken beyond i64")
c("CallTool",{"name":"t","_meta":{"progressToken":-9223372036854775808}},"progressToken i64 min")
c("CallTool",{"name":"t","inputResponses":{"a":{"content":{"type":"text","text":"x"},"model":"m","role":"user"}}},"inputResponse createMessage")
c("CallTool",{"name":"t","inputResponses":{"a":{"content":{"type":0,"text":"x"},"model":"m","role":"user"}}},"sampling tag variant index in Content")
c("CallTool",{"name":"t","inputResponses":{"a":{"content":{"type":5,"text":"x"},"model":"m","role":"user"}}},"sampling tag index out of range")
c("CallTool",{"name":"t","inputResponses":{"a":{"content":{"type":"text","text":"x","annotations":{"audience":[{"user":{}}]}},"model":"m","role":"user"}}},"unit variant empty map in owned Content")
c("CallTool",{"name":"t","inputResponses":{"a":{"content":{"type":"text","text":"x"},"model":"m","role":{"user":{}}}}},"unit variant empty map in Content ref")
c("CallTool",{"name":"t","inputResponses":{"a":{"action":"accept","content":{"f":[1]}}}},"elicit field value mixed array")
# CreateMessage
cm={"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],"maxTokens":10}
c("CreateMessage",cm,"minimal")
c("CreateMessage",{"messages":[]},"missing maxTokens")
c("CreateMessage",dict(cm,maxTokens=4294967296),"maxTokens > u32")
c("CreateMessage",dict(cm,maxTokens=4294967295),"maxTokens u32 max")
c("CreateMessage",dict(cm,maxTokens=-1),"maxTokens negative")
c("CreateMessage",dict(cm,messages=[{"role":"user","content":{"type":"image","data":"d"}}]),"image missing mimeType")
c("CreateMessage",dict(cm,messages=[{"role":"user","content":[{"type":"tool_use","id":"1","name":"n"}]}]),"tool_use missing input")
c("CreateMessage",dict(cm,messages=[{"role":"user","content":[{"type":"tool_result","toolUseId":"1","content":[{"type":"text","text":1}]}]}]),"nested tool_result text number")
c("CreateMessage",dict(cm,tools=[{"name":"t","inputSchema":None}]),"tool inputSchema null ok")
c("CreateMessage",dict(cm,tools=[{"name":"t"}]),"tool missing inputSchema")
c("CreateMessage",dict(cm,includeContext="allServers"),"includeContext allServers")
# ListRoots
c("ListRoots",{},"empty")
c("ListRoots",{"_meta":"x"},"_meta string")
# Elicit
form={"message":"m","requestedSchema":{"type":"object","properties":{"a":{"type":"string"}}}}
url={"mode":"url","elicitationId":"e","message":"m","url":"u"}
c("Elicit",form,"form 2025-06-18","2025-06-18")
c("Elicit",url,"url under 2025-06-18 rejected","2025-06-18")
c("Elicit",url,"url under 2025-11-25 ok")
c("Elicit",{"message":"m"},"missing schema")
c("Elicit",dict(form,requestedSchema={"type":"object","properties":{"a":{"type":"integer","minimum":1.5}}}),"integer schema float minimum")
c("Elicit",dict(form,requestedSchema={"type":"object","properties":{"a":{"type":"string","enum":None}}}),"enum null counts as present")
c("Elicit",dict(form,requestedSchema={"type":"object","properties":{"a":{"type":7}}}),"non-string type is Raw")
# Tasks
for v in ["GetTask","GetTaskResult","CancelTask"]:
    c(v,{"taskId":"t"},"minimal")
    c(v,{},"missing taskId")
    c(v,{"taskId":7},"taskId number")
c("CancelTask",{"taskId":"t","reason":[]},"reason array")
c("ListTasks",{},"empty")
c("ListTasks",{"status":"input_required"},"status")
c("ListTasks",{"status":"inputRequired"},"status camelCase rejected")
c("Discover",{},"empty")
c("Discover",{"_meta":{"io.modelcontextprotocol/clientCapabilities":{"sampling":{"tools":[1]}}}},"empty struct nonempty seq")
c("Discover",{"_meta":{"io.modelcontextprotocol/clientCapabilities":{"sampling":{"tools":[]}}}},"empty struct empty seq")
# SubscriptionsListen
c("SubscriptionsListen",{"notifications":{}},"minimal")
c("SubscriptionsListen",{},"missing notifications")
c("SubscriptionsListen",{"notifications":None},"null notifications")
c("SubscriptionsListen",{"notifications":{"taskIds":[1]}},"taskIds numbers")
# Cancelled
c("Cancelled",{"requestId":1},"minimal")
c("Cancelled",{},"missing requestId")
c("Cancelled",{"requestId":None},"null requestId")
c("Cancelled",{"requestId":1.5},"float requestId")
c("Cancelled",{"requestId":-7,"reason":None},"negative requestId")
c("Cancelled",{"requestId":"r","reason":1},"reason number")
# Progress
c("Progress",{"progressToken":"t","progress":0.5},"minimal")
c("Progress",{"progressToken":"t"},"missing progress")
c("Progress",{"progressToken":True,"progress":1},"bool token")
c("Progress",{"progressToken":1.0,"progress":1},"float token")
c("Progress",{"progressToken":"t","progress":"1"},"progress string")
# LoggingMessage
c("LoggingMessage",{"level":"info","data":None},"null data present")
c("LoggingMessage",{"level":"info"},"missing data")
c("LoggingMessage",{"level":"loud","data":1},"bad level")
c("LoggingMessage",{"level":"info","data":1,"logger":1},"logger number")
# ResourceUpdated
c("ResourceUpdated",{"uri":"u"},"minimal")
c("ResourceUpdated",{},"missing uri")
c("ResourceUpdated",{"uri":1},"uri number")
c("ResourceUpdated",{"uri":"u","_meta":7},"meta not checked")
# TaskStatus
ts={"taskId":"t","status":"working","createdAt":"c","lastUpdatedAt":"l"}
c("TaskStatus",ts,"minimal (ttl Option absent)")
c("TaskStatus",{k:v for k,v in ts.items() if k!="createdAt"},"missing createdAt")
c("TaskStatus",dict(ts,status="done"),"bad status")
c("TaskStatus",dict(ts,ttl=-1),"negative ttl")
c("TaskStatus",dict(ts,pollInterval=2.5),"float pollInterval")
# ElicitationComplete
c("ElicitationComplete",{"elicitationId":"e"},"minimal")
c("ElicitationComplete",{},"missing id")
c("ElicitationComplete",{"elicitationId":None},"null id")
# SubscriptionsAcknowledged
c("SubscriptionsAcknowledged",{"notifications":{}},"minimal")
c("SubscriptionsAcknowledged",{},"missing notifications")
c("SubscriptionsAcknowledged",{"notifications":{},"_meta":{"io.modelcontextprotocol/subscriptionId":1.5}},"subscriptionId float")
c("SubscriptionsAcknowledged",{"notifications":{"toolsListChanged":"y"}},"nested bool string")

with open("cases.jsonl","w") as f:
    for v,r,p,l in C: f.write(json.dumps({"v":v,"r":r,"p":p})+"\n")
with open("cases.meta","w") as f:
    for v,r,p,l in C: f.write(json.dumps([v,r,json.dumps(p),l])+"\n")
