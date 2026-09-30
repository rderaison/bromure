use std::io::{BufRead, Write};
use serde_json::Value;
use serde::de::DeserializeOwned;
use tower_mcp_types::protocol::*;

fn decode<T: DeserializeOwned>(p: &Value) -> Result<T, String> {
    serde_json::from_value::<T>(p.clone()).map_err(|e| e.to_string())
}
fn d<T: DeserializeOwned>(p: &Value) -> Result<(), String> { decode::<T>(p).map(|_| ()) }

fn validate(v: &str, rev: &str, params: &Value) -> Result<(), String> {
    match v {
        "Object" => Ok(()),
        "Initialize" => d::<InitializeParams>(params),
        "Complete" => d::<CompleteParams>(params),
        "SetLogLevel" => d::<SetLogLevelParams>(params),
        "GetPrompt" => d::<GetPromptParams>(params),
        "ListPrompts" => d::<ListPromptsParams>(params),
        "ListResources" => d::<ListResourcesParams>(params),
        "ListResourceTemplates" => d::<ListResourceTemplatesParams>(params),
        "ReadResource" => d::<ReadResourceParams>(params),
        "SubscribeResource" => d::<SubscribeResourceParams>(params),
        "UnsubscribeResource" => d::<UnsubscribeResourceParams>(params),
        "CallTool" => d::<CallToolParams>(params),
        "ListTools" => d::<ListToolsParams>(params),
        "CreateMessage" => d::<CreateMessageParams>(params),
        "ListRoots" => d::<ListRootsParams>(params),
        "Elicit" => if rev == "2025-06-18" { d::<ElicitFormParams>(params) } else { d::<ElicitRequestParams>(params) },
        "GetTask" => d::<GetTaskInfoParams>(params),
        "GetTaskResult" => d::<GetTaskResultParams>(params),
        "ListTasks" => d::<ListTasksParams>(params),
        "CancelTask" => d::<CancelTaskParams>(params),
        "Discover" => d::<DiscoverParams>(params),
        "SubscriptionsListen" => { let p = decode::<SubscriptionsListenParams>(params)?; if p.notifications.is_none() { Err("notifications missing".into()) } else { Ok(()) } }
        "Cancelled" => { let p = decode::<CancelledParams>(params)?; if p.request_id.is_none() { Err("requestId missing".into()) } else { Ok(()) } }
        "Progress" => d::<ProgressParams>(params),
        "LoggingMessage" => { if params.get("data").is_none() { return Err("data missing".into()) } d::<LoggingMessageParams>(params) }
        "ResourceUpdated" => if params.get("uri").is_some_and(Value::is_string) { Ok(()) } else { Err("uri".into()) },
        "TaskStatus" => d::<TaskStatusParams>(params),
        "ElicitationComplete" => d::<ElicitationCompleteParams>(params),
        "SubscriptionsAcknowledged" => d::<SubscriptionsAcknowledgedParams>(params),
        _ => Err(format!("unknown validator {v}")),
    }
}

// Input lines: {"v":..., "r":..., "p":...}; output: "OK" or "ERR <msg>"
fn main() {
    let stdin = std::io::stdin();
    let mut out = std::io::BufWriter::new(std::io::stdout());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        if line.trim().is_empty() { continue; }
        let item: Value = match serde_json::from_str(&line) { Ok(v) => v, Err(e) => { writeln!(out, "BADLINE {e}").unwrap(); continue; } };
        let v = item["v"].as_str().unwrap();
        let r = item["r"].as_str().unwrap();
        let p = &item["p"];
        match validate(v, r, p) {
            Ok(()) => writeln!(out, "OK").unwrap(),
            Err(e) => writeln!(out, "ERR {}", e.replace('\n', " ")).unwrap(),
        }
    }
}
