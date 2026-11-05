# dmgbuild settings for the release DMG's Finder window (docs/DESIGN.md
# section 11, "Release pipeline"). scripts/release.sh runs it as
#
#   Vendor/dmgbuild/bin/python3 -I -m dmgbuild -s scripts/dmg/settings.py \
#       -D app=<Armadale.app> -D icon=<volume icon .icns> Armadale <out.dmg>
#
# dmgbuild executes this file as Python with `defines` holding the -D values
# (see https://dmgbuild.readthedocs.io/en/latest/settings.html). The window
# is 600 x 400 points; positions are Finder's: the centre of each icon, in
# points from the top-left of the window's content area. The background
# (background.tiff next to this file, 1x and 2x in one TIFF) is drawn by
# scripts/render-dmg-background.swift to the same coordinates: keep the two
# in step.

import inspect
import os.path

_here = os.path.dirname(os.path.abspath(inspect.currentframe().f_code.co_filename))


def _required(name):
    value = defines.get(name)  # noqa: F821  (provided by dmgbuild)
    if not value:
        raise ValueError(f"scripts/dmg/settings.py needs -D {name}=<path>")
    if not os.path.exists(value):
        raise ValueError(f"-D {name}={value}: no such file")
    return value


application = _required("app")
appname = os.path.basename(application.rstrip("/"))

# .. Image ......................................................................

volume_name = "Armadale"
format = "UDZO"
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}

# The volume icon: the plain app icon (release.sh builds the .icns from the
# asset catalog's AppIcon rasters with iconutil). dmgbuild copies it to
# .VolumeIcon.icns and sets the volume's custom-icon flag.
icon = _required("icon")

# .. Window ...................................................................

background = os.path.join(_here, "background.tiff")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# ((x, y), (w, h)); dmgbuild documents y as running bottom to top, and the
# Finder moves a window that would be off screen back onto it.
window_rect = ((200, 250), (600, 400))

default_view = "icon-view"
show_icon_preview = False

# .. Icon view ................................................................

arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128

# The hidden files dmgbuild adds are placed far outside the window, so
# Finder's "show all files" (⇧⌘.) does not put them over the design.
icon_locations = {
    appname: (150, 200),
    "Applications": (450, 200),
    ".background.tiff": (900, 900),
    ".VolumeIcon.icns": (900, 900),
    ".DS_Store": (900, 900),
}
