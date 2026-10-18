# dmgbuild settings for the Isla disk image: what the person sees when the
# image opens. Read by Scripts/dmg.sh, which passes the app, the version and
# the background in through -D. Coordinates are points from the top-left of
# the window's content area; the window is the background's size, 660 x 400.
import os

app = defines["app"]
background = defines["background"]
version = defines.get("version", "")

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

# The app's own icon on the mounted volume, so the desktop and the sidebar
# show Isla rather than a grey drive.
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180

icon_size = 128
text_size = 13
arrange_by = None
# The arrow in the background points from the first slot to the second.
icon_locations = {
    os.path.basename(app): (165, 190),
    "Applications": (495, 190),
}
