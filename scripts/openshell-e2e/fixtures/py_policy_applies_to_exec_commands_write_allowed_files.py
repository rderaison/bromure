def write_allowed_files() -> str:
    from pathlib import Path

    Path("/sandbox/allowed.txt").write_text("ok")
    Path("/tmp/allowed.txt").write_text("ok")
    return "ok"
