# Layout of the disk image, for dmgbuild (https://dmgbuild.readthedocs.io).
# Used by tools/make-dmg.sh: dmgbuild -s tools/dmg-settings.py -D app=... -D background=... "Name" out.dmg
import os

app = defines.get("app")  # noqa: F821 (dmgbuild provides `defines`)
background = defines.get("background")  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]

# The window frame: 380 points of content, plus room for the title bar.
# The icons sit on the background's arrow (tools/make-dmg-background.swift).
window_rect = ((200, 120), (660, 408))
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (165, 150),
    "Applications": (495, 150),
}
background = background or "builtin-arrow"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
