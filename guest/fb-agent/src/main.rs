// fb-agent — guest-side framebuffer push agent (Bromure AC, Windows port).
//
// On macOS the host gets `VZVirtualMachineView` for free; on Windows we
// have no equivalent, so we run a tiny agent inside the guest that
// captures from the X server (XDamage) and pushes damage-rect updates
// over vsock to the host's `SwapChainPanel` (or WPF `D3DImage`).
//
// This is the Phase-0 spike skeleton — the wire protocol and run loop
// are stubbed to a printable shape so the host-side `VsockBridge` can
// be exercised in isolation. The XDamage capture path is left as a
// TODO (links to xcb-damage / xcb-shm) so the guest image can be built
// without the full graphics stack on day one.
//
// Wire protocol (vsock port 8448, host-side AF_VSOCK listener):
//
//   header (8 B):  magic="FBA1" (4) + payload_len u32 LE
//   payload:       JSON; one frame envelope (see Frame below)
//
// The host accepts frames in batches; the agent never blocks waiting
// for an ACK.

use std::io::{Read, Write};
use std::time::Duration;

use anyhow::{Context, Result};
use log::{info, warn};
use serde::{Deserialize, Serialize};

const FB_PORT: u32 = 8448;
const MAGIC: &[u8; 4] = b"FBA1";

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Frame {
    /// Sent right after connect — describes what the host should expect.
    Hello {
        protocol_version: u32,
        screen_width: u32,
        screen_height: u32,
        bytes_per_pixel: u32,
    },
    /// One or more dirty rectangles in the most recent capture.
    /// Pixels are zstd-compressed BGRA8 (we'll switch to NVENC/AMF
    /// H.264 once the host pipeline can decode it).
    Damage {
        rects: Vec<Rect>,
    },
    /// Frame interval, in ms. Host can pace its own redraws off this.
    Heartbeat { tick_ms: u32 },
}

#[derive(Debug, Serialize, Deserialize)]
struct Rect {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Compressed pixel run. Length matches `compressed_len` in the
    /// outer envelope; the agent never embeds inline pixel data in
    /// JSON — pixels follow the JSON envelope on the same vsock conn.
    compressed_len: u32,
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    info!("fb-agent starting on vsock port {}", FB_PORT);

    // Connect to the host. On Windows the host endpoint is exposed as a
    // named pipe; from inside the guest, both Linux/macOS hosts and
    // Windows hosts look the same — AF_VSOCK to (CID_HOST, FB_PORT).
    let mut stream = open_host_vsock(FB_PORT)
        .context("vsock connect to host failed; is QEMU running with vhost-vsock?")?;

    // Hello — describe the screen. Real values come from the X server;
    // the spike hard-codes 1920x1080 BGRA8 to validate the wire shape.
    write_frame(&mut stream, Frame::Hello {
        protocol_version: 1,
        screen_width: 1920,
        screen_height: 1080,
        bytes_per_pixel: 4,
    })?;

    // TODO(real): set up XDamage on :0, register damage handler,
    // capture the bounding rect via xcb-shm, zstd-compress, push.
    // Until then, send heartbeats so the host can verify connectivity.
    let mut tick = 0u32;
    loop {
        write_frame(&mut stream, Frame::Heartbeat { tick_ms: tick })?;
        tick = tick.wrapping_add(33);
        std::thread::sleep(Duration::from_millis(33));
    }
}

#[cfg(unix)]
fn open_host_vsock(port: u32) -> Result<std::net::TcpStream> {
    // The actual implementation uses libc::socket(AF_VSOCK, SOCK_STREAM)
    // + connect((VMADDR_CID_HOST, port)). For the v0 skeleton we keep
    // the shape decoupled by returning a TcpStream; switch to the real
    // vsock crate once the host supports it.
    use std::net::TcpStream;
    let _ = port;
    TcpStream::connect(("127.0.0.1", 8448))
        .map_err(|e| anyhow::anyhow!("tcp fallback connect failed: {e}"))
}

#[cfg(not(unix))]
fn open_host_vsock(_port: u32) -> Result<std::net::TcpStream> {
    anyhow::bail!("fb-agent only runs inside the guest");
}

fn write_frame<W: Write>(w: &mut W, frame: Frame) -> Result<()> {
    let payload = serde_json::to_vec(&frame)?;
    let mut header = [0u8; 8];
    header[0..4].copy_from_slice(MAGIC);
    header[4..8].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(&payload)?;
    Ok(())
}

#[allow(dead_code)]
fn read_frame<R: Read>(r: &mut R) -> Result<Frame> {
    let mut header = [0u8; 8];
    r.read_exact(&mut header)?;
    if &header[0..4] != MAGIC {
        warn!("bad magic {:x?}", &header[0..4]);
        anyhow::bail!("framing error");
    }
    let len = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    Ok(serde_json::from_slice(&buf)?)
}
