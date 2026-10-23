"""Headless Finder layout; https://dmgbuild.readthedocs.io/en/latest/settings.html."""
from pathlib import Path

app = Path(defines["app"])
resources = Path(defines["resources"])
files = [(str(app), "Yeelight Station.app"), (defines["license"], "License.txt")]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
icon = str(app / "Contents/Resources/Station.icns")
background = str(resources / "background.png")
# Finder may retain the user's path/status bars despite the per-volume flags.
# Leave enough frame height for the full 400-point artwork with that chrome.
window_rect = ((180, 180), (600, 500))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
icon_size = 80
text_size = 13
label_pos = "bottom"
icon_locations = {
    "Yeelight Station.app": (150, 180),
    "Applications": (450, 180),
    "License.txt": (520, 320),
}
# Do not apply FinderInfo flags to the signed app: codesign --strict rejects them.
# Finder normally hides .app extensions without modifying the bundle.
