#!/usr/bin/env python3
"""Bromure "display" MCP server (stdio): show the user a picture, a video or a
chart in the chat.

Nothing is sent anywhere from here. The chat renders these tool calls from the
agent's own transcript — the call's arguments are all it needs — as inline
cards the user can pop out into a window. This server only checks the
arguments so a bad call fails loudly to the agent instead of showing the user
a broken card.
"""
import json
import mimetypes
import os
import sys

PROTOCOL = "2025-03-26"

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".bmp", ".tif", ".tiff"}
VIDEO_EXT = {".mp4", ".m4v", ".mov"}
MAX_IMAGE = 25 * 1024 * 1024
MAX_VIDEO = 500 * 1024 * 1024
MAX_SPEC = 2 * 1024 * 1024

INSTRUCTIONS = (
    "Show the user something visual, right in the Bromure chat: show_media for an "
    "image or a video file on this machine, show_chart for an interactive data chart "
    "(a Vega-Lite spec). The user sees it inline and can pop it out into its own "
    "window. Use it whenever a picture says it better than text: a screenshot, a "
    "rendered result, a plot of numbers you computed."
)

TOOLS = [
    {
        "name": "show_media",
        "description": (
            "Show the user an image (png, jpg, gif, webp, heic, …) or a video (mp4, mov, "
            "m4v) in the chat, inline with a button to pop it out. `path` must be an "
            "ABSOLUTE path to a file on this machine. Images up to 25 MB, videos up to "
            "500 MB (H.264/HEVC in mp4/mov plays everywhere)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path of the image or video file."},
                "title": {"type": "string", "description": "A short title shown above it."},
                "caption": {"type": "string", "description": "Optional text shown under it."},
            },
            "required": ["path"],
        },
    },
    {
        "name": "show_chart",
        "description": (
            "Show the user an interactive chart in the chat (inline, with a pop-out window). "
            "`spec` is a Vega-Lite v5/v6 specification (a JSON object: mark, encoding, "
            "data.values …) with the data INLINE in data.values — no URLs or files. "
            "Interactivity is yours to add: tooltips (\"tooltip\": true in the mark or a "
            "tooltip encoding), zoom/pan (params: [{name: 'grid', select: 'interval', "
            "bind: 'scales'}]), legend filters (a point selection bound to the legend), "
            "brushing. In the chat the trackpad scrolls the conversation (the user zooms "
            "with ⌥-scroll, or pops the chart out). Leave width as \"container\" so it fits "
            "the chat and the window."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "spec": {"type": "object", "description": "The Vega-Lite specification, data inline."},
                "title": {"type": "string", "description": "A short title shown above the chart."},
                "caption": {"type": "string", "description": "Optional text shown under it."},
            },
            "required": ["spec"],
        },
    },
]


def check_media(args):
    path = args.get("path")
    if not isinstance(path, str) or not path:
        return "`path` is required."
    if not os.path.isabs(path):
        return "`path` must be absolute (e.g. %s)." % os.path.abspath(path)
    if not os.path.isfile(path):
        return "No such file: %s" % path
    ext = os.path.splitext(path)[1].lower()
    size = os.path.getsize(path)
    if ext in IMAGE_EXT:
        if size > MAX_IMAGE:
            return "The image is %d MB; the limit is 25 MB." % (size // (1024 * 1024))
        kind = "image"
    elif ext in VIDEO_EXT:
        if size > MAX_VIDEO:
            return "The video is %d MB; the limit is 500 MB." % (size // (1024 * 1024))
        kind = "video"
    else:
        guess = mimetypes.guess_type(path)[0] or "unknown type"
        return ("Not a supported image or video (%s, %s). Images: %s. Videos: %s."
                % (ext or "no extension", guess, ", ".join(sorted(IMAGE_EXT)), ", ".join(sorted(VIDEO_EXT))))
    return None, kind, size


def check_chart(args):
    spec = args.get("spec")
    if isinstance(spec, str):
        try:
            spec = json.loads(spec)
        except ValueError as e:
            return "`spec` isn't valid JSON: %s" % e
    if not isinstance(spec, dict):
        return "`spec` must be a Vega-Lite specification (a JSON object)."
    if len(json.dumps(spec)) > MAX_SPEC:
        return "The spec is over 2 MB; aggregate or sample the data first."
    known = ("mark", "layer", "concat", "hconcat", "vconcat", "facet", "repeat", "spec")
    if not any(k in spec for k in known):
        return "That doesn't look like a Vega-Lite spec (no mark, layer, concat, facet or repeat)."

    def urls(node):
        if isinstance(node, dict):
            d = node.get("data")
            if isinstance(d, dict) and "url" in d:
                return True
            return any(urls(v) for v in node.values())
        if isinstance(node, list):
            return any(urls(v) for v in node)
        return False

    if urls(spec):
        return "Put the data inline (data.values): the chart renders offline and can't load URLs."
    return None


def call(name, args):
    if name == "show_media":
        r = check_media(args)
        if isinstance(r, str):
            return r, True
        _, kind, size = r
        return ("Shown to the user in the chat: the %s %s (%d KB). They can pop it out into a window."
                % (kind, args["path"], max(1, size // 1024))), False
    if name == "show_chart":
        err = check_chart(args)
        if err:
            return err, True
        return "Shown to the user in the chat as an interactive chart. They can pop it out into a window.", False
    return "Unknown tool: %s" % name, True


def answer(msg):
    method = msg.get("method")
    if method == "initialize":
        return {"protocolVersion": PROTOCOL,
                "serverInfo": {"name": "bromure-display", "version": "1"},
                "capabilities": {"tools": {"listChanged": False}},
                "instructions": INSTRUCTIONS}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        p = msg.get("params") or {}
        text, is_error = call(p.get("name"), p.get("arguments") or {})
        out = {"content": [{"type": "text", "text": text}]}
        if is_error:
            out["isError"] = True
        return out
    raise LookupError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "id" not in msg:
            continue   # a notification (notifications/initialized, …)
        try:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": answer(msg)}
        except LookupError:
            reply = {"jsonrpc": "2.0", "id": msg["id"],
                     "error": {"code": -32601, "message": "Method not found"}}
        except Exception as e:   # never die on one bad call
            reply = {"jsonrpc": "2.0", "id": msg["id"],
                     "error": {"code": -32603, "message": str(e)}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
