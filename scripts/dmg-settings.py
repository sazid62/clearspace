# dmgbuild settings for a drag-to-Applications installer window.
# Run through scripts/build.sh, which passes -D app=... -D background=...
import os.path

application = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]  # noqa: F821

window_rect = ((200, 160), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 200),
    "Applications": (495, 200),
}
