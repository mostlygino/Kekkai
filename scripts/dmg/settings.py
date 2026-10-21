# dmgbuild settings for Kekkai (scripts/make-dmg.sh passes the -D values).
# Coordinates match scripts/make-art.swift: a 640 x 400 window,
# Kekkai centred at (170, 210), Applications at (470, 210), each in its own raked rings.
import os.path

app = defines["app"]
appname = os.path.basename(app)

format = "ULMO"            # LZMA: small, and opens on every supported macOS
filesystem = "HFS+"
size = None                 # sized to fit

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]  # Finder shows "Kekkai"

icon = defines["icon"]              # volume icon (.icns)
background = defines["background"]  # TIFF with the 1x and 2x images

window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 210), "Applications": (470, 210)}
