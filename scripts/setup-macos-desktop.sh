#!/bin/bash
# Configure a macOS-inspired dark desktop on XFCE4 + Plank inside the Debian 13 chroot:
# - Slim translucent dark top bar: Debian Whisker Menu + Window Menu on left;
#   GPU/CPU/RAM telemetry + systray + Date/Time on right
# - Centered frosted rounded floating macOS Dock at bottom (Plank) with 145% hover zoom,
#   running-app indicator dots, pinned apps + 9-dot App Grid button
# - Custom xfwm4 "MacOS-Dark" theme with 4x supersampled red/yellow/green traffic lights on top-left
# - Generated dusk-horizon dark wallpaper, Adwaita-dark + Papirus-Dark + Cantarell + JetBrains Mono
#
# Environment overrides:
#   DESKTOP_USER=droid          Target Linux username (default: droid)
#   GPU_LABEL="Adreno 850"      Label displayed in the top bar telemetry badge

set -euo pipefail

DESKTOP_USER="${DESKTOP_USER:-droid}"
GPU_LABEL="${GPU_LABEL:-Adreno 850}"
H="/home/${DESKTOP_USER}"
USER_UID="$(id -u "$DESKTOP_USER")"
USER_GID="$(id -g "$DESKTOP_USER")"

CFG="$H/.config/xfce4/xfconf/xfce-perchannel-xml"
PNL="$H/.config/xfce4/panel"
TERM_CFG="$H/.config/xfce4/terminal"
GTK3="$H/.config/gtk-3.0"
BG_DIR="$H/.local/share/backgrounds"
XFWM_THEME="$H/.local/share/themes/MacOS-Dark/xfwm4"
PLANK_THEME="$H/.local/share/plank/themes/MacOS-Dark"
PLANK_LAUNCHERS="$H/.config/plank/dock1/launchers"
APPS_DIR="$H/.local/share/applications"

mkdir -p "$CFG" "$PNL" "$TERM_CFG" "$GTK3" "$BG_DIR" "$XFWM_THEME" "$PLANK_THEME" "$PLANK_LAUNCHERS" "$APPS_DIR" "$H/.local/bin" "$H/.config/autostart"

# 1. Generate dusk wallpaper + crisp 4x supersampled macOS traffic-light xfwm4 theme via Pillow
BG_PATH="$BG_DIR/macos-dark.png" XFWM_DIR="$XFWM_THEME" python3 - << 'PYEOF'
from PIL import Image, ImageDraw, ImageFilter
import math, os

bg_path = os.environ["BG_PATH"]
tdir = os.environ["XFWM_DIR"]

# --- A. Moody dark dusk/horizon wallpaper ---
W, H = 1920, 1200
img = Image.new("RGB", (W, H), (14, 18, 28))
px = img.load()
for y in range(H):
    ny = y / H
    for x in range(W):
        nx = x / W
        horizon = math.exp(-((ny - 0.62) / 0.14) ** 2)
        side = math.exp(-((nx - 0.22) / 0.35) ** 2)
        r = int(min(255, 14 + 34 * horizon + 55 * horizon * side + 8 * (1 - ny)))
        g = int(min(255, 19 + 28 * horizon + 26 * horizon * side + 12 * (1 - ny)))
        b = int(min(255, 32 + 46 * (1 - abs(ny - 0.38)) + 16 * horizon))
        px[x, y] = (r, g, b)

ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(ov)
d.polygon(
    [(0, int(H * 0.66)), (int(W * 0.30), int(H * 0.56)), (int(W * 0.68), int(H * 0.63)),
     (W, int(H * 0.58)), (W, H), (0, H)],
    fill=(12, 16, 26, 200),
)
d.ellipse((int(W * 0.05), int(H * 0.44), int(W * 0.48), int(H * 0.76)), fill=(224, 130, 72, 34))
ov = ov.filter(ImageFilter.GaussianBlur(radius=22))
img = Image.alpha_composite(img.convert("RGBA"), ov).convert("RGB")
img.save(bg_path, "PNG")

# --- B. MacOS-Dark xfwm4 theme with traffic-light buttons on top-left ---
BG_ACT = (32, 34, 42)
BG_INACT = (24, 26, 32)
BORDER = (52, 56, 68)
TITLE_H = 30

def save_solid(name, w, h, color, border_top=None):
    im = Image.new("RGB", (w, h), color)
    if border_top:
        dr = ImageDraw.Draw(im)
        dr.line([(0, 0), (w - 1, 0)], fill=border_top)
    im.save(os.path.join(tdir, name))

for i in range(1, 6):
    save_solid(f"title-{i}-active.png", 8, TITLE_H, BG_ACT, BORDER)
    save_solid(f"title-{i}-inactive.png", 8, TITLE_H, BG_INACT, BORDER)

save_solid("top-left-active.png", 8, TITLE_H, BG_ACT, BORDER)
save_solid("top-left-inactive.png", 8, TITLE_H, BG_INACT, BORDER)
save_solid("top-right-active.png", 8, TITLE_H, BG_ACT, BORDER)
save_solid("top-right-inactive.png", 8, TITLE_H, BG_INACT, BORDER)
save_solid("left-active.png", 2, 16, BORDER)
save_solid("left-inactive.png", 2, 16, BG_INACT)
save_solid("right-active.png", 2, 16, BORDER)
save_solid("right-inactive.png", 2, 16, BG_INACT)
save_solid("bottom-active.png", 16, 2, BORDER)
save_solid("bottom-inactive.png", 16, 2, BG_INACT)
save_solid("bottom-left-active.png", 4, 4, BORDER)
save_solid("bottom-left-inactive.png", 4, 4, BG_INACT)
save_solid("bottom-right-active.png", 4, 4, BORDER)
save_solid("bottom-right-inactive.png", 4, 4, BG_INACT)

def make_btn(prefix, active_col, hover_col):
    S = 4  # 4x supersample for crisp anti-aliased circles
    W_B, H_B = 22, TITLE_H
    for state, bg, col in [
        ("active", BG_ACT, active_col),
        ("prelight", BG_ACT, hover_col),
        ("pressed", BG_ACT, hover_col),
        ("inactive", BG_INACT, (72, 76, 88)),
    ]:
        im = Image.new("RGB", (W_B * S, H_B * S), bg)
        dr = ImageDraw.Draw(im)
        dr.line([(0, 0), (W_B * S - 1, 0)], fill=BORDER, width=S)
        cx, cy, r = (W_B * S) // 2, (H_B * S) // 2, 6 * S
        dr.ellipse((cx - r, cy - r, cx + r, cy + r), fill=col)
        im = im.resize((W_B, H_B), Image.Resampling.LANCZOS)
        im.save(os.path.join(tdir, f"{prefix}-{state}.png"))

make_btn("close", (255, 95, 86), (255, 125, 118))
make_btn("hide", (255, 189, 46), (255, 210, 96))
make_btn("maximize", (39, 201, 63), (84, 224, 104))
make_btn("maximize-toggled", (39, 201, 63), (84, 224, 104))
make_btn("menu", BG_ACT, (80, 86, 104))

with open(os.path.join(tdir, "themerc"), "w") as f:
    f.write("""active_text_color=#e6e9f2
inactive_text_color=#7c8294
active_text_shadow_color=#000000
button_offset=6
button_spacing=2
full_width_title=true
maximized_offset=0
shadow_delta_height=4
shadow_delta_width=0
shadow_delta_x=0
shadow_delta_y=-3
shadow_opacity=55
show_app_icon=false
title_alignment=center
title_horizontal_offset=0
title_shadow_active=false
title_shadow_inactive=false
title_vertical_offset=0
""")
PYEOF

# 2. Custom 9-dot App Grid desktop entry for the right end of the dock
cat << 'EOF' > "$APPS_DIR/app-grid.desktop"
[Desktop Entry]
Type=Application
Name=Applications
Comment=Show all applications
Icon=view-app-grid-symbolic
Exec=xfce4-popup-whiskermenu
Categories=Utility;
EOF

# 3. Plank MacOS-Dark translucent rounded glass dock theme
cat << 'EOF' > "$PLANK_THEME/dock.theme"
[PlankTheme]
TopRoundness=14
BottomRoundness=14
LineWidth=1
OuterStrokeColor=255;;255;;255;;45
FillStartColor=22;;24;;32;;215
FillEndColor=18;;20;;28;;225
InnerStrokeColor=255;;255;;255;;18

[PlankDockTheme]
HorizPadding=6
TopPadding=4
BottomPadding=4
ItemPadding=6
IndicatorSize=4
IconShadowSize=2
UrgentBounceHeight=1.4
LaunchBounceHeight=0.5
FadeOpacity=1
ClickTime=250
UrgentBounceTime=500
LaunchBounceTime=500
ActiveTime=250
SlideTime=250
FadeTime=200
HideTime=250
GlowSize=24
GlowTime=8000
GlowPulseTime=2000
GlowOpacity=0.8
CascadeHide=true
BadgeColor=255;;95;;86;;255
EOF

# 4. Plank dock pinned launchers
rm -f "$PLANK_LAUNCHERS"/*.dockitem
cat << 'EOF' > "$PLANK_LAUNCHERS/01-files.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/thunar.desktop
EOF
cat << 'EOF' > "$PLANK_LAUNCHERS/02-terminal.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/xfce4-terminal.desktop
EOF
cat << 'EOF' > "$PLANK_LAUNCHERS/03-kitty.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/kitty.desktop
EOF
cat << 'EOF' > "$PLANK_LAUNCHERS/04-editor.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/org.xfce.mousepad.desktop
EOF
cat << 'EOF' > "$PLANK_LAUNCHERS/05-monitor.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/xfce4-taskmanager.desktop
EOF
cat << 'EOF' > "$PLANK_LAUNCHERS/06-settings.dockitem"
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/xfce-settings-manager.desktop
EOF
cat << EOF > "$PLANK_LAUNCHERS/07-apps.dockitem"
[PlankDockItemPreferences]
Launcher=file://${APPS_DIR}/app-grid.desktop
EOF

# 5. Top bar telemetry script (GPU badge + CPU % + RAM %)
cat << EOF > "$H/.local/bin/topbar-stats.sh"
#!/bin/bash
RAM=\$(awk '/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{printf "%.0f%%", (t-a)*100/t}' /proc/meminfo)
CPU=\$(awk '{u=\$2+\$4; t=\$2+\$4+\$5} NR==1{u1=u;t1=t} END{if(t-t1>0) printf "%.0f%%", (u-u1)*100/(t-t1); else print "1%"}' <(head -n1 /proc/stat) <(sleep 0.15; head -n1 /proc/stat))
printf "<txt>  ${GPU_LABEL}   CPU %s   RAM %s  </txt>" "\$CPU" "\$RAM"
EOF
chmod 755 "$H/.local/bin/topbar-stats.sh"

# 6. GTK3 + Top Bar CSS
cat << 'EOF' > "$GTK3/settings.ini"
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Cantarell 10.5
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-size=24
EOF

cat << 'EOF' > "$GTK3/gtk.css"
#XfcePanelWindow.xfce4-panel {
    background-color: rgba(16, 18, 24, 0.88);
    color: #eceff4;
    font-family: "Cantarell", sans-serif;
    font-size: 13px;
    font-weight: 600;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

#whiskermenu-button {
    padding: 0 10px;
}
#whiskermenu-button:hover {
    background-color: rgba(255, 255, 255, 0.12);
    border-radius: 6px;
}
EOF

# 7. xsettings + xfwm4 (traffic lights on LEFT: CMH|) + wallpaper
cat << 'EOF' > "$CFG/xsettings.xml"
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Cantarell 10.5"/>
    <property name="MonospaceFontName" type="string" value="JetBrains Mono 11"/>
    <property name="CursorThemeSize" type="int" value="24"/>
    <property name="DecorationLayout" type="string" value="close,minimize,maximize:menu"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
  </property>
</channel>
EOF

cat << 'EOF' > "$CFG/xfwm4.xml"
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="MacOS-Dark"/>
    <property name="title_font" type="string" value="Cantarell Bold 10"/>
    <property name="button_layout" type="string" value="CMH|"/>
    <property name="use_compositing" type="bool" value="true"/>
    <property name="vblank_mode" type="string" value="off"/>
    <property name="show_frame_shadow" type="bool" value="true"/>
    <property name="show_popup_shadow" type="bool" value="true"/>
    <property name="show_dock_shadow" type="bool" value="false"/>
    <property name="workspace_count" type="int" value="4"/>
    <property name="placement_mode" type="string" value="center"/>
    <property name="snap_to_border" type="bool" value="true"/>
    <property name="tile_on_move" type="bool" value="true"/>
  </property>
</channel>
EOF

cat << EOF > "$CFG/xfce4-desktop.xml"
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="${BG_DIR}/macos-dark.png"/>
        </property>
      </property>
      <property name="monitorbuiltin" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="${BG_DIR}/macos-dark.png"/>
        </property>
      </property>
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="${BG_DIR}/macos-dark.png"/>
        </property>
      </property>
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="0"/>
  </property>
</channel>
EOF

# 8. Slim macOS-style Top Bar (Panel 1 ONLY — Plank handles the floating bottom dock)
cat << 'EOF' > "$PNL/whiskermenu-1.rc"
favorites=thunar.desktop,xfce4-terminal.desktop,kitty.desktop,org.xfce.mousepad.desktop,xfce4-taskmanager.desktop,xfce-settings-manager.desktop
button-title=
button-icon=distributor-logo-debian
show-button-title=false
show-button-icon=true
launcher-show-name=true
launcher-show-description=false
launcher-icon-size=3
category-icon-size=1
view-mode=1
menu-width=640
menu-height=500
menu-opacity=95
position-search-alternate=true
position-categories-alternate=true
EOF

cat << EOF > "$PNL/genmon-4.rc"
Command=${H}/.local/bin/topbar-stats.sh
UseLabel=0
Text=
UpdatePeriod=3000
Font=Cantarell 10
EOF

cat << 'EOF' > "$CFG/xfce4-panel.xml"
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="double" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="icon-size" type="uint" value="16"/>
      <property name="size" type="uint" value="28"/>
      <property name="background-style" type="uint" value="1"/>
      <property name="background-rgba" type="array">
        <value type="double" value="0.06"/>
        <value type="double" value="0.07"/>
        <value type="double" value="0.09"/>
        <value type="double" value="0.88"/>
      </property>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="windowmenu">
      <property name="style" type="uint" value="0"/>
      <property name="workspace-actions" type="bool" value="false"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="genmon"/>
    <property name="plugin-5" type="string" value="systray">
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="  %a %b %d %H:%M  "/>
      <property name="digital-time-font" type="string" value="Cantarell Bold 10"/>
    </property>
  </property>
</channel>
EOF

# 9. Clean dark terminal config
cat << 'EOF' > "$TERM_CFG/terminalrc"
[Configuration]
FontName=JetBrains Mono 11
MiscMenubarDefault=FALSE
MiscDefaultGeometry=96x28
ColorForeground=#eeeeec
ColorBackground=#1a1b24
ColorCursor=#7aa2f7
ColorPalette=#1a1b24;#ff5f56;#27c93f;#ffbd2e;#3584e4;#bb9af7;#7dcfff;#deddda;#5e5c64;#ff7b72;#57e389;#ffd260;#62a0ea;#dc8add;#9ce5ff;#ffffff
ScrollingLines=10000
EOF

# 10. Autostart Plank dock inside XFCE4
cat << 'EOF' > "$H/.config/autostart/plank.desktop"
[Desktop Entry]
Type=Application
Name=Plank Dock
Exec=plank
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF

# 11. Keyboard shortcuts (Alt/Super+Space -> App Menu, Alt/Super+Return -> Terminal)
cat << 'EOF' > "$CFG/xfce4-keyboard-shortcuts.xml"
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="custom" type="empty">
      <property name="override" type="bool" value="true"/>
      <property name="&lt;Alt&gt;space" type="string" value="xfce4-popup-whiskermenu"/>
      <property name="&lt;Super&gt;space" type="string" value="xfce4-popup-whiskermenu"/>
      <property name="&lt;Alt&gt;Return" type="string" value="xfce4-terminal"/>
      <property name="&lt;Super&gt;Return" type="string" value="xfce4-terminal"/>
      <property name="&lt;Alt&gt;F2" type="string" value="rofi -show drun"/>
    </property>
  </property>
</channel>
EOF

chown -R "${USER_UID}:${USER_GID}" "$H/.config" "$H/.local"

# 12. Apply Plank dconf settings (MacOS-Dark theme, 44px icons, 145% hover zoom, bottom-center)
apply_plank_gsettings() {
    dbus-run-session -- bash -c '
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ theme "MacOS-Dark"
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ icon-size 44
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ zoom-enabled true
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ zoom-percent 145
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ position "bottom"
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ alignment "center"
        gsettings set net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/ hide-mode "none"
    ' 2>/dev/null || true
}

if [ "$(id -u)" -eq 0 ]; then
    su - "$DESKTOP_USER" -c "$(declare -f apply_plank_gsettings); apply_plank_gsettings"
else
    apply_plank_gsettings
fi

echo "macOS-style XFCE4 + Plank desktop configured for user '${DESKTOP_USER}'."
