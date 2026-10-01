#!/usr/bin/env python3
"""Check publish provenance; guest setup separately gates actual library loadability."""
import json
from pathlib import Path
import re
import sys


def check(image_dir, repo):
    source = (repo / "Sources/SandboxEngine/LinuxImageManager.swift").read_text()
    version = re.search(r'public static let imageVersion = "([^"\n]+)"', source).group(1)
    stamp = (image_dir / "image-version").read_text().strip()
    info = json.loads((image_dir / "build-info.json").read_text())
    if stamp != version or info.get("version") != version:
        raise ValueError(f"image stamp/build metadata must both match browser version {version}")
    expected = json.loads((repo / "Sources/SandboxEngine/Resources/vm-setup/configs/graphics-capabilities.json").read_text())
    actual = json.loads((image_dir / "graphics-capabilities.json").read_text())
    if any(actual.get(key) != value for key, value in expected.items()):
        raise ValueError("image graphics contract does not match this build's guest setup")
    print(f"Browser image {version}: graphics/video/pointer contract PASS")


if __name__ == "__main__":
    try:
        check(Path(sys.argv[1]), Path(__file__).resolve().parent.parent)
    except (OSError, ValueError, IndexError) as error:
        sys.exit(f"Browser image contract failed: {error}")
