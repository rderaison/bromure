#!/usr/bin/env python3
"""Write the release DMG's Finder layout without Apple Events.

Install tools/dmg-layout-requirements.txt in a venv and set
BROMURE_DMG_LAYOUT_PYTHON to that environment's Python when packaging.
"""
import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("volume", type=Path)
parser.add_argument("app_name")
args = parser.parse_args()
background = args.volume / ".background/bg.png"
app = args.app_name + ".app"
if not background.is_file() or not (args.volume / app).is_dir():
    parser.error("Mounted release image is missing its app or background")

window = {
    "WindowBounds": "{{100, 100}, {660, 400}}",
    "ShowToolbar": False,
    "ShowStatusBar": False,
    "ShowSidebar": False,
    "ShowPathbar": False,
    "ShowTabView": False,
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
}
icons = {
    "viewOptionsVersion": 1,
    "iconSize": 128.0,
    "textSize": 14.0,
    "arrangeBy": "none",
    "labelOnBottom": True,
    "showItemInfo": False,
    "showIconPreview": False,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
    "backgroundType": 2,
    "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
}
store = args.volume / ".DS_Store"
with DSStore.open(str(store), "w+") as data:
    data["."]["vSrn"] = ("long", 1)
    data["."]["bwsp"] = window
    data["."]["icvp"] = icons
    data["."]["icvl"] = ("type", b"icnv")
    data[app]["Iloc"] = (165, 200)
    data["Applications"]["Iloc"] = (495, 200)
with DSStore.open(str(store), "r") as data:
    assert data["."]["icvp"]["iconSize"] == 128.0
    assert data["."]["icvp"]["backgroundType"] == 2
    assert data[app]["Iloc"] == (165, 200)
    assert data["Applications"]["Iloc"] == (495, 200)
print("Verified release DMG layout: 128-point icons and drag arrow background")
