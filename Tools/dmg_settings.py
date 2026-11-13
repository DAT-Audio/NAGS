# dmgbuild settings for the disk image. Used by `./build.sh release dmg`, which
# passes the paths with -D. Icon positions are icon centres, top-left origin, and must agree
# with the name bands drawn by Tools/make_dmg_background.swift. Spaced for names
# shown with their extensions (a Finder setting each person may have on).
#
# dmgbuild (MIT, Alastair Houghton) writes Finder's layout file itself, so no Finder scripting
# and no screen are needed; it is a build tool only and nothing of it ships.
import os.path

build = defines["build"]            # noqa: F821  (dmgbuild provides `defines`)
staging = defines["staging"]        # noqa: F821

format = "UDZO"
filesystem = "HFS+"
size = None

files = [
    os.path.join(staging, "Network Audio Grabber.app"),
    os.path.join(staging, "Network Audio Sender.app"),
    os.path.join(staging, "DAT Audio Plug-ins.component"),
    os.path.join(staging, "Read Me.html"),
]
symlinks = {
    "Applications": "/Applications",
    "Components": "/Library/Audio/Plug-Ins/Components",
}
# Only the Read Me: hiding a bundle's extension writes Finder information onto the bundle, which
# strict signature checks reject as "detritus" (and Gatekeeper may call the app damaged). Finder
# hides ".app" by itself; the plug-ins keep ".component".
hide_extensions = ["Read Me.html"]

icon = os.path.join(staging, "volume.icns")
background = os.path.join(staging, "background.tiff")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Finder's window bounds include its title bar; the background is 720 × 470.
window_rect = ((200, 120), (720, 498))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100     # Finder rejects the whole view (background, icon size) above its own maximum of 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 12
icon_size = 64

icon_locations = {
    "Network Audio Grabber.app": (130, 168),
    "Network Audio Sender.app": (320, 168),
    "Applications": (560, 168),
    "DAT Audio Plug-ins.component": (130, 304),
    "Components": (310, 304),
    "Read Me.html": (620, 40),
}
