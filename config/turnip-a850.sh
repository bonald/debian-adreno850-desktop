# /etc/profile.d/turnip-a850.sh
# Auto-load bare-metal Adreno 850 Turnip (Vulkan 1.4) + Zink (OpenGL 4.6)
# inside the native Debian 13 (trixie arm64) chroot.

export VK_ICD_FILENAMES="/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json"
export MESA_LOADER_DRIVER_OVERRIDE="zink"
export GALLIUM_DRIVER="zink"

# noconform: enables Vulkan 1.4 features on Adreno 850 (a840 topology entry)
# noubwc:    prevents UBWC texture/glyph corruption on Adreno 850
export TU_DEBUG="${TU_DEBUG:-noconform,noubwc}"

# sw WSI avoids Termux:X11 DRI3 stalls on uncached KGSL DMA-BUF CPU readbacks
export MESA_VK_WSI_DEBUG="${MESA_VK_WSI_DEBUG:-sw}"

# Android kernels disable CONFIG_SYSVIPC
export QT_X11_NO_MITSHM=1

# System-wide dark mode for GTK3/GTK4/Qt apps
export GTK_THEME="${GTK_THEME:-Adwaita:dark}"
export QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-gtk3}"

export DISPLAY="${DISPLAY:-:0}"

# Termux PulseAudio TCP bridge (AAudio_sink on 127.0.0.1:4713)
export PULSE_SERVER="${PULSE_SERVER:-127.0.0.1}"
