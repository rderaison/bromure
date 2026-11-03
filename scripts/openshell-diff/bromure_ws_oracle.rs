//! Bromure differential oracle, WebSocket half (scratch; test-only).
//! Mirrors `inspect_websocket_text_message` for one client text message.
use super::{GraphqlWebSocketMessage, classify_graphql_websocket_message};
use crate::l7::L7RequestInfo;
use crate::l7::relay::{L7EvalContext, evaluate_l7_request};
use crate::opa::TunnelPolicyEngine;
use std::collections::HashMap;

/// (passes, forced_deny, reason). `passes` accounts for audit enforcement.
pub(crate) fn decide(
    engine: &TunnelPolicyEngine,
    ctx: &L7EvalContext,
    target: &str,
    query: &HashMap<String, Vec<String>>,
    graphql_policy: bool,
    enforce: bool,
    text: &str,
) -> (bool, String) {
    if !graphql_policy {
        let info = L7RequestInfo { action: "WEBSOCKET_TEXT".into(), target: target.into(),
                                   query_params: query.clone(), graphql: None, jsonrpc: None };
        return match evaluate_l7_request(engine, ctx, &info) {
            Ok((allowed, reason)) => (allowed || !enforce, reason),
            Err(e) => (false, format!("error: {e}")),
        };
    }
    match classify_graphql_websocket_message(text) {
        GraphqlWebSocketMessage::Control { message_type } => (true, format!("control {message_type}")),
        GraphqlWebSocketMessage::Operation { message_type, graphql } => {
            if let Some(err) = graphql.error.as_deref() {
                return (false, format!("graphql_ws_type={message_type} rejected: {err}"));
            }
            let info = L7RequestInfo { action: "WEBSOCKET_TEXT".into(), target: target.into(),
                                       query_params: query.clone(), graphql: Some(graphql), jsonrpc: None };
            match evaluate_l7_request(engine, ctx, &info) {
                Ok((allowed, reason)) => (allowed || !enforce, format!("graphql_ws_type={message_type} {reason}")),
                Err(e) => (false, format!("error: {e}")),
            }
        }
    }
}
