//! Bromure differential-test oracle (scratch; not part of OpenShell).
//! Reads JSONL cases from $BROMURE_ORACLE_IN, writes decisions to
//! $BROMURE_ORACLE_OUT using OpenShell's own engine and request parsers.
#![cfg(test)]

use std::io::{BufRead, Write};
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::l7::jsonrpc::JsonRpcInspectionOptions;
use crate::l7::path::{CanonicalizeOptions, canonicalize_request_target};
use crate::l7::relay::{L7EvalContext, evaluate_l7_request};
use crate::l7::{L7RequestInfo, parse_l7_config};
use crate::opa::{NetworkInput, OpaEngine};

const REGO: &str = include_str!("../data/sandbox-policy.rego");

fn eval_case(case: &Value) -> Value {
    let id = case["id"].clone();
    let policy = case["policy"].as_str().unwrap_or("");
    // What `openshell policy set` enforces before a policy reaches a sandbox:
    // schema parse + validation + endpoint-ambiguity rejection.
    let gateway: Result<(), String> = openshell_policy::parse_sandbox_policy(policy)
        .map_err(|e| format!("parse: {e}"))
        .and_then(|p| openshell_policy::validate_and_canonicalize_sandbox_policy(p)
            .map_err(|e| format!("validate: {e}")))
        .and_then(|p| {
            let a = openshell_policy::find_endpoint_ambiguities(&p);
            if a.is_empty() { Ok(()) } else { Err(format!("ambiguity: {}", a[0])) }
        });
    if let Err(e) = gateway {
        return json!({"id": id, "load_ok": false, "load_error": e, "gateway": true});
    }
    let engine = match OpaEngine::from_strings(REGO, policy) {
        Ok(e) => e,
        Err(e) => return json!({"id": id, "load_ok": false, "load_error": format!("{e}")}),
    };
    let host = case["host"].as_str().unwrap_or("").to_string();
    let port = case["port"].as_u64().unwrap_or(443) as u16;
    let binary = case["binary"].as_str().unwrap_or("/usr/bin/curl").to_string();
    let ancestors: Vec<String> = case["ancestors"].as_array().map(|a| {
        a.iter().filter_map(|v| v.as_str().map(String::from)).collect()
    }).unwrap_or_default();
    let input = NetworkInput {
        host: host.clone(),
        port,
        binary_path: PathBuf::from(&binary),
        binary_sha256: String::new(),
        ancestors: ancestors.iter().map(PathBuf::from).collect(),
        cmdline_paths: vec![],
    };
    let l4 = match engine.evaluate_network(&input) {
        Ok(d) => d,
        Err(e) => return json!({"id": id, "load_ok": true, "l4_error": format!("{e}")}),
    };
    let mut out = json!({"id": id, "load_ok": true, "l4_allowed": l4.allowed,
                         "l4_policy": l4.matched_policy});
    if l4.allowed && case.get("resolved").is_some() {
        let ips: Vec<std::net::IpAddr> = case["resolved"].as_array().unwrap().iter()
            .filter_map(|v| v.as_str()).filter_map(|s| s.parse().ok()).collect();
        match engine.authorize_egress(&input) {
            Ok(auth) => match crate::proxy::bromure_dest_oracle::oracle_destination(&auth, &host, port, &ips) {
                Ok(addrs) => { out["dest_ok"] = json!(true); out["dest_addrs"] = json!(addrs); }
                Err(e) => { out["dest_ok"] = json!(false); out["dest_reason"] = json!(e); }
            },
            Err(e) => { out["dest_error"] = json!(format!("{e}")); }
        }
    }
    let Some(req) = case.get("request") else { return out };
    if !l4.allowed { return out; }

    // Which L7 config applies: as the relay does — canonicalize (encoded
    // slash taken permissively across configs), then the most specific config
    // whose path selector matches; none → deny.
    let auth = match engine.authorize_egress(&input) {
        Ok(a) => a,
        Err(e) => { out["l7_error"] = json!(format!("{e}")); return out; }
    };
    let configs: Vec<_> = auth.endpoint_configs.iter().filter_map(parse_l7_config).collect();
    if configs.is_empty() { out["l7_inspected"] = json!(false); return out; }
    out["l7_inspected"] = json!(true);

    let method = req["method"].as_str().unwrap_or("GET").to_string();
    let target = req["target"].as_str().unwrap_or("/").to_string();
    let any_slash = configs.iter().any(|c| c.allow_encoded_slash);
    let opts = CanonicalizeOptions { allow_encoded_slash: any_slash, ..Default::default() };
    let (canon, query) = match canonicalize_request_target(&target, &opts) {
        Ok(v) => v,
        Err(e) => { out["l7_allowed"] = json!(false); out["canonical_error"] = json!(format!("{e}")); return out; }
    };
    out["canonical"] = json!(canon.path);
    let Some(config) = configs.iter().filter(|c| c.matches_path(&canon.path)).max_by_key(|c| c.path_specificity()) else {
        out["l7_allowed"] = json!(false);
        out["l7_reason"] = json!("no L7 endpoint path matched request");
        return out;
    };
    let config = config.clone();
    out["l7_protocol"] = json!(format!("{:?}", config.protocol).to_lowercase());
    if !config.allow_encoded_slash && crate::l7::path::canonical_path_has_encoded_slash(&canon.path) {
        out["l7_allowed"] = json!(false);
        out["l7_reason"] = json!("encoded slash not allowed on this endpoint");
        return out;
    }
    let query_params = match query.as_deref().map(crate::l7::rest::parse_query_params) {
        Some(Ok(q)) => q,
        Some(Err(e)) => { out["l7_allowed"] = json!(false); out["query_error"] = json!(format!("{e}")); return out; }
        None => Default::default(),
    };
    let body = req["body"].as_str().unwrap_or("").as_bytes().to_vec();
    let proto = format!("{:?}", config.protocol).to_lowercase();
    let ctx = L7EvalContext {
        host: host.clone(), port, policy_name: l4.matched_policy.clone().unwrap_or_default(),
        binary_path: binary, ancestors, cmdline_paths: vec![],
        ..Default::default()
    };
    let mut info = L7RequestInfo { action: method.clone(), target: canon.path.clone(), query_params: query_params.clone(), graphql: None, jsonrpc: None };
    if proto == "graphql" {
        // As the relay: header checks, bounded body, then classify_request.
        if let Some(h) = req["headers"].as_object() {
            for (k, v) in h {
                let (k, v) = (k.to_ascii_lowercase(), v.as_str().unwrap_or("").trim().to_ascii_lowercase());
                if (k == "content-encoding" && !v.is_empty() && v != "identity") || (k == "content-type" && v.starts_with("multipart/")) {
                    out["l7_allowed"] = json!(false); out["l7_reason"] = json!("GraphQL unsupported header"); return out;
                }
            }
        }
        if body.len() > config.graphql_max_body_bytes {
            out["l7_allowed"] = json!(false); out["l7_reason"] = json!("GraphQL body exceeds limit"); return out;
        }
        let l7req = crate::l7::provider::L7Request {
            action: method.clone(), target: canon.path.clone(), query_params: query_params.clone(),
            raw_header: Vec::new(), body_length: crate::l7::provider::BodyLength::None,
        };
        info.graphql = Some(crate::l7::graphql::classify_request(&l7req, &body));
    } else if proto == "jsonrpc" || proto == "mcp" {
        // As the relay does: bounded body read, receive-stream detection,
        // config-profile parse, then MCP revision selection + re-inspection.
        if body.len() > config.json_rpc_max_body_bytes {
            out["l7_allowed"] = json!(false);
            out["l7_reason"] = json!("JSON-RPC body exceeds inspection limit");
            return out;
        }
        let mut raw = format!("{method} {target} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n");
        if let Some(v) = req["mcp_version"].as_str() { raw += &format!("MCP-Protocol-Version: {v}\r\n"); }
        if let Some(h) = req["headers"].as_object() {
            for (k, v) in h { raw += &format!("{k}: {}\r\n", v.as_str().unwrap_or("")); }
        }
        if !body.is_empty() { raw += &format!("Content-Length: {}\r\n", body.len()); }
        raw += "\r\n";
        let mut raw = raw.into_bytes();
        raw.extend_from_slice(&body);
        let l7req = crate::l7::provider::L7Request {
            action: method.clone(), target: canon.path.clone(), query_params: query_params.clone(),
            raw_header: raw,
            body_length: if body.is_empty() { crate::l7::provider::BodyLength::None }
                         else { crate::l7::provider::BodyLength::ContentLength(body.len() as u64) },
        };
        let info0 = if crate::l7::jsonrpc::jsonrpc_receive_stream_request(&l7req) {
            crate::l7::jsonrpc::JsonRpcRequestInfo::receive_stream()
        } else {
            crate::l7::jsonrpc::parse_jsonrpc_body_with_options(&body, JsonRpcInspectionOptions::for_config(&config))
        };
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let mut sink: Vec<u8> = Vec::new();
        match rt.block_on(crate::l7::relay::enforce_mcp_protocol_version(&config, &l7req, info0, &mut sink, &ctx, &canon.path, None)) {
            Ok(Some(i)) => {
                info.jsonrpc = Some(i);
            }
            Ok(None) => {
                let text = String::from_utf8_lossy(&sink).to_string();
                out["l7_allowed"] = json!(false);
                out["l7_reason"] = json!(text.lines().last().unwrap_or("").to_string());
                return out;
            }
            Err(e) => { out["l7_allowed"] = json!(false); out["l7_reason"] = json!(format!("{e}")); return out; }
        }
    }
    let tunnel = match engine.clone_engine_for_tunnel(engine.current_generation()) {
        Ok(t) => t,
        Err(e) => { out["l7_error"] = json!(format!("{e}")); return out; }
    };
    match evaluate_l7_request(&tunnel, &ctx, &info) {
        Ok((allowed, reason)) => { out["l7_allowed"] = json!(allowed); out["l7_reason"] = json!(reason); }
        Err(e) => { out["l7_error"] = json!(format!("{e}")); }
    }
    // Client text messages on an upgraded WebSocket route.
    if let Some(msgs) = req["ws_messages"].as_array() {
        if proto == "websocket" {
            let enforce = matches!(config.enforcement, crate::l7::EnforcementMode::Enforce);
            let verdicts: Vec<Value> = msgs.iter().map(|m| {
                let (pass, reason) = crate::l7::websocket::bromure_ws_oracle::decide(
                    &tunnel, &ctx, &canon.path, &query_params, config.websocket_graphql_policy, enforce,
                    m.as_str().unwrap_or(""));
                json!({"pass": pass, "reason": reason})
            }).collect();
            out["ws"] = json!(verdicts);
        }
    }
    out
}

#[test]
fn bromure_oracle() {
    let (Ok(inp), Ok(outp)) = (std::env::var("BROMURE_ORACLE_IN"), std::env::var("BROMURE_ORACLE_OUT")) else {
        return;
    };
    let reader = std::io::BufReader::new(std::fs::File::open(inp).unwrap());
    let mut w = std::io::BufWriter::new(std::fs::File::create(outp).unwrap());
    for line in reader.lines() {
        let line = line.unwrap();
        if line.trim().is_empty() { continue; }
        let case: Value = serde_json::from_str(&line).unwrap();
        let res = std::panic::catch_unwind(|| eval_case(&case))
            .unwrap_or_else(|_| json!({"id": case["id"], "panic": true}));
        writeln!(w, "{res}").unwrap();
    }
}
