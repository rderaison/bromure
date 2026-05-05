// clip-agent — guest-side clipboard bridge (Bromure AC, Windows port).
//
// Replaces `VZSpiceAgentPortAttachment` on macOS. Listens on vsock port
// 8449 for the host's clipboard channel; talks UTF-8 JSON, newline-
// delimited (the same framing the SubscriptionTokenBridge / CodexTokenBridge
// already use, so the host plumbing carries over).
//
// Wire ops (one JSON object per line, both directions):
//
//   { "op": "set",      "text": "..." }      — host wrote new clipboard
//   { "op": "get-req"   }                    — host asks for current
//   { "op": "get-resp", "text": "..." }      — guest replies
//
// Scope (v1): UTF-8 text only. Image / HTML clipboard formats are a
// follow-up — the macOS spice agent does carry them, but Bromure AC
// has only ever transferred text in practice.

use std::io::{BufRead, BufReader, Write};

use anyhow::{Context, Result};
use log::info;
use serde::{Deserialize, Serialize};

const CLIP_PORT: u32 = 8449;

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum Msg {
    Set { text: String },
    GetReq,
    GetResp { text: String },
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    info!("clip-agent starting on vsock port {}", CLIP_PORT);

    // Same shape as fb-agent: AF_VSOCK to (CID_HOST, port). Until the
    // Windows QEMU build ships vsock, both agents speak the same wire
    // format over a TCP fallback.
    let stream = std::net::TcpStream::connect(("127.0.0.1", 8449))
        .context("could not connect to host clipboard channel")?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);

    let mut line = String::new();
    while reader.read_line(&mut line)? > 0 {
        let trimmed = line.trim_end();
        let msg: Msg = match serde_json::from_str(trimmed) {
            Ok(m) => m,
            Err(_) => {
                line.clear();
                continue;
            }
        };
        match msg {
            Msg::Set { text } => {
                paste_into_clipboard(&text)?;
            }
            Msg::GetReq => {
                let text = read_from_clipboard().unwrap_or_default();
                let resp = serde_json::to_string(&Msg::GetResp { text })?;
                writer.write_all(resp.as_bytes())?;
                writer.write_all(b"\n")?;
            }
            Msg::GetResp { .. } => {
                // Should never arrive at the guest — host-only message.
            }
        }
        line.clear();
    }
    Ok(())
}

/// Push to the X11 PRIMARY+CLIPBOARD selections. Real implementation
/// shells out to `xclip` or talks ICCCM directly via xcb. Stubbed here
/// so the wire-protocol code compiles on day one.
fn paste_into_clipboard(text: &str) -> Result<()> {
    info!("[stub] would set clipboard to {} bytes", text.len());
    Ok(())
}

fn read_from_clipboard() -> Option<String> {
    None
}
