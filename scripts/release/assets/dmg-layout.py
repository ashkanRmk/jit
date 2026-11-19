"""Write and inspect Finder metadata on the mounted image, independent of a GUI session."""

import json
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def layout_settings(volume):
    dimensions = json.loads(Path(__file__).with_suffix(".json").read_text(encoding="utf-8"))
    width, height = dimensions["width"], dimensions["height"]
    window = dict.fromkeys(
        (
            "ShowStatusBar", "ShowToolbar", "ShowPathbar", "ShowSidebar", "ContainerShowSidebar",
            "ShowTabView", "PreviewPaneVisibility",
        ),
        False,
    )
    window["WindowBounds"] = f"{{{{120, 140}}, {{{width}, {height}}}}}"
    window["SidebarWidth"] = 180

    background = Alias.for_file(str(volume / ".background/background.tiff"))
    icon_view = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": background.to_bytes(),
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "arrangeBy": "none",
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 52.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 13.0,
        "iconSize": float(dimensions["iconSize"]),
    }
    positions = {
        "Jit.app": (dimensions["jitX"], dimensions["iconY"]),
        "Applications": (dimensions["applicationsX"], dimensions["iconY"]),
    }
    return window, icon_view, positions


def write_layout(volume, window, icon_view, positions):
    with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = (b"long", 1)
        store["."]["icvl"] = (b"type", b"icnv")
        store["."]["bwsp"] = window
        store["."]["icvp"] = icon_view
        for name, position in positions.items():
            store[name]["Iloc"] = position


def verify_layout(volume, window, icon_view, positions):
    def require(condition, detail):
        if not condition:
            raise SystemExit(f"Invalid Finder layout: {detail}")

    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        require(store["."]["icvl"] == (b"type", b"icnv"), "the image must open in icon view")
        require(store["."]["bwsp"] == window, "window bounds or chrome differ")
        actual_view = store["."]["icvp"]
        actual_alias = Alias.from_bytes(actual_view.pop("backgroundImageAlias"))
        expected_alias = Alias.from_bytes(icon_view.pop("backgroundImageAlias"))
        require(actual_view == icon_view, "icon view settings differ")
        require(
            actual_alias.volume.name == expected_alias.volume.name
            and actual_alias.target.cnid == expected_alias.target.cnid
            and actual_alias.target.posix_path == expected_alias.target.posix_path,
            "the background alias does not point to this volume's background",
        )
        for name, position in positions.items():
            require(store[name]["Iloc"] == position, f"wrong position for {name}")
    require((volume / "Applications").readlink() == Path("/Applications"), "wrong Applications link target")
    print("Icon view, window, background alias, icon positions and Applications link verified")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in {"write", "verify"}:
        raise SystemExit("usage: dmg-layout.py write|verify MOUNT_POINT")
    mount = Path(sys.argv[2]).resolve(strict=True)
    command = write_layout if sys.argv[1] == "write" else verify_layout
    command(mount, *layout_settings(mount))
