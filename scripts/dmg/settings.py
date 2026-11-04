"""Finder layout for the drag-to-install image; no Finder/AppleScript required."""
from pathlib import Path
import subprocess

application = Path(defines["app"])
files = [(str(application), "PairDesk.app")]
symlinks = {"Applications": "/Applications"}
icon = str(application / "Contents/Resources/PairDesk.icns")
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"

# Extra height leaves the footer visible when Finder forces path/status bars on.
window_rect = ((160, 160), (660, 520))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
icon_size = 112
text_size = 14
label_pos = "bottom"
icon_locations = {"PairDesk.app": (170, 220), "Applications": (490, 220)}


def create_hook(mount_point, options):
    # dmgbuild uses ditto internally; verify the copied bundle before publishing.
    subprocess.run(["codesign", "--verify", "--deep", "--strict",
                    str(Path(mount_point) / "PairDesk.app")], check=True)
