#!/system/bin/sh
# Native Debian 13 (trixie arm64) chroot with bare-metal Adreno 850 GPU
# (glibc Mesa 27.0 Turnip Vulkan 1.4 + Zink OpenGL 4.6), macOS-style XFCE4 + Plank,
# Termux:X11 local display (:0), Termux PulseAudio (AAudio), persistent perf tweaks,
# and TigerVNC (x0vncserver) + noVNC remote access restricted to Tailscale + localhost.
#
# Usage:
#   su -c "/data/adb/debian-gpu.sh start"            - Apply perf, mount, X11, audio, desktop & VNC
#   su -c "/data/adb/debian-gpu.sh stop"             - Stop desktop, VNC & noVNC
#   su -c "/data/adb/debian-gpu.sh macos-start"      - Switch to macOS 27.2 VM (Gunyah + xnu_fb_view on :0)
#   su -c "/data/adb/debian-gpu.sh macos-stop"       - Stop macOS 27.2 VM, viewer & host bridges
#   su -c "/data/adb/debian-gpu.sh macos-services"   - Start/refresh macOS Audio, WebDAV/Clipboard & Tailscale SSH/VNC
#   su -c "/data/adb/debian-gpu.sh macos-log"        - Show recent macOS VM & XNU dmesg logs
#   su -c "/data/adb/debian-gpu.sh profile docked|battery" - Switch 1-tap performance profile
#   su -c "/data/adb/debian-gpu.sh set-macos-opt K V" - Persist MACOS_RES or MACOS_RAM_MB preset
#   su -c "/data/adb/debian-gpu.sh umount"           - Stop services/VM and unmount chroot image
#   su -c "/data/adb/debian-gpu.sh shell"            - Interactive bash shell as droid
#   su -c "/data/adb/debian-gpu.sh status"           - Show running services & remote URLs
#   su -c "/data/adb/debian-gpu.sh perf"             - Apply all enabled perf tweaks from config
#   su -c "/data/adb/debian-gpu.sh set-toggle K V"   - Persist & live-apply one toggle (0/1)
#   su -c "/data/adb/debian-gpu.sh reset-perf"       - Restore stock defaults for all toggles
#   su -c "/data/adb/debian-gpu.sh audio-fix"        - Start/repair Termux PulseAudio AAudio_sink
#   su -c "/data/adb/debian-gpu.sh telemetry"        - Machine-readable live status for Debian GPU APK
#   su -c "/data/adb/debian-gpu.sh debloat"          - Disable 55 safe Honor/YOYO/China bloat packages (user-space)
#   su -c "/data/adb/debian-gpu.sh restore-bloat"    - Restore all Honor packages disabled by debloat
#   su -c "/data/adb/debian-gpu.sh free-ram"         - Evict cached background apps & drop page cache
#   su -c "/data/adb/debian-gpu.sh kernel-profile"   - Run 3s zero-risk tracefs/kprobe kernel profiler
#   su -c "/data/adb/debian-gpu.sh vnc"              - Restart VNC + noVNC proxy
#   su -c "/data/adb/debian-gpu.sh passwd"           - Change VNC password

set -eu

IMG=/data/adb/debian-gpu.img
MNT=/data/local/debian-gpu
CONF=/data/adb/debian-gpu.conf
BOOT_SCRIPT=/data/adb/service.d/99-debian-gpu-perf.sh
MACOS_SCRIPT=/data/adb/run-xnulinux-vm.sh
MACOS_DIR=/data/local/xnu-mac
MACOS_LOG=/data/local/tmp/vm_macos_live.log
MACOS_VIEW_LOG=/tmp/xnu_fb_view.log
TUID=10459
TPREFIX=/data/data/com.termux/files/usr
THOME=/data/data/com.termux/files/home
X11_DIR="$TPREFIX/tmp/.X11-unix"

write_default_conf() {
    cat > "$CONF" <<'EOF'
# Persistent Debian GPU performance & desktop toggles (0=off, 1=on)
PERF_HONOR_MODE=1
PERF_GPU_UNLOCK=1
PERF_GPU_RAMP=1
PERF_GPU_MAX_WAKE=0
PERF_CPU_UNLOCK=1
PERF_THERMAL_DOCKED=1
PERF_WALT_BURST=1
PERF_WALT_PRIME_BIAS=1
PERF_VM_IO=1
PERF_MEM_OPT=1
PERF_THP_OPT=1
PERF_JEMALLOC=1
PERF_SHMEM_COMPAT=1
PERF_KERNEL_BOOST=0
PERF_XFCE_OPT=1
PERF_CHROMIUM_VULKAN=1
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=1
MACOS_RES=1920x1080
MACOS_RAM_MB=4400
EOF
    chmod 644 "$CONF"
}

load_conf() {
    [ -f "$CONF" ] || write_default_conf
    PERF_HONOR_MODE=1
    PERF_GPU_UNLOCK=1
    PERF_GPU_RAMP=1
    PERF_GPU_MAX_WAKE=0
    PERF_CPU_UNLOCK=1
    PERF_THERMAL_DOCKED=1
    PERF_WALT_BURST=1
    PERF_WALT_PRIME_BIAS=1
    PERF_VM_IO=1
    PERF_MEM_OPT=1
    PERF_THP_OPT=1
    PERF_JEMALLOC=1
    PERF_SHMEM_COMPAT=1
    PERF_KERNEL_BOOST=0
    PERF_XFCE_OPT=1
    PERF_CHROMIUM_VULKAN=1
    PERF_PULSEAUDIO=1
    PERF_BOOT_PERSIST=1
    MACOS_RES=1920x1080
    MACOS_RAM_MB=4400
    # shellcheck disable=SC1090
    . "$CONF" 2>/dev/null || true
}

get_tailscale_ip() {
    ip -4 addr show dev tun1 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}' \
    || ip -4 addr show 2>/dev/null | awk '/inet 100\./ {split($2,a,"/"); print a[1]; exit}'
}

get_loop_dev() {
    mount | awk -v m="$MNT" '$3 == m {print $1; exit}' | sed 's|/dev/block/||;s|/dev/||'
}

# Lock a sysfs control node to a desired value by writing to the real kernel node first,
# then bind-mounting a writable sink file (preserving SELinux context) so vendor daemons
# (iawareperf / perf2-hal / dubaid) succeed silently without re-clamping clocks or spinning.
# Hardware CPUCP/LMh (scmi_limit_notify_cb) and TSENS (105-125C) stay 100% active underneath.
GUARD_DIR=/data/local/tmp/.debian_gpu_guard

is_mounted_path() {
    local real
    real=$(readlink -f "$1" 2>/dev/null || echo "$1")
    grep -Fq " $real " /proc/self/mountinfo 2>/dev/null
}

save_orig_node() {
    local target="$1" name="$2"
    local orig="$GUARD_DIR/orig_$name"
    [ -e "$target" ] || return 0
    [ -f "$orig" ] && return 0
    is_mounted_path "$target" && return 0
    mkdir -p "$GUARD_DIR"
    cat "$target" > "$orig" 2>/dev/null || true
}

get_orig_node() {
    local name="$1" fallback="${2:-}"
    local orig="$GUARD_DIR/orig_$name"
    if [ -s "$orig" ]; then
        cat "$orig" 2>/dev/null || echo "$fallback"
    else
        echo "$fallback"
    fi
}

guard_sysfs_node() {
    local target="$1" val="$2" name="$3"
    local real sink
    [ -e "$target" ] || return 0
    real=$(readlink -f "$target" 2>/dev/null || echo "$target")
    sink="$GUARD_DIR/$name"
    while is_mounted_path "$real"; do
        umount "$real" 2>/dev/null || break
    done
    chmod 644 "$real" 2>/dev/null || true
    (echo "$val" > "$real") 2>/dev/null || true
    mkdir -p "$GUARD_DIR"
    printf "%s\n" "$val" > "$sink"
    chmod 666 "$sink"
    chcon --reference="$real" "$sink" 2>/dev/null || true
    mount --bind "$sink" "$real" 2>/dev/null || true
}

unguard_sysfs_node() {
    local target="$1" val="${2:-}"
    local real
    [ -e "$target" ] || return 0
    real=$(readlink -f "$target" 2>/dev/null || echo "$target")
    while is_mounted_path "$real"; do
        umount "$real" 2>/dev/null || break
    done
    if [ -n "$val" ]; then
        chmod 644 "$real" 2>/dev/null || true
        (echo "$val" > "$real") 2>/dev/null || true
    fi
}

sync_boot_script() {
    if [ "${PERF_BOOT_PERSIST:-1}" = "1" ]; then
        mkdir -p /data/adb/service.d
        cat > "$BOOT_SCRIPT" <<'EOF'
#!/system/bin/sh
# Auto-apply persistent Debian GPU performance tweaks after Android boot
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 60 ]; do
    sleep 2
    i=$((i + 1))
done
sleep 5
[ -x /data/adb/debian-gpu.sh ] && /data/adb/debian-gpu.sh boot-apply >/dev/null 2>&1 || true
EOF
        chmod 755 "$BOOT_SCRIPT"
    else
        rm -f "$BOOT_SCRIPT" 2>/dev/null || true
    fi
}

do_mount() {
    mkdir -p "$MNT" "$X11_DIR"
    if ! mountpoint -q "$MNT"; then
        LOOP=$(losetup -f)
        losetup "$LOOP" "$IMG"
        mount -t ext4 -o rw,suid,dev,exec,noatime "$LOOP" "$MNT"
    fi
    mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/tmp/.X11-unix" "$MNT/mnt/android"
    mountpoint -q "$MNT/proc" || mount -t proc proc "$MNT/proc"
    mountpoint -q "$MNT/sys" || mount -t sysfs sysfs "$MNT/sys"
    mountpoint -q "$MNT/dev" || mount --bind /dev "$MNT/dev"
    mkdir -p "$MNT/dev/pts" "$MNT/dev/shm"
    mountpoint -q "$MNT/dev/pts" || mount --bind /dev/pts "$MNT/dev/pts"
    mountpoint -q "$MNT/dev/shm" || mount -t tmpfs -o rw,nosuid,nodev,mode=1777 tmpfs "$MNT/dev/shm"
    mountpoint -q "$MNT/tmp/.X11-unix" || mount --bind "$X11_DIR" "$MNT/tmp/.X11-unix"
    if ! mountpoint -q "$MNT/mnt/android"; then
        if [ -d /data/media/0 ]; then
            mount --bind /data/media/0 "$MNT/mnt/android"
        else
            mount --bind /storage/emulated/0 "$MNT/mnt/android"
        fi
    fi
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$MNT/etc/resolv.conf"
    # Apply loop read-ahead right after mount if VM/IO tuning enabled
    load_conf
    if [ "$PERF_VM_IO" = "1" ]; then
        LDEV=$(get_loop_dev || true)
        [ -n "$LDEV" ] && [ -w "/sys/block/$LDEV/queue/read_ahead_kb" ] && echo 512 > "/sys/block/$LDEV/queue/read_ahead_kb" 2>/dev/null || true
    fi
}

run_in_chroot() {
    chroot "$MNT" /usr/bin/env -i \
        HOME=/root \
        TERM=xterm-256color \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash -c "$1"
}

apply_chromium_flags() {
    load_conf
    mountpoint -q "$MNT" || return 0
    FLAG_FILE="$MNT/etc/profile.d/chromium-gpu-flags.sh"
    if [ "$PERF_CHROMIUM_VULKAN" = "1" ]; then
        cat > "$FLAG_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_CHROMIUM_VULKAN=1)
# Native Skia GaneshVulkan + ANGLE Vulkan directly on Adreno 850 Turnip (Mesa 27.0)
export CHROMIUM_GPU_FLAGS="--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy --enable-features=Vulkan --use-gl=angle --use-angle=vulkan"
EOF
    else
        cat > "$FLAG_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_CHROMIUM_VULKAN=0)
# Zink OpenGL 4.6 fallback
export CHROMIUM_GPU_FLAGS="--ignore-gpu-blocklist --enable-gpu-rasterization"
EOF
    fi
    chmod 644 "$FLAG_FILE"
}

apply_allocator_opt() {
    load_conf
    mountpoint -q "$MNT" || return 0
    ALLOC_FILE="$MNT/etc/profile.d/allocator-opt.sh"
    if [ "$PERF_JEMALLOC" = "1" ]; then
        cat > "$ALLOC_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_JEMALLOC=1)
# Tuned jemalloc 5.3 (~3.7x faster multi-thread alloc vs glibc ptmalloc2).
# Chromium/Electron wrappers explicitly reset LD_PRELOAD so PartitionAlloc stays untouched.
if [ -r /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ]; then
    export MALLOC_CONF="${MALLOC_CONF:-background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000,metadata_thp:auto}"
    case ":${LD_PRELOAD:-}:" in
        *:/usr/lib/aarch64-linux-gnu/libjemalloc.so.2:*) ;;
        *) export LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libjemalloc.so.2${LD_PRELOAD:+:$LD_PRELOAD}" ;;
    esac
fi
EOF
    else
        cat > "$ALLOC_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_JEMALLOC=0 - stock glibc ptmalloc2)
EOF
    fi
    chmod 644 "$ALLOC_FILE"
}

apply_shmem_compat() {
    load_conf
    mountpoint -q "$MNT" || return 0
    SHMEM_FILE="$MNT/etc/profile.d/shmem-compat.sh"
    if [ "$PERF_SHMEM_COMPAT" = "1" ] && [ -r "$MNT/usr/lib/aarch64-linux-gnu/libandroid-shmem.so" ]; then
        cat > "$SHMEM_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_SHMEM_COMPAT=1)
# Wire-compatible /dev/ashmem + abstract-socket SysV SHM / X11 MIT-SHM shim for Android GKI
if [ -r /usr/lib/aarch64-linux-gnu/libandroid-shmem.so ]; then
    unset QT_X11_NO_MITSHM
    case ":${LD_PRELOAD:-}:" in
        *:/usr/lib/aarch64-linux-gnu/libandroid-shmem.so:*) ;;
        *) export LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libandroid-shmem.so${LD_PRELOAD:+:$LD_PRELOAD}" ;;
    esac
fi
EOF
    else
        cat > "$SHMEM_FILE" <<'EOF'
# Managed by /data/adb/debian-gpu.sh (PERF_SHMEM_COMPAT=0)
export QT_X11_NO_MITSHM=1
EOF
    fi
    chmod 644 "$SHMEM_FILE"
    # Ensure turnip-a850.sh sources shmem-compat.sh so login shells & desktop apps inherit it
    TURNIP_PROF="$MNT/etc/profile.d/turnip-a850.sh"
    if [ -f "$TURNIP_PROF" ] && ! grep -q "shmem-compat.sh" "$TURNIP_PROF" 2>/dev/null; then
        printf "\n# Optional SysV SHM / X11 MIT-SHM shim (managed by /data/adb/debian-gpu.sh PERF_SHMEM_COMPAT)\n[ -r /etc/profile.d/shmem-compat.sh ] && . /etc/profile.d/shmem-compat.sh\n" >> "$TURNIP_PROF"
    fi
}

EXPECTED_KGSL_SHA256="2fb43a4754f44459c67ba6b65c574a561f0bdf113a5b810fc51071497bc3500b"

apply_kernel_boost() {
    [ "${SKIP_KBOOST:-0}" = "1" ] && return 0
    load_conf
    KBOOST_KO=/data/adb/honor_boost.ko
    if [ "$PERF_KERNEL_BOOST" = "1" ] && [ -r "$KBOOST_KO" ]; then
        KGSL_SHA=$(sha256sum /vendor_dlkm/lib/modules/msm_kgsl.ko 2>/dev/null | awk '{print $1}')
        if [ -n "$KGSL_SHA" ] && [ "$KGSL_SHA" != "$EXPECTED_KGSL_SHA256" ]; then
            echo "Warning: msm_kgsl.ko SHA-256 changed after OTA; skipping honor_boost.ko GPU hook." >&2
            PERF_GPU_UNLOCK=0
        fi
        if ! lsmod 2>/dev/null | grep -q '^honor_boost '; then
            insmod "$KBOOST_KO" >/dev/null 2>&1 || true
        fi
        if [ -d /sys/module/honor_boost/parameters ]; then
            KGSL_VER=$(cat /sys/module/honor_boost/parameters/kgsl_verified 2>/dev/null || echo 0)
            if [ "$PERF_GPU_UNLOCK" = "1" ] && [ "$KGSL_VER" = "1" ]; then
                (echo 1 > /sys/module/honor_boost/parameters/gpu_unclamp) 2>/dev/null || true
                # Let honor_boost.ko intercept real max_pwrlevel writes in-kernel (no stale sink file)
                unguard_sysfs_node /sys/class/kgsl/kgsl-3d0/max_pwrlevel "0"
            else
                (echo 0 > /sys/module/honor_boost/parameters/gpu_unclamp) 2>/dev/null || true
            fi
            if [ "$PERF_CPU_UNLOCK" = "1" ]; then
                (echo 5011200 > /sys/module/honor_boost/parameters/cpu_unclamp_khz) 2>/dev/null || true
            else
                (echo 0 > /sys/module/honor_boost/parameters/cpu_unclamp_khz) 2>/dev/null || true
            fi
        fi
    else
        if [ -d /sys/module/honor_boost/parameters ]; then
            (echo 0 > /sys/module/honor_boost/parameters/gpu_unclamp) 2>/dev/null || true
            (echo 0 > /sys/module/honor_boost/parameters/cpu_unclamp_khz) 2>/dev/null || true
        fi
        if lsmod 2>/dev/null | grep -q '^honor_boost '; then
            rmmod honor_boost >/dev/null 2>&1 || true
            # Re-apply stock KGSL max_pwrlevel and nudge CPU policies so lifted values don't linger
            if [ "$PERF_GPU_UNLOCK" = "0" ]; then
                ORIG_MAX_PL=$(get_orig_node gpu_max_pwrlevel "" | tr -d ' \r\n')
                [ -n "$ORIG_MAX_PL" ] && (echo "$ORIG_MAX_PL" > /sys/class/kgsl/kgsl-3d0/max_pwrlevel) 2>/dev/null || true
            fi
            if [ "$PERF_CPU_UNLOCK" = "0" ]; then
                for p in 0 3 6; do
                    CUR_M=$(cat "/sys/devices/system/cpu/cpufreq/policy${p}/scaling_max_freq" 2>/dev/null || true)
                    [ -n "$CUR_M" ] && (echo "$CUR_M" > "/sys/devices/system/cpu/cpufreq/policy${p}/scaling_max_freq") 2>/dev/null || true
                done
            fi
        fi
    fi
}

apply_xfce_tweaks() {
    load_conf
    mountpoint -q "$MNT" || return 0
    pgrep -x xfwm4 >/dev/null 2>&1 || return 0
    if [ "$PERF_XFCE_OPT" = "1" ]; then
        run_in_chroot 'su - droid -c "
            export DISPLAY=:0
            DBUS_ADDR=\$(tr \"\0\" \"\n\" < /proc/\$(pgrep -o -x xfwm4)/environ 2>/dev/null | grep ^DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2-)
            [ -n \"\$DBUS_ADDR\" ] && export DBUS_SESSION_BUS_ADDRESS=\"\$DBUS_ADDR\"
            xfconf-query -c xfwm4 -p /general/show_frame_shadow -n -t bool -s false 2>/dev/null || xfconf-query -c xfwm4 -p /general/show_frame_shadow -s false 2>/dev/null || true
            xfconf-query -c xfwm4 -p /general/show_popup_shadow -n -t bool -s false 2>/dev/null || xfconf-query -c xfwm4 -p /general/show_popup_shadow -s false 2>/dev/null || true
            xfconf-query -c xfwm4 -p /general/vblank_mode -n -t string -s xpresent 2>/dev/null || xfconf-query -c xfwm4 -p /general/vblank_mode -s xpresent 2>/dev/null || true
        "' 2>/dev/null || true
    else
        run_in_chroot 'su - droid -c "
            export DISPLAY=:0
            DBUS_ADDR=\$(tr \"\0\" \"\n\" < /proc/\$(pgrep -o -x xfwm4)/environ 2>/dev/null | grep ^DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2-)
            [ -n \"\$DBUS_ADDR\" ] && export DBUS_SESSION_BUS_ADDRESS=\"\$DBUS_ADDR\"
            xfconf-query -c xfwm4 -p /general/show_frame_shadow -s true 2>/dev/null || true
            xfconf-query -c xfwm4 -p /general/show_popup_shadow -s true 2>/dev/null || true
            xfconf-query -c xfwm4 -p /general/vblank_mode -s off 2>/dev/null || true
        "' 2>/dev/null || true
    fi
}

apply_perf_tweaks() {
    load_conf

    # Keep Termux, Termux:X11, Tailscale, and Debian GPU Manager exempt from Doze/bg throttling
    for pkg in com.termux com.termux.x11 com.debiangpu.manager com.tailscale.ipn me.weishu.kernelsu; do
        cmd deviceidle whitelist +"$pkg" >/dev/null 2>&1 || true
        cmd appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || true
        cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
    done

    # 1. Honor Performance Mode (SmartModeStatus: 4=Performance, 1=Normal)
    if [ "$PERF_HONOR_MODE" = "1" ]; then
        settings put system SmartModeStatus 4 >/dev/null 2>&1 || true
    else
        settings put system SmartModeStatus 1 >/dev/null 2>&1 || true
    fi

    # 2. Adreno 850 GPU thermal & max_pwrlevel unlock (0 = 1450 MHz max; clears Honor's silent max_pwrlevel=13 578 MHz cap)
    save_orig_node /sys/class/kgsl/kgsl-3d0/max_pwrlevel gpu_max_pwrlevel
    if [ "$PERF_GPU_UNLOCK" = "1" ]; then
        guard_sysfs_node /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "0" gpu_thermal_pwrlevel
        guard_sysfs_node /sys/class/kgsl/kgsl-3d0/max_pwrlevel "0" gpu_max_pwrlevel
    else
        unguard_sysfs_node /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "0"
        ORIG_MAX_PL=$(get_orig_node gpu_max_pwrlevel "" | tr -d ' \r\n')
        unguard_sysfs_node /sys/class/kgsl/kgsl-3d0/max_pwrlevel "$ORIG_MAX_PL"
    fi

    # 3. Adreno 850 KGSL wake level & idle timer (+24% FPS in glmark2; keeps GMU IFPC nap safe)
    if [ "$PERF_GPU_MAX_WAKE" = "1" ]; then
        (echo 0 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 500 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
        (echo 0 > /sys/class/kgsl/kgsl-3d0/force_no_nap) 2>/dev/null || true
    elif [ "$PERF_GPU_RAMP" = "1" ]; then
        (echo 7 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 500 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
        (echo 0 > /sys/class/kgsl/kgsl-3d0/force_no_nap) 2>/dev/null || true
    else
        (echo 22 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 80 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
        (echo 0 > /sys/class/kgsl/kgsl-3d0/force_no_nap) 2>/dev/null || true
    fi

    # 4. CPU max frequency, honor_fas burst cap & core_ctl 8-core unlock
    # Uses bind-mount sysfs guards so iawareperf / perf2-hal stay running (smooth UI)
    # without silently re-clamping msm_performance/cpu_max_freq or parking Prime cores.
    if [ "$PERF_CPU_UNLOCK" = "1" ]; then
        guard_sysfs_node /sys/kernel/fas/mgr/fas_enable "0" fas_enable
        guard_sysfs_node /sys/devices/system/cpu/cpu0/core_ctl/max_cpus "3" c0_max
        guard_sysfs_node /sys/devices/system/cpu/cpu0/core_ctl/min_cpus "3" c0_min
        guard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/max_cpus "3" c3_max
        guard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/min_cpus "3" c3_min
        guard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/enable "0" c3_en
        guard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/max_cpus "2" c6_max
        guard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/min_cpus "2" c6_min
        guard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/enable "0" c6_en
        guard_sysfs_node /sys/kernel/msm_performance/parameters/cpu_max_freq \
            "0:3744000 1:3744000 2:3744000 3:4032000 4:4032000 5:4032000 6:5011200 7:5011200" \
            cpu_max_freq
        guard_sysfs_node /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq "3744000" pol0_max
        guard_sysfs_node /sys/devices/system/cpu/cpufreq/policy3/scaling_max_freq "4032000" pol3_max
        guard_sysfs_node /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq "5011200" pol6_max
    else
        unguard_sysfs_node /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq "3744000"
        unguard_sysfs_node /sys/devices/system/cpu/cpufreq/policy3/scaling_max_freq "4032000"
        unguard_sysfs_node /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq "5011200"
        unguard_sysfs_node /sys/kernel/msm_performance/parameters/cpu_max_freq \
            "0:3744000 1:3744000 2:3744000 3:4032000 4:4032000 5:4032000 6:5011200 7:5011200"
        unguard_sysfs_node /sys/kernel/fas/mgr/fas_enable "1"
        unguard_sysfs_node /sys/devices/system/cpu/cpu0/core_ctl/max_cpus "3"
        unguard_sysfs_node /sys/devices/system/cpu/cpu0/core_ctl/min_cpus "3"
        unguard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/max_cpus "3"
        unguard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/min_cpus "0"
        unguard_sysfs_node /sys/devices/system/cpu/cpu3/core_ctl/enable "1"
        unguard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/max_cpus "2"
        unguard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/min_cpus "0"
        unguard_sysfs_node /sys/devices/system/cpu/cpu6/core_ctl/enable "1"
    fi

    # 4b. Docked Thermal Mode: pause Honor 40C skin-temp daemon (dubaid) & guard hn_thermal cooling_switch
    # Keeps vendor.honor.hardware.iawareperf running (smooth UI) and HW CPUCP/LMh + TSENS (105-125C) active!
    if [ "$PERF_THERMAL_DOCKED" = "1" ]; then
        guard_sysfs_node /sys/class/hn_thermal/cooling/cooling_switch "0" cooling_switch
        stop dubaid 2>/dev/null || true
    else
        unguard_sysfs_node /sys/class/hn_thermal/cooling/cooling_switch "1"
        start dubaid 2>/dev/null || true
    fi

    # 5. WALT CPU governor burst tuning
    if [ "$PERF_WALT_BURST" = "1" ]; then
        (echo 70 > /sys/devices/system/cpu/cpufreq/policy0/walt/hispeed_load) 2>/dev/null || true
        (echo 2188800 > /sys/devices/system/cpu/cpufreq/policy0/walt/hispeed_freq) 2>/dev/null || true
        (echo 1 > /sys/devices/system/cpu/cpufreq/policy0/walt/pl) 2>/dev/null || true
        (echo 70 > /sys/devices/system/cpu/cpufreq/policy3/walt/hispeed_load) 2>/dev/null || true
        (echo 2649600 > /sys/devices/system/cpu/cpufreq/policy3/walt/hispeed_freq) 2>/dev/null || true
        (echo 1 > /sys/devices/system/cpu/cpufreq/policy3/walt/pl) 2>/dev/null || true
        (echo 70 > /sys/devices/system/cpu/cpufreq/policy6/walt/hispeed_load) 2>/dev/null || true
        (echo 3571200 > /sys/devices/system/cpu/cpufreq/policy6/walt/hispeed_freq) 2>/dev/null || true
        (echo 1 > /sys/devices/system/cpu/cpufreq/policy6/walt/pl) 2>/dev/null || true
    else
        (echo 90 > /sys/devices/system/cpu/cpufreq/policy0/walt/hispeed_load) 2>/dev/null || true
        (echo 1286400 > /sys/devices/system/cpu/cpufreq/policy0/walt/hispeed_freq) 2>/dev/null || true
        (echo 0 > /sys/devices/system/cpu/cpufreq/policy0/walt/pl) 2>/dev/null || true
        (echo 90 > /sys/devices/system/cpu/cpufreq/policy3/walt/hispeed_load) 2>/dev/null || true
        (echo 2438400 > /sys/devices/system/cpu/cpufreq/policy3/walt/hispeed_freq) 2>/dev/null || true
        (echo 0 > /sys/devices/system/cpu/cpufreq/policy3/walt/pl) 2>/dev/null || true
        (echo 90 > /sys/devices/system/cpu/cpufreq/policy6/walt/hispeed_load) 2>/dev/null || true
        (echo 2438400 > /sys/devices/system/cpu/cpufreq/policy6/walt/hispeed_freq) 2>/dev/null || true
        (echo 0 > /sys/devices/system/cpu/cpufreq/policy6/walt/pl) 2>/dev/null || true
    fi

    # 5b. WALT Prime-Bias (faster single-core migration to 5.01 GHz cpu6-7; keeps <10% idle tasks on Little)
    if [ "$PERF_WALT_PRIME_BIAS" = "1" ]; then
        (echo "40 25" > /proc/sys/walt/cluster0/sched_other_cgroup_updownmigrate) 2>/dev/null || true
        (echo "40 25" > /proc/sys/walt/cluster0/sched_foreground_updownmigrate) 2>/dev/null || true
        (echo "40 25" > /proc/sys/walt/cluster0/sched_topapp_updownmigrate) 2>/dev/null || true
        (echo "45 30" > /proc/sys/walt/cluster1/sched_other_cgroup_updownmigrate) 2>/dev/null || true
        (echo "45 30" > /proc/sys/walt/cluster1/sched_foreground_updownmigrate) 2>/dev/null || true
        (echo "45 30" > /proc/sys/walt/cluster1/sched_topapp_updownmigrate) 2>/dev/null || true
        (echo 1 > /proc/sys/walt/sched_asymcap_boost) 2>/dev/null || true
        (echo 25 > /proc/sys/walt/sched_min_task_util_for_boost) 2>/dev/null || true
    else
        (echo "95 85" > /proc/sys/walt/cluster0/sched_other_cgroup_updownmigrate) 2>/dev/null || true
        (echo "95 85" > /proc/sys/walt/cluster0/sched_foreground_updownmigrate) 2>/dev/null || true
        (echo "85 75" > /proc/sys/walt/cluster0/sched_topapp_updownmigrate) 2>/dev/null || true
        (echo "95 85" > /proc/sys/walt/cluster1/sched_other_cgroup_updownmigrate) 2>/dev/null || true
        (echo "95 85" > /proc/sys/walt/cluster1/sched_foreground_updownmigrate) 2>/dev/null || true
        (echo "95 85" > /proc/sys/walt/cluster1/sched_topapp_updownmigrate) 2>/dev/null || true
        (echo 0 > /proc/sys/walt/sched_asymcap_boost) 2>/dev/null || true
        (echo 51 > /proc/sys/walt/sched_min_task_util_for_boost) 2>/dev/null || true
    fi

    # 6. Memory & chroot loop I/O tuning (allow moderate ZRAM swap so 5-6 GB Gunyah VM never triggers lmkd/OOM)
    LDEV=$(get_loop_dev || true)
    if [ "$PERF_VM_IO" = "1" ]; then
        if pgrep -x crosvm >/dev/null 2>&1; then
            (echo 15 > /proc/sys/vm/swappiness) 2>/dev/null || true
            [ -w /proc/sys/vm/direct_swappiness ] && (echo 20 > /proc/sys/vm/direct_swappiness) 2>/dev/null || true
        else
            (echo 20 > /proc/sys/vm/swappiness) 2>/dev/null || true
        fi
        (echo 50 > /proc/sys/vm/vfs_cache_pressure) 2>/dev/null || true
        [ -n "$LDEV" ] && (echo 512 > "/sys/block/$LDEV/queue/read_ahead_kb") 2>/dev/null || true
    else
        (echo 60 > /proc/sys/vm/swappiness) 2>/dev/null || true
        (echo 100 > /proc/sys/vm/vfs_cache_pressure) 2>/dev/null || true
        [ -n "$LDEV" ] && (echo 128 > "/sys/block/$LDEV/queue/read_ahead_kb") 2>/dev/null || true
    fi

    # 7. Transparent Huge Pages defrag stutter fix & OOM-safe mTHP shmem policy
    # Linux 6.18 shmem mTHP orders <= PAGE_ALLOC_COSTLY_ORDER (32kB/16kB/8kB = order 3/2/1)
    # invoke the kernel OOM killer under defrag=always/madvise (GFP_TRANSHUGE lacks __GFP_NORETRY).
    # Keep sub-64kB shmem mTHP disabled and never use synchronous defrag=always during VM boot.
    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
        for sz in 32kB 16kB 8kB; do
            [ -w "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/shmem_enabled" ] && \
                (echo never > "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/shmem_enabled") 2>/dev/null || true
        done
        if pgrep -x crosvm >/dev/null 2>&1; then
            (echo defer > /sys/kernel/mm/transparent_hugepage/defrag) 2>/dev/null || true
        elif [ "$PERF_THP_OPT" = "1" ]; then
            (echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag) 2>/dev/null || true
            (echo madvise > /sys/kernel/mm/transparent_hugepage/enabled) 2>/dev/null || true
            for sz in 128kB 256kB 512kB 1024kB 2048kB; do
                (echo madvise > "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/enabled") 2>/dev/null || true
            done
            (echo always > /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled) 2>/dev/null || true
        else
            (echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag) 2>/dev/null || true
            (echo always > /sys/kernel/mm/transparent_hugepage/enabled) 2>/dev/null || true
            for sz in 64kB 128kB 256kB 512kB 1024kB 2048kB; do
                (echo always > "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/enabled") 2>/dev/null || true
            done
        fi
    fi

    # 7b. HyperHold zswapd churn reduction & udmabuf Venus/Wayland cap unlock.
    # Always keep MGLRU min_ttl_ms=0 on Android so MGLRU never bypasses lmkd and OOM-kills VMs/system daemons.
    (echo 0 > /sys/kernel/mm/lru_gen/min_ttl_ms) 2>/dev/null || true
    save_orig_node /sys/module/udmabuf/parameters/size_limit_mb udmabuf_size
    save_orig_node /sys/module/udmabuf/parameters/list_limit udmabuf_list
    if [ ! -f "$GUARD_DIR/orig_hh_avail_bufs" ] && [ -r /sys/block/zram0/hyperhold_avail_buffers ] && ! is_mounted_path /sys/block/zram0/hyperhold_avail_buffers; then
        mkdir -p "$GUARD_DIR"
        awk '/hhgki_avail_buffers:/{a=$2} /hhgki_min_avail_buffers:/{b=$2} /hhgki_high_avail_buffers:/{c=$2} /hhgki_free_swap_threshold:/{d=$2} END{if(a!=""&&b!=""&&c!=""&&d!="") print a,b,c,d}' \
            /sys/block/zram0/hyperhold_avail_buffers > "$GUARD_DIR/orig_hh_avail_bufs" 2>/dev/null || true
    fi
    if [ "$PERF_MEM_OPT" = "1" ]; then
        guard_sysfs_node /sys/block/zram0/hyperhold_avail_buffers "1800 1750 1850 500" hh_avail_bufs
        (echo 2048 > /sys/module/udmabuf/parameters/size_limit_mb) 2>/dev/null || true
        (echo 4096 > /sys/module/udmabuf/parameters/list_limit) 2>/dev/null || true
    else
        ORIG_HH=$(get_orig_node hh_avail_bufs "")
        unguard_sysfs_node /sys/block/zram0/hyperhold_avail_buffers "$ORIG_HH"
        ORIG_USZ=$(get_orig_node udmabuf_size "512" | tr -d ' \r\n')
        ORIG_ULM=$(get_orig_node udmabuf_list "1024" | tr -d ' \r\n')
        (echo "$ORIG_USZ" > /sys/module/udmabuf/parameters/size_limit_mb) 2>/dev/null || true
        (echo "$ORIG_ULM" > /sys/module/udmabuf/parameters/list_limit) 2>/dev/null || true
    fi

    # 8. Sync chroot configs, runtime kernel monkey-patch LKM & boot persistence
    apply_chromium_flags
    apply_allocator_opt
    apply_shmem_compat
    apply_kernel_boost
    apply_xfce_tweaks
    sync_boot_script
}

start_pulseaudio() {
    load_conf
    [ "$PERF_PULSEAUDIO" = "1" ] || return 0
    su "$TUID" -g 3003 -c "
        export PREFIX=$TPREFIX HOME=$THOME TMPDIR=$TPREFIX/tmp PATH=$TPREFIX/bin:/system/bin PULSE_SERVER=127.0.0.1
        if pgrep -x pulseaudio >/dev/null 2>&1; then
            if ! timeout 3 pactl info >/dev/null 2>&1; then
                pkill -9 -x pulseaudio 2>/dev/null || true
                sleep 0.3
            fi
        fi
        if ! pgrep -x pulseaudio >/dev/null 2>&1; then
            pulseaudio --start --load='module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1' --exit-idle-time=-1 >/dev/null 2>&1 || true
            sleep 0.5
        fi
        if ! timeout 3 pactl list short sinks 2>/dev/null | grep -qiE 'AAudio_sink|OpenSL'; then
            timeout 3 pactl load-module module-aaudio-sink >/dev/null 2>&1 || timeout 3 pactl load-module module-sles-sink >/dev/null 2>&1 || true
            sleep 0.2
        fi
        SINK=\$(timeout 3 pactl list short sinks 2>/dev/null | awk '/AAudio_sink|OpenSL/{print \$2; exit}')
        if [ -n \"\$SINK\" ]; then
            timeout 3 pactl set-default-sink \"\$SINK\" >/dev/null 2>&1 || true
            timeout 3 pactl set-sink-mute \"\$SINK\" 0 >/dev/null 2>&1 || true
            timeout 3 pactl set-sink-volume \"\$SINK\" 100% >/dev/null 2>&1 || true
            for idx in \$(timeout 3 pactl list short sink-inputs 2>/dev/null | awk '{print \$1}'); do
                timeout 3 pactl move-sink-input \"\$idx\" \"\$SINK\" >/dev/null 2>&1 || true
            done
        fi
        # Ensure TCP simple-protocol listener on 127.0.0.1:4714 for macOS AndroidAudio.driver
        if ! timeout 3 pactl list short modules 2>/dev/null | grep -q 'module-simple-protocol-tcp'; then
            timeout 3 pactl load-module module-simple-protocol-tcp rate=48000 format=s16le channels=2 port=4714 listen=127.0.0.1 playback=true record=false >/dev/null 2>&1 || true
        fi
    " 2>/dev/null || true
}

stop_pulseaudio() {
    pkill -TERM -x pulseaudio 2>/dev/null || true
    sleep 0.3
    pkill -KILL -x pulseaudio 2>/dev/null || true
}

do_set_toggle() {
    KEY="${1:-}"
    VAL="${2:-}"
    case "$KEY" in
        PERF_HONOR_MODE|PERF_GPU_UNLOCK|PERF_GPU_RAMP|PERF_GPU_MAX_WAKE|PERF_CPU_UNLOCK|PERF_THERMAL_DOCKED|PERF_WALT_BURST|PERF_WALT_PRIME_BIAS|PERF_VM_IO|PERF_MEM_OPT|PERF_THP_OPT|PERF_JEMALLOC|PERF_SHMEM_COMPAT|PERF_KERNEL_BOOST|PERF_XFCE_OPT|PERF_CHROMIUM_VULKAN|PERF_PULSEAUDIO|PERF_BOOT_PERSIST)
            ;;
        *)
            echo "Unknown toggle key: $KEY" >&2
            exit 1
            ;;
    esac
    case "$VAL" in
        0|1) ;;
        *)
            echo "Toggle value must be 0 or 1" >&2
            exit 1
            ;;
    esac
    load_conf
    # Update or append key in $CONF
    TMP="$CONF.tmp"
    grep -v "^${KEY}=" "$CONF" > "$TMP" 2>/dev/null || true
    echo "${KEY}=${VAL}" >> "$TMP"
    mv "$TMP" "$CONF"
    chmod 644 "$CONF"

    # Keep GPU_RAMP and GPU_MAX_WAKE mutually coherent
    if [ "$KEY" = "PERF_GPU_MAX_WAKE" ] && [ "$VAL" = "1" ]; then
        grep -v "^PERF_GPU_RAMP=" "$CONF" > "$TMP" 2>/dev/null || true
        echo "PERF_GPU_RAMP=1" >> "$TMP"
        mv "$TMP" "$CONF"
    elif [ "$KEY" = "PERF_GPU_RAMP" ] && [ "$VAL" = "0" ]; then
        grep -v "^PERF_GPU_MAX_WAKE=" "$CONF" > "$TMP" 2>/dev/null || true
        echo "PERF_GPU_MAX_WAKE=0" >> "$TMP"
        mv "$TMP" "$CONF"
    fi

    apply_perf_tweaks
    if [ "$KEY" = "PERF_PULSEAUDIO" ]; then
        if [ "$VAL" = "1" ]; then
            start_pulseaudio
        else
            stop_pulseaudio
        fi
    fi
    echo "Set ${KEY}=${VAL} (applied & persisted)"
}

do_reset_perf() {
    load_conf
    cat > "$CONF" <<EOF
# Stock defaults (restored)
PERF_HONOR_MODE=0
PERF_GPU_UNLOCK=0
PERF_GPU_RAMP=0
PERF_GPU_MAX_WAKE=0
PERF_CPU_UNLOCK=0
PERF_THERMAL_DOCKED=0
PERF_WALT_BURST=0
PERF_WALT_PRIME_BIAS=0
PERF_VM_IO=0
PERF_MEM_OPT=0
PERF_THP_OPT=0
PERF_JEMALLOC=0
PERF_SHMEM_COMPAT=0
PERF_KERNEL_BOOST=0
PERF_XFCE_OPT=0
PERF_CHROMIUM_VULKAN=0
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=0
MACOS_RES=${MACOS_RES:-1920x1080}
MACOS_RAM_MB=${MACOS_RAM_MB:-4400}
EOF
    chmod 644 "$CONF"
    apply_perf_tweaks
    echo "Restored stock defaults."
}

do_profile() {
    PROF="${1:-}"
    load_conf
    case "$PROF" in
        docked)
            cat > "$CONF" <<EOF
# Profile: Docked Max (all 18 performance + kernel boost + compat tweaks enabled)
PERF_HONOR_MODE=1
PERF_GPU_UNLOCK=1
PERF_GPU_RAMP=1
PERF_GPU_MAX_WAKE=1
PERF_CPU_UNLOCK=1
PERF_THERMAL_DOCKED=1
PERF_WALT_BURST=1
PERF_WALT_PRIME_BIAS=1
PERF_VM_IO=1
PERF_MEM_OPT=1
PERF_THP_OPT=1
PERF_JEMALLOC=1
PERF_SHMEM_COMPAT=1
PERF_KERNEL_BOOST=0
PERF_XFCE_OPT=1
PERF_CHROMIUM_VULKAN=1
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=1
MACOS_RES=${MACOS_RES:-1920x1080}
MACOS_RAM_MB=${MACOS_RAM_MB:-4400}
EOF
            chmod 644 "$CONF"
            apply_perf_tweaks
            start_pulseaudio
            echo "Applied profile: Docked Max (17 tweaks ON, 1450 MHz wake, docked thermal; honor_boost.ko opt-in)."
            ;;
        battery)
            cat > "$CONF" <<EOF
# Profile: Battery / Portable (stock thermals/clocks + zero-power desktop/mem/SHM optimizations)
PERF_HONOR_MODE=0
PERF_GPU_UNLOCK=0
PERF_GPU_RAMP=0
PERF_GPU_MAX_WAKE=0
PERF_CPU_UNLOCK=0
PERF_THERMAL_DOCKED=0
PERF_WALT_BURST=0
PERF_WALT_PRIME_BIAS=0
PERF_VM_IO=1
PERF_MEM_OPT=1
PERF_THP_OPT=1
PERF_JEMALLOC=1
PERF_SHMEM_COMPAT=1
PERF_KERNEL_BOOST=0
PERF_XFCE_OPT=1
PERF_CHROMIUM_VULKAN=1
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=1
MACOS_RES=${MACOS_RES:-1920x1080}
MACOS_RAM_MB=${MACOS_RAM_MB:-4400}
EOF
            chmod 644 "$CONF"
            apply_perf_tweaks
            echo "Applied profile: Battery / Portable (dubaid + stock clocks restored; MGLRU/HyperHold/udmabuf/SHM/jemalloc/THP/Vulkan ON)."
            ;;
        *)
            echo "Usage: $0 profile {docked|battery}" >&2
            exit 1
            ;;
    esac
}

do_set_macos_opt() {
    KEY="${1:-}"
    VAL="${2:-}"
    case "$KEY" in
        MACOS_RES)
            case "$VAL" in
                1920x1080|2384x1100|1280x720) ;;
                *) echo "Invalid MACOS_RES: $VAL (use 1920x1080|2384x1100|1280x720)" >&2; exit 1 ;;
            esac
            ;;
        MACOS_RAM_MB)
            case "$VAL" in
                4400|5200|6000) ;;
                *) echo "Invalid MACOS_RAM_MB: $VAL (use 4400|5200|6000)" >&2; exit 1 ;;
            esac
            ;;
        *)
            echo "Unknown macOS option: $KEY" >&2
            exit 1
            ;;
    esac
    load_conf
    TMP="$CONF.tmp"
    grep -v "^${KEY}=" "$CONF" > "$TMP" 2>/dev/null || true
    echo "${KEY}=${VAL}" >> "$TMP"
    mv "$TMP" "$CONF"
    chmod 644 "$CONF"
    echo "Saved ${KEY}=${VAL} (takes effect on next Start macOS 27)."
}

start_termux_x11() {
    cmd deviceidle whitelist +com.termux >/dev/null 2>&1 || true
    cmd deviceidle whitelist +com.termux.x11 >/dev/null 2>&1 || true
    if ! ([ -S "$X11_DIR/X0" ] && pgrep -f "termux.x11" >/dev/null 2>&1); then
        su "$TUID" -c "
            export PREFIX=$TPREFIX HOME=$THOME TMPDIR=$TPREFIX/tmp PATH=$TPREFIX/bin:/system/bin
            nohup termux-x11 :0 -ac >\$TMPDIR/termux-x11.log 2>&1 </dev/null &
        "
        i=0
        while [ ! -S "$X11_DIR/X0" ] && [ "$i" -lt 20 ]; do
            sleep 0.5
            i=$((i + 1))
        done
    fi
    am start --user 0 -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
}

kill_desktop_procs() {
    run_in_chroot '
        for p in x0vncserver X0tigervnc i3 polybar picom dunst kitty \
                 xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfconfd plank \
                 labwc waybar swaybg foot Xwayland wayland_android_bridge; do
            pkill -9 -x "$p" 2>/dev/null || true
        done
        pkill -9 -f "[w]ebsockify.*6080" 2>/dev/null || true
        pkill -9 -f "[d]bus-run-session -- (i3|startxfce4|labwc)" 2>/dev/null || true
        rm -rf /home/droid/.cache/sessions 2>/dev/null || true
    ' || true
    pkill -9 -f "TCP-LISTEN:[5]900" 2>/dev/null || true
    pkill -9 -f "TCP-LISTEN:[6]080" 2>/dev/null || true
}

do_stop() {
    if mountpoint -q "$MNT"; then
        kill_desktop_procs
    fi
    echo "Debian GPU desktop & remote X stopped."
}

ensure_macos_bind() {
    mkdir -p "$MACOS_DIR" "$MACOS_DIR/mesa_shader_cache" "$MNT/var/xnu-mac"
    mountpoint -q "$MNT/var/xnu-mac" 2>/dev/null || mount --bind "$MACOS_DIR" "$MNT/var/xnu-mac"
}

kill_matching_safe() {
    local pat="$1"
    for p in $(pgrep -f "$pat" 2>/dev/null || true); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null || true
    done
}

get_macos_guest_ip() {
    local ip=""
    if [ -r "$MNT/tmp/macos-ip" ]; then
        ip=$(tr -d ' \r\n' < "$MNT/tmp/macos-ip" 2>/dev/null || true)
    fi
    if [ -z "$ip" ]; then
        ip=$(ip neigh show 2>/dev/null | awk '/^192\.168\.77\./{print $1; exit}' || true)
    fi
    echo "$ip"
}

stop_macos_services() {
    kill_matching_safe "TCP-LISTEN:4714"
    kill_matching_safe "TCP-LISTEN:5901"
    kill_matching_safe "TCP-LISTEN:2223"
    kill_matching_safe "/usr/local/bin/macos-bridge.py"
}

start_macos_services() {
    do_mount
    start_pulseaudio

    # Wait briefly for crosvm TAP 192.168.78.1 to exist if VM just started
    i=0
    while ! ip -4 addr show 2>/dev/null | grep -q "192.168.78.1" && [ "$i" -lt 10 ]; do
        sleep 0.5
        i=$((i + 1))
    done

    if ip -4 addr show 2>/dev/null | grep -q "192.168.78.1"; then
        # 1. Audio TCP bridge (strictly on private VM TAP 192.168.78.1:4714 -> Termux PulseAudio AAudio)
        kill_matching_safe "TCP-LISTEN:4714"
        if [ -x "$MNT/usr/bin/socat" ]; then
            setsid chroot "$MNT" /usr/bin/socat \
                "TCP-LISTEN:4714,bind=192.168.78.1,reuseaddr,fork,nodelay" TCP:127.0.0.1:4714 \
                >"$MNT/tmp/socat-audio.log" 2>&1 </dev/null &
        fi

        # 2. WebDAV (/android, /debian) + Bidirectional Clipboard + Guest IP bridge on 192.168.78.1:8445
        kill_matching_safe "/usr/local/bin/macos-bridge.py"
        if [ -x "$MNT/usr/local/bin/macos-bridge.py" ]; then
            setsid chroot "$MNT" /usr/bin/env \
                PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DISPLAY=:0 \
                python3 /usr/local/bin/macos-bridge.py \
                >"$MNT/tmp/macos-bridge.log" 2>&1 </dev/null &
        fi
    else
        echo "Note: VM TAP 192.168.78.1 not up yet (start macOS 27 first)."
    fi

    # 3. Tailscale-only remote access for macOS Screen Sharing (:5901->:5900) and SSH (:2223->:22)
    TS_IP=$(get_tailscale_ip || true)
    MAC_IP=$(get_macos_guest_ip || true)
    kill_matching_safe "TCP-LISTEN:5901"
    kill_matching_safe "TCP-LISTEN:2223"
    if [ -n "$TS_IP" ] && [ -n "$MAC_IP" ] && [ -x "$MNT/usr/bin/socat" ]; then
        setsid chroot "$MNT" /usr/bin/socat \
            "TCP-LISTEN:5901,bind=$TS_IP,reuseaddr,fork,nodelay" "TCP:${MAC_IP}:5900" \
            >"$MNT/tmp/socat-mac-vnc.log" 2>&1 </dev/null &
        setsid chroot "$MNT" /usr/bin/socat \
            "TCP-LISTEN:2223,bind=$TS_IP,reuseaddr,fork,nodelay" "TCP:${MAC_IP}:22" \
            >"$MNT/tmp/socat-mac-ssh.log" 2>&1 </dev/null &
        echo "macOS Tailscale forwards: Screen Sharing ${TS_IP}:5901 -> ${MAC_IP}:5900 | SSH ${TS_IP}:2223 -> ${MAC_IP}:22"
    else
        echo "macOS Tailscale forwards: waiting for Tailscale (${TS_IP:-offline}) & macOS guest IP (${MAC_IP:-pending})."
    fi
    echo "macOS Host Bridge: Audio 192.168.78.1:4714 | WebDAV & Clipboard http://192.168.78.1:8445"
}

do_macos_stop() {
    stop_macos_services
    pkill -TERM -x xnu_fb_view 2>/dev/null || true
    pkill -TERM -x xnu_fb_bridge 2>/dev/null || true
    pkill -TERM -f "^sh /data/adb/run-xnulinux-vm\\.sh" 2>/dev/null || true
    pkill -TERM -x crosvm 2>/dev/null || true
    i=0
    while (pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -x xnu_fb_bridge >/dev/null 2>&1) && [ "$i" -lt 10 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    pkill -KILL -x xnu_fb_view 2>/dev/null || true
    pkill -KILL -x xnu_fb_bridge 2>/dev/null || true
    pkill -KILL -f "^sh /data/adb/run-xnulinux-vm\\.sh" 2>/dev/null || true
    pkill -KILL -x crosvm 2>/dev/null || true
    if [ -r /sys/power/wake_lock ] && [ -w /sys/power/wake_unlock ]; then
        for wl in $(tr ' ' '\n' < /sys/power/wake_lock 2>/dev/null | grep '^xnulinux_vm_' || true); do
            echo "$wl" > /sys/power/wake_unlock 2>/dev/null || true
        done
    fi
    [ -w /proc/sys/vm/direct_swappiness ] && (echo 60 > /proc/sys/vm/direct_swappiness) 2>/dev/null || true
    [ -w /sys/block/zram0/hyperhold_cold_writeback ] && (echo 1 > /sys/block/zram0/hyperhold_cold_writeback) 2>/dev/null || true
    apply_perf_tweaks >/dev/null 2>&1 || true
    echo "macOS 27 VM stopped."
}

do_macos_start() {
    if [ ! -x "$MACOS_SCRIPT" ]; then
        echo "Error: $MACOS_SCRIPT not found or not executable." >&2
        exit 1
    fi
    load_conf
    do_mount
    ensure_macos_bind
    apply_perf_tweaks
    start_pulseaudio

    # Free RAM by stopping Debian desktop (Wayland or XFCE4) & any prior VM instance
    if pgrep -x xfwm4 >/dev/null 2>&1 || pgrep -x plank >/dev/null 2>&1 || pgrep -x labwc >/dev/null 2>&1 || pgrep -x x0vncserver >/dev/null 2>&1; then
        echo "Stopping Debian desktop before starting macOS 27..."
        kill_desktop_procs
    fi
    if pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -x xnu_fb_bridge >/dev/null 2>&1 || pgrep -f "^sh /data/adb/run-xnulinux-vm\\.sh" >/dev/null 2>&1; then
        do_macos_stop >/dev/null 2>&1 || true
    fi
    # Drop Linux page cache & compact free RAM cleanly WITHOUT running `am kill-all`
    # (which kills Tailscale VPN, Termux, bridges, and background services).
    evict_cached_apps_safe
    sleep 0.3

    # Reset XNU dmesg log & stale guest IP so readiness reflects this boot
    : > "$MACOS_DIR/xnu-dmesg.log" 2>/dev/null || true
    : > "$MACOS_LOG" 2>/dev/null || true
    rm -f "$MNT/tmp/macos-ip" "$MACOS_DIR/xnu-scanout.cache" 2>/dev/null || true

    # Apply persisted resolution & RAM presets (overrideable via env)
    RES="${MACOS_RES:-1920x1080}"
    FB_W="${FB_WIDTH:-${RES%x*}}"
    FB_H="${FB_HEIGHT:-${RES#*x}}"
    XNU_RAM="${XNU_RAM_MB:-${MACOS_RAM_MB:-4400}}"
    LINUX_MB=512
    VM_MEM="${VM_MEM_MB:-$(( ((LINUX_MB + XNU_RAM + 208 + 63) / 64) * 64 ))}"
    if [ "$VM_MEM" -gt 6144 ]; then
        VM_MEM=6144
        [ "$((XNU_RAM + LINUX_MB + 128))" -gt 6144 ] && XNU_RAM=$((6144 - LINUX_MB - 128))
    fi

    # Direct GPU Display Bypass (zero Termux:X11 overhead): xnu_fb_bridge -> DebianGPU DisplayActivity
    if [ -x /data/adb/xnu_fb_bridge ]; then
        setsid /data/adb/xnu_fb_bridge >/data/local/tmp/xnu_fb_bridge.log 2>&1 </dev/null &
        sleep 0.3
        for p in $(pidof xnu_fb_bridge 2>/dev/null); do
            [ -w /dev/cpuset/top-app/cgroup.procs ] && echo "$p" > /dev/cpuset/top-app/cgroup.procs 2>/dev/null || true
            [ -w /dev/cpuctl/top-app/cgroup.procs ] && echo "$p" > /dev/cpuctl/top-app/cgroup.procs 2>/dev/null || true
            [ -w "/proc/$p/oom_score_adj" ] && echo -900 > "/proc/$p/oom_score_adj" 2>/dev/null || true
        done
        am start --user 0 -n com.debiangpu.manager/.DisplayActivity --es mode mac >/dev/null 2>&1 || true
    else
        # Fallback to legacy Termux:X11 viewer if direct bridge is not installed
        start_termux_x11
        if [ -x "$MNT/usr/local/bin/xnu_fb_view" ]; then
            setsid chroot "$MNT" /usr/bin/env -i \
                DISPLAY=:0 \
                PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                /usr/local/bin/xnu_fb_view --fullscreen --size "${FB_W}x${FB_H}" \
                >"$MNT$MACOS_VIEW_LOG" 2>&1 </dev/null &
            sleep 0.5
        fi
    fi

    # Launch Gunyah + Adreno 850 Venus macOS 27.2 VM detached from caller stdio
    setsid env FB_WIDTH="$FB_W" FB_HEIGHT="$FB_H" XNU_RAM_MB="$XNU_RAM" LINUX_MEM="${LINUX_MB}M" VM_MEM_MB="$VM_MEM" \
        sh "$MACOS_SCRIPT" >"$MACOS_LOG" 2>&1 </dev/null &

    # Wait up to 8s for crosvm to come up
    i=0
    while ! pgrep -x crosvm >/dev/null 2>&1 && [ "$i" -lt 16 ]; do
        sleep 0.5
        i=$((i + 1))
    done

    # Re-apply VM-aware memory tuning now that crosvm is live (swappiness=15, direct_swappiness=20, MGLRU min_ttl_ms=0, defrag=defer)
    if pgrep -x crosvm >/dev/null 2>&1; then
        apply_perf_tweaks >/dev/null 2>&1 || true
    fi

    # Promote direct display bridge into Android top-app scheduling group & shield from lmkd
    for p in $(pidof xnu_fb_bridge xnu_fb_view 2>/dev/null); do
        [ -w /dev/cpuset/top-app/cgroup.procs ] && echo "$p" > /dev/cpuset/top-app/cgroup.procs 2>/dev/null || true
        [ -w /dev/cpuctl/top-app/cgroup.procs ] && echo "$p" > /dev/cpuctl/top-app/cgroup.procs 2>/dev/null || true
        [ -w "/proc/$p/oom_score_adj" ] && echo -900 > "/proc/$p/oom_score_adj" 2>/dev/null || true
    done

    # Start Audio (:4714), WebDAV/Clipboard (:8445), and wait in background for:
    #  1) early XnuDisplay scanout PA -> /data/local/xnu-mac/xnu-scanout.cache (before dmesg wraps)
    #  2) macOS guest IP -> Tailscale Screen Sharing (:5901) & SSH (:2223) forwards
    start_macos_services >/dev/null 2>&1 || true
    setsid sh -c '
        DMESG="/data/local/xnu-mac/xnu-dmesg.log"
        CACHE="/data/local/xnu-mac/xnu-scanout.cache"
        for _ in $(seq 1 160); do
            CP=$(pgrep -o -x crosvm 2>/dev/null || true)
            [ -n "$CP" ] || break
            LINE=$(grep "XnuDisplay: scanout " "$DMESG" 2>/dev/null | tail -n 1 || true)
            if [ -n "$LINE" ]; then
                SCAN=$(printf "%s\n" "$LINE" | sed -n "s/.*XnuDisplay: scanout \(0x[0-9a-fA-F]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3/p")
                if [ -n "$SCAN" ]; then
                    printf "%s %s\n" "$CP" "$SCAN" > "$CACHE" 2>/dev/null || true
                    break
                fi
            fi
            sleep 0.25
        done
    ' >/dev/null 2>&1 </dev/null &
    setsid sh -c '
        for _ in $(seq 1 45); do
            sleep 3
            if [ -s /data/local/debian-gpu/tmp/macos-ip ]; then
                /data/adb/debian-gpu.sh macos-services >/dev/null 2>&1 || true
                break
            fi
            pgrep -x crosvm >/dev/null 2>&1 || break
        done
    ' >/dev/null 2>&1 </dev/null &

    VM_PID=$(pgrep -o -x crosvm 2>/dev/null || true)
    BRIDGE_PID=$(pgrep -o -x xnu_fb_bridge 2>/dev/null || pgrep -o -x xnu_fb_view 2>/dev/null || true)
    if [ -n "$VM_PID" ]; then
        echo "macOS 27.2 VM booting on Gunyah (Adreno 850 Venus, ${FB_W}x${FB_H}, XNU ${XNU_RAM} MB / VM ${VM_MEM} MB)"
        echo "crosvm PID: $VM_PID | Display bridge PID: ${BRIDGE_PID:-none}"
        echo "Bridge: Audio :4714 | WebDAV & Clipboard :8445 | Log: $MACOS_LOG"
        echo "Display appears automatically once XNU completes first swap (~30s)."
    else
        echo "Warning: crosvm did not stay running — tailing $MACOS_LOG:"
        tail -n 20 "$MACOS_LOG" 2>/dev/null || true
        exit 1
    fi
}

do_macos_log() {
    echo "=== VM Launch Log ($MACOS_LOG) ==="
    if [ -r "$MACOS_LOG" ]; then
        tail -n 20 "$MACOS_LOG"
    else
        echo "(no VM log yet)"
    fi
    echo ""
    echo "=== XNU dmesg ($MACOS_DIR/xnu-dmesg.log) ==="
    if [ -r "$MACOS_DIR/xnu-dmesg.log" ]; then
        tail -n 20 "$MACOS_DIR/xnu-dmesg.log"
    else
        echo "(no XNU dmesg yet)"
    fi
}

# Safe, 100% reversible user-space Honor MagicOS debloat (never touches /system or /vendor)
# Excludes firmware-protected packages (id, parentcontrol, findmydevice) and core stability/projection packages.
HONOR_DEBLOAT_DISABLE="
com.hihonor.auto
com.hihonor.awareness
com.hihonor.brain
com.hihonor.assistant
com.hihonor.magicvoice
com.hihonor.searchservice
com.hihonor.search
com.hihonor.aipluginengine
com.hihonor.android.UEInfoCheck
com.hihonor.hnmagicportal
com.hihonor.suggestion
com.hihonor.aimage.agent
com.hihonor.globalwrite
com.hihonor.recordassistant
com.hihonor.hnstandby
com.hihonor.voiceengine
com.hihonor.android.AutoRegSms
com.hihonor.android.chr
com.hihonor.android.upgradeguide
com.hihonor.hnstartupguide
com.hihonor.browserhomepage
com.honor.reader
com.baidu.input_hihonor
com.sohu.inputmethod.sogou.honor
com.hihonor.scenariomanager
com.hihonor.sceneservice
com.hihonor.quickengine
com.hihonor.smartiot
com.hihonor.intelligentmessage
com.hihonor.servicecenter
com.hihonor.detectrepair
com.hihonor.msdp
com.hihonor.hncloud
com.hihonor.assetsync
com.hihonor.assetsyncservice
com.hihonor.contacts.sync
com.hihonor.koBackup
com.hihonor.android.thememanager
com.hihonor.devicefinder
com.hihonor.dms
com.hihonor.airlink
com.hihonor.handoff
com.hihonor.synergy
com.hihonor.android.instantshare
com.hihonor.crossdeviceserviceshare
com.hihonor.pcassistant
com.hihonor.android.honorsuite
com.hihonor.remoteassist
com.hihonor.android.clone
com.hihonor.wallet
com.hihonor.hnpanpayservice
"

# Persistent user-space bloat (removed for user 0 only; reversible via cmd package install-existing)
HONOR_DEBLOAT_UNINSTALL_U0="
com.hihonor.android.pushagent
com.hihonor.hiview
com.hihonor.nearby
com.honor.aimm
"

do_debloat() {
    RESTORE_SCRIPT=/data/adb/restore-honor-bloat.sh
    ENABLED_LIST=$(pm list packages -e 2>/dev/null || true)
    NEW_DIS=0
    NEW_UNINST=0
    ALREADY=0

    cat > "$RESTORE_SCRIPT" <<'EOF'
#!/system/bin/sh
# Auto-generated restore script for Honor MagicOS user-space debloat
# Run as root: su -c /data/adb/restore-honor-bloat.sh
EOF
    chmod 755 "$RESTORE_SCRIPT"

    for p in $HONOR_DEBLOAT_DISABLE; do
        echo "pm enable --user 0 $p >/dev/null 2>&1 || true" >> "$RESTORE_SCRIPT"
        if printf "%s\n" "$ENABLED_LIST" | grep -qx "package:$p"; then
            if pm disable-user --user 0 "$p" >/dev/null 2>&1; then
                am force-stop "$p" >/dev/null 2>&1 || true
                NEW_DIS=$((NEW_DIS + 1))
            fi
        else
            ALREADY=$((ALREADY + 1))
        fi
    done

    for p in $HONOR_DEBLOAT_UNINSTALL_U0; do
        echo "cmd package install-existing $p >/dev/null 2>&1 || true" >> "$RESTORE_SCRIPT"
        echo "pm enable --user 0 $p >/dev/null 2>&1 || true" >> "$RESTORE_SCRIPT"
        if printf "%s\n" "$ENABLED_LIST" | grep -qx "package:$p"; then
            if pm uninstall -k --user 0 "$p" >/dev/null 2>&1; then
                am force-stop "$p" >/dev/null 2>&1 || true
                NEW_UNINST=$((NEW_UNINST + 1))
            fi
        else
            ALREADY=$((ALREADY + 1))
        fi
    done

    AVAIL_MB=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    echo "Honor MagicOS debloat complete (user-space only; /system untouched)."
    echo "Newly disabled: $NEW_DIS | Uninstalled (u0): $NEW_UNINST | Already clean: $ALREADY"
    echo "Restore script: $RESTORE_SCRIPT"
    echo "MemAvailable now: ${AVAIL_MB} MB"
    if pgrep -f 'com\.hihonor\.(nearby|hiview|android\.pushagent)' >/dev/null 2>&1; then
        echo "Note: persistent daemons (nearby/pushagent/hiview) are uninstalled for u0 and stay off after reboot (+~120 MB)."
    fi
}

do_restore_bloat() {
    RESTORED=0
    for p in $HONOR_DEBLOAT_UNINSTALL_U0; do
        if cmd package install-existing "$p" >/dev/null 2>&1; then
            pm enable --user 0 "$p" >/dev/null 2>&1 || true
            RESTORED=$((RESTORED + 1))
        fi
    done
    for p in $HONOR_DEBLOAT_DISABLE; do
        if pm enable --user 0 "$p" >/dev/null 2>&1; then
            RESTORED=$((RESTORED + 1))
        fi
    done
    echo "Restored $RESTORED Honor packages (user 0). Reboot recommended if persistent services were restored."
}

evict_cached_apps_safe() {
    # Gently reclaim memory from currently-running non-essential 3rd-party cached apps
    # without touching Tailscale, Termux, Termux:X11, Debian GPU Manager, KernelSU, T3 Code,
    # Bluetooth, or system bridges. Filters to running processes so it finishes in <1s.
    local running_pkgs
    running_pkgs=$( (
        pm list packages -3 2>/dev/null | sed 's/^package:/P /'
        (ps -A -o NAME 2>/dev/null || ps -A 2>/dev/null | awk '{print $NF}') | sed 's/:.*$//' | awk '{print "R " $1}'
    ) | awk '$1=="P"{p[$2]=1} $1=="R" && p[$2]{print $2; delete p[$2]}' )
    for pkg in $running_pkgs; do
        case "$pkg" in
            com.tailscale.ipn|com.termux|com.termux.x11|com.debiangpu.manager|me.weishu.kernelsu|com.t3tools.t3code)
                continue ;;
            *)
                am kill "$pkg" >/dev/null 2>&1 || true ;;
        esac
    done
    sync
    (echo 3 > /proc/sys/vm/drop_caches) 2>/dev/null || true
}

do_free_ram() {
    BEFORE_FREE=$(awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    BEFORE_AVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    evict_cached_apps_safe
    sleep 0.5
    AFTER_FREE=$(awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    AFTER_AVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    echo "Evicted idle cached apps (keeping Tailscale/Termux/bridges safe) & dropped Linux page cache."
    echo "MemFree:      ${BEFORE_FREE} MB -> ${AFTER_FREE} MB"
    echo "MemAvailable: ${BEFORE_AVAIL} MB -> ${AFTER_AVAIL} MB"
}

start_vnc_tailscale_proxy() {
    local ts_ip="${1:-$(get_tailscale_ip || true)}"
    pkill -9 -f "TCP-LISTEN:[5]900" 2>/dev/null || true
    pkill -9 -f "TCP-LISTEN:[6]080" 2>/dev/null || true
    [ -z "$ts_ip" ] && return 0
    if [ -x "$MNT/usr/bin/socat" ]; then
        run_in_chroot "setsid /usr/bin/socat 'TCP-LISTEN:5900,bind=$ts_ip,reuseaddr,fork,nodelay' TCP:127.0.0.1:5900 >/tmp/socat-5900.log 2>&1 </dev/null &"
        run_in_chroot "setsid /usr/bin/socat 'TCP-LISTEN:6080,bind=$ts_ip,reuseaddr,fork,nodelay' TCP:127.0.0.1:6080 >/tmp/socat-6080.log 2>&1 </dev/null &"
    elif [ -x "$TPREFIX/bin/socat" ]; then
        LD_LIBRARY_PATH="$TPREFIX/lib" nohup "$TPREFIX/bin/socat" "TCP-LISTEN:5900,bind=$ts_ip,reuseaddr,fork,nodelay" TCP:127.0.0.1:5900 >/dev/null 2>&1 </dev/null &
        LD_LIBRARY_PATH="$TPREFIX/lib" nohup "$TPREFIX/bin/socat" "TCP-LISTEN:6080,bind=$ts_ip,reuseaddr,fork,nodelay" TCP:127.0.0.1:6080 >/dev/null 2>&1 </dev/null &
    fi
}

do_vnc() {
    do_mount
    TS_IP=$(get_tailscale_ip || true)
    pkill -9 -x x0vncserver 2>/dev/null || true
    pkill -9 -x X0tigervnc 2>/dev/null || true
    pkill -9 -f "[w]ebsockify.*6080" 2>/dev/null || true
    sleep 0.3
    run_in_chroot '
        su - droid -c "
            export DISPLAY=:0
            export PULSE_SERVER=127.0.0.1
            if [ ! -f ~/.vnc/passwd ]; then
                mkdir -p ~/.vnc
                printf \"%s\n\" debian-gpu | vncpasswd -f > ~/.vnc/passwd
                chmod 600 ~/.vnc/passwd
            fi
            setsid x0vncserver -display :0 -interface 127.0.0.1 -rfbport 5900 -PasswordFile ~/.vnc/passwd -UseSHM=0 >/tmp/x0vnc.log 2>&1 </dev/null &
            setsid websockify --web=/usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >/tmp/novnc.log 2>&1 </dev/null &
        "
    '
    sleep 1
    start_vnc_tailscale_proxy "$TS_IP"
    sleep 0.5
    do_status
}

do_start_wayland() {
    do_mount
    if pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -x xnu_fb_bridge >/dev/null 2>&1 || pgrep -f "[r]un-xnulinux-vm.sh" >/dev/null 2>&1; then
        echo "Stopping running macOS 27 VM before starting Debian Wayland Desktop..."
        do_macos_stop
    fi
    apply_perf_tweaks
    start_pulseaudio
    kill_desktop_procs
    sleep 0.3

    # Ensure root-owned /tmp/.X11-unix so Xwayland can bind :0 cleanly
    mountpoint -q "$MNT/tmp/.X11-unix" && umount -l "$MNT/tmp/.X11-unix" 2>/dev/null || true
    mkdir -p "$MNT/tmp/.X11-unix"
    chmod 1777 "$MNT/tmp/.X11-unix"
    chown 0:0 "$MNT/tmp/.X11-unix"

    run_in_chroot '
        su - droid -c "
            mkdir -p /tmp/xdg-droid && chmod 700 /tmp/xdg-droid
            mkdir -p ~/.config/labwc
            WP=/home/droid/.local/share/backgrounds/macos-dark.png
            if [ -f \"\$WP\" ]; then
                BG_CMD=\"swaybg -i \$WP -m fill\"
            else
                BG_CMD=\"swaybg -c #111520\"
            fi
            cat > ~/.config/labwc/autostart <<EOF
wlr-randr --output HEADLESS-1 --custom-mode 1920x1080@120Hz >/tmp/wlr-randr.log 2>&1 || true
\$BG_CMD >/dev/null 2>&1 &
waybar >/tmp/waybar.log 2>&1 &
EOF
            export XDG_RUNTIME_DIR=/tmp/xdg-droid
            export PULSE_SERVER=127.0.0.1
            export VK_ICD_FILENAMES=/opt/turnip-a850/share/vulkan/icd.d/freedreno_drm_shim_icd.aarch64.json
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export TU_DEBUG=noconform,noubwc
            export WLR_BACKENDS=headless
            export WLR_RENDERER=vulkan
            export WLR_LIBINPUT_NO_DEVICES=1
            export GTK_THEME=Adwaita:dark
            export QT_QPA_PLATFORMTHEME=gtk3
            export GDK_BACKEND=wayland,x11
            export QT_QPA_PLATFORM=\"wayland;xcb\"
            export MOZ_ENABLE_WAYLAND=1
            export GSK_RENDERER=vulkan
            . /etc/profile.d/allocator-opt.sh 2>/dev/null || true
            . /etc/profile.d/shmem-compat.sh 2>/dev/null || true
            nohup dbus-run-session -- labwc >/tmp/labwc.log 2>&1 </dev/null &
        "
    '
    i=0
    while ! [ -S "$MNT/tmp/xdg-droid/wayland-0" ] && [ "$i" -lt 20 ]; do
        sleep 0.25
        i=$((i + 1))
    done

    run_in_chroot '
        su - droid -c "
            export XDG_RUNTIME_DIR=/tmp/xdg-droid
            export WAYLAND_DISPLAY=wayland-0
            nohup /usr/local/bin/wayland_android_bridge >/tmp/wayland_bridge.log 2>&1 </dev/null &
        "
    '
    sleep 0.5
    for p in $(pidof labwc wayland_android_bridge 2>/dev/null); do
        [ -w /dev/cpuset/top-app/cgroup.procs ] && echo "$p" > /dev/cpuset/top-app/cgroup.procs 2>/dev/null || true
        [ -w /dev/cpuctl/top-app/cgroup.procs ] && echo "$p" > /dev/cpuctl/top-app/cgroup.procs 2>/dev/null || true
    done
    am start --user 0 -n com.debiangpu.manager/.DisplayActivity --es mode wayland >/dev/null 2>&1 || true
    do_status
}

do_start() {
    if [ -x "$MNT/usr/bin/labwc" ] && [ -x "$MNT/usr/local/bin/wayland_android_bridge" ]; then
        do_start_wayland
        return
    fi
    do_start_x11
}

do_start_x11() {
    do_mount
    if pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -x xnu_fb_bridge >/dev/null 2>&1 || pgrep -f "[r]un-xnulinux-vm.sh" >/dev/null 2>&1; then
        echo "Stopping running macOS 27 VM before starting Debian Desktop..."
        do_macos_stop
    fi
    apply_perf_tweaks
    start_termux_x11
    start_pulseaudio

    TS_IP=$(get_tailscale_ip || true)
    kill_desktop_procs
    sleep 0.5

    # Launch macOS-style XFCE4 + Plank desktop on DISPLAY=:0 as droid (bare-metal Adreno 850 Turnip+Zink)
    run_in_chroot '
        su - droid -c "
            export DISPLAY=:0
            export PULSE_SERVER=127.0.0.1
            export VK_ICD_FILENAMES=/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json
            export MESA_LOADER_DRIVER_OVERRIDE=zink
            export GALLIUM_DRIVER=zink
            export TU_DEBUG=noconform,noubwc
            export MESA_VK_WSI_DEBUG=sw
            export QT_X11_NO_MITSHM=1
            export GTK_THEME=Adwaita:dark
            export QT_QPA_PLATFORMTHEME=gtk3
            . /etc/profile.d/allocator-opt.sh 2>/dev/null || true
            . /etc/profile.d/shmem-compat.sh 2>/dev/null || true
            nohup dbus-run-session -- startxfce4 >/tmp/xfce.log 2>&1 </dev/null &
        "
    '
    # Wait up to 8s for xfwm4 + xfce4-panel to come up
    i=0
    while ! pgrep -x xfwm4 >/dev/null 2>&1 && [ "$i" -lt 16 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    sleep 1

    # Apply persistent XFCE4 compositor tweaks once xfwm4 is up
    apply_xfce_tweaks

    # Ensure Plank macOS dock is running
    run_in_chroot '
        if ! pgrep -x plank >/dev/null 2>&1; then
            su - droid -c "export DISPLAY=:0 PULSE_SERVER=127.0.0.1; nohup plank >/tmp/plank.log 2>&1 </dev/null &"
        fi
    ' || true

    # Launch TigerVNC x0vncserver on localhost:5900 (-UseSHM=0 for Android kernel without SYSVIPC)
    # and noVNC/websockify on localhost:6080
    run_in_chroot '
        su - droid -c "
            export DISPLAY=:0
            export PULSE_SERVER=127.0.0.1
            if [ ! -f ~/.vnc/passwd ]; then
                mkdir -p ~/.vnc
                printf \"%s\n\" debian-gpu | vncpasswd -f > ~/.vnc/passwd
                chmod 600 ~/.vnc/passwd
            fi
            nohup x0vncserver -display :0 -interface 127.0.0.1 -rfbport 5900 -PasswordFile ~/.vnc/passwd -UseSHM=0 >/tmp/x0vnc.log 2>&1 </dev/null &
            nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >/tmp/novnc.log 2>&1 </dev/null &
        "
    '
    sleep 1

    # Expose VNC (5900) and noVNC (6080) ONLY on Tailscale IP (never public WiFi)
    start_vnc_tailscale_proxy "$TS_IP"

    do_status
}

do_umount() {
    do_macos_stop >/dev/null 2>&1 || true
    do_stop
    sleep 0.5
    for p in "$MNT/var/xnu-mac" "$MNT/mnt/android" "$MNT/tmp/.X11-unix" "$MNT/dev/shm" "$MNT/dev/pts" "$MNT/dev" "$MNT/sys" "$MNT/proc" "$MNT"; do
        mountpoint -q "$p" && umount -l "$p" 2>/dev/null || true
    done
    echo "Debian GPU chroot unmounted."
}

do_status() {
    TS_IP=$(get_tailscale_ip || true)
    echo "=== Debian 13 Native Adreno 850 Chroot ==="
    mountpoint -q "$MNT" && echo "Mount:      $MNT (mounted)" || echo "Mount:      NOT mounted"
    ([ -S "$X11_DIR/X0" ] && pgrep -f "termux.x11" >/dev/null 2>&1) && echo "Termux:X11: running (DISPLAY=:0)" || echo "Termux:X11: stopped"
    pgrep -x xfwm4 >/dev/null 2>&1 && echo "Desktop:    macOS-style XFCE4 + Plank Dock running" || echo "Desktop:    stopped"
    if pgrep -x crosvm >/dev/null 2>&1; then
        if grep -q "XnuDisplay: first swap submitted" "$MACOS_DIR/xnu-dmesg.log" 2>/dev/null; then
            echo "macOS 27:   running (Gunyah + Venus ready)"
        else
            echo "macOS 27:   booting (Gunyah + Venus)"
        fi
    else
        echo "macOS 27:   stopped"
    fi
    pgrep -x pulseaudio >/dev/null 2>&1 && echo "PulseAudio: running (127.0.0.1:4713)" || echo "PulseAudio: stopped"
    pgrep -x x0vncserver >/dev/null 2>&1 && echo "TigerVNC:   running (127.0.0.1:5900${TS_IP:+, $TS_IP:5900})" || echo "TigerVNC:   stopped"
    pgrep -f "websockify.*6080" >/dev/null 2>&1 && echo "noVNC Web:  running (http://127.0.0.1:6080/vnc.html${TS_IP:+, http://$TS_IP:6080/vnc.html})" || echo "noVNC Web:  stopped"
}

do_telemetry() {
    load_conf
    echo "ROOT=1"
    mountpoint -q "$MNT" && echo "MOUNT=1" || echo "MOUNT=0"
    ([ -S "$X11_DIR/X0" ] || [ -S "$MNT/tmp/.X11-unix/X0" ] || ss -xl 2>/dev/null | grep -q 'X11-unix/X0') && (pgrep -f 'termux.x11' >/dev/null 2>&1 || ss -xl 2>/dev/null | grep -q 'X11-unix/X0') && echo "X11=1" || echo "X11=0"
    (pgrep -x xfwm4 >/dev/null 2>&1 || pgrep -x labwc >/dev/null 2>&1) && echo "DESKTOP=1" || echo "DESKTOP=0"
    (pgrep -x labwc >/dev/null 2>&1 && pgrep -x wayland_android_bridge >/dev/null 2>&1) && echo "WAYLAND=1" || echo "WAYLAND=0"
    pgrep -x plank >/dev/null 2>&1 && echo "PLANK=1" || echo "PLANK=0"
    [ -x "$MACOS_SCRIPT" ] && echo "MACOS_AVAIL=1" || echo "MACOS_AVAIL=0"
    if pgrep -x crosvm >/dev/null 2>&1; then
        echo "MACOS_VM=1"
        grep -q "XnuDisplay: first swap submitted" "$MACOS_DIR/xnu-dmesg.log" 2>/dev/null && echo "MACOS_READY=1" || echo "MACOS_READY=0"
    else
        echo "MACOS_VM=0"
        echo "MACOS_READY=0"
    fi
    (pgrep -x xnu_fb_bridge >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1) && echo "MACOS_VIEW=1" || echo "MACOS_VIEW=0"
    pgrep -f 'TCP-LISTEN:4714' >/dev/null 2>&1 && echo "MACOS_AUDIO=1" || echo "MACOS_AUDIO=0"
    pgrep -f '/usr/local/bin/macos-bridge.py' >/dev/null 2>&1 && echo "MACOS_BRIDGE=1" || echo "MACOS_BRIDGE=0"
    pgrep -f 'TCP-LISTEN:5901' >/dev/null 2>&1 && echo "MACOS_REMOTE=1" || echo "MACOS_REMOTE=0"
    echo "MACOS_IP=$(get_macos_guest_ip || true)"
    echo "MACOS_RES=${MACOS_RES:-1920x1080}"
    echo "MACOS_RAM_MB=${MACOS_RAM_MB:-4400}"
    (pgrep -x x0vncserver >/dev/null 2>&1 || pgrep -x X0tigervnc >/dev/null 2>&1) && echo "VNC=1" || echo "VNC=0"
    pgrep -f 'websockify.*6080' >/dev/null 2>&1 && echo "NOVNC=1" || echo "NOVNC=0"
    if pgrep -x pulseaudio >/dev/null 2>&1; then
        SINKS=$(su "$TUID" -g 3003 -c "export PREFIX=$TPREFIX PATH=$TPREFIX/bin:/system/bin PULSE_SERVER=127.0.0.1; timeout 2 pactl list short sinks 2>/dev/null" 2>/dev/null || true)
        if echo "$SINKS" | grep -qiE 'AAudio_sink|OpenSL'; then
            echo "PULSE=aaudio"
        else
            echo "PULSE=null"
        fi
    else
        echo "PULSE=stopped"
    fi
    echo "TS=$(get_tailscale_ip || true)"
    echo "DISK=$(df -h "$MNT" 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"

    # CPU cluster frequencies (kHz) & core_ctl active core count
    for p in 0 3 6; do
        echo "CPU${p}_CUR=$(cat /sys/devices/system/cpu/cpufreq/policy${p}/scaling_cur_freq 2>/dev/null || echo 0)"
        echo "CPU${p}_MAX=$(cat /sys/devices/system/cpu/cpufreq/policy${p}/scaling_max_freq 2>/dev/null || echo 0)"
        echo "CPU${p}_HW=$(cat /sys/devices/system/cpu/cpufreq/policy${p}/cpuinfo_max_freq 2>/dev/null || echo 0)"
        echo "CPU${p}_ACT=$(cat /sys/devices/system/cpu/cpu${p}/core_ctl/active_cpus 2>/dev/null || echo '?')"
    done
    echo "FAS_EN=$(cat /sys/kernel/fas/mgr/fas_enable 2>/dev/null | tr -d ' ' || echo '?')"
    echo "COOL_SW=$(cat /sys/class/hn_thermal/cooling/cooling_switch 2>/dev/null | tr -d ' ' || echo '?')"
    echo "DUBAID_SVC=$(getprop init.svc.dubaid 2>/dev/null || echo '?')"

    # Adreno 850 GPU telemetry
    echo "GPU_CUR=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo 0)"
    echo "GPU_MAX=$(cat /sys/class/kgsl/kgsl-3d0/max_clock_mhz 2>/dev/null || echo 1450)"
    echo "GPU_BUSY=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d ' %' || echo 0)"
    echo "GPU_THERM_LVL=$(cat /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel 2>/dev/null || echo 0)"
    echo "GPU_MAX_LVL=$(cat /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null || echo 0)"
    echo "GPU_NO_NAP=$(cat /sys/class/kgsl/kgsl-3d0/force_no_nap 2>/dev/null || echo 0)"
    DEF_LVL=$(cat /sys/class/kgsl/kgsl-3d0/default_pwrlevel 2>/dev/null || echo 22)
    echo "GPU_DEF_LVL=$DEF_LVL"
    echo "GPU_IDLE_MS=$(cat /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null || echo 80)"
    WAKE_MHZ=$(awk -v idx="$((DEF_LVL + 1))" '{if ($idx != "") printf "%d", $idx/1000000; else print "?"}' /sys/class/kgsl/kgsl-3d0/gpu_available_frequencies 2>/dev/null || echo "?")
    echo "GPU_WAKE_MHZ=$WAKE_MHZ"

    # Thermals, Battery, Honor Power Mode (read Current HAL temps, not stale cached block)
    TS_DUMP=$(dumpsys thermalservice 2>/dev/null | head -n 110 || true)
    echo "THERM_STATUS=$(echo "$TS_DUMP" | awk '/Thermal Status:/{print $3; exit}')"
    echo "TEMP_CPU=$(echo "$TS_DUMP" | awk -F'mValue=|, ' '/mName=CPU0,/{v=$2} END{print v}')"
    echo "TEMP_GPU=$(echo "$TS_DUMP" | awk -F'mValue=|, ' '/mName=GPU0-0,/{v=$2} END{print v}')"
    echo "TEMP_SKIN=$(echo "$TS_DUMP" | awk -F'mValue=|, ' '/mName=skin,/{v=$2} END{print v}')"
    echo "BATT_CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo '?')"
    echo "BATT_TEMP=$(awk '{printf "%.1f", $1/10}' /sys/class/power_supply/battery/temp 2>/dev/null || echo '?')"
    echo "BATT_STAT=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo '?')"
    echo "HONOR_MODE=$(settings get system SmartModeStatus 2>/dev/null || echo '?')"
    echo "LAUNCHER_FRONT=$(dumpsys powergenius ScenarioService 2>/dev/null | awk '/mIsLauncherFront/{print $3; exit}' || echo 'false')"

    # Memory / Swap / I/O / THP
    awk '/^MemTotal:/{mt=$2} /^MemAvailable:/{ma=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} END{printf "MEM_USED=%d\nMEM_TOTAL=%d\nSWAP_USED=%d\nSWAP_TOTAL=%d\n", (mt-ma)/1024, mt/1024, (st-sf)/1024, st/1024}' /proc/meminfo 2>/dev/null || true
    echo "SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
    LDEV=$(get_loop_dev || true)
    echo "LOOP_RA=$([ -n "$LDEV" ] && cat "/sys/block/$LDEV/queue/read_ahead_kb" 2>/dev/null || echo '?')"
    echo "THP_DEFRAG=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo '?')"
    echo "MGLRU_TTL=$(cat /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null || echo 0)"
    echo "UDMABUF_MB=$(cat /sys/module/udmabuf/parameters/size_limit_mb 2>/dev/null || echo 512)"
    if [ -r "$MNT/usr/lib/aarch64-linux-gnu/libandroid-shmem.so" ] && grep -q "libandroid-shmem.so" "$MNT/etc/profile.d/shmem-compat.sh" 2>/dev/null; then
        echo "SHMEM_LIB=1"
        [ -c /dev/ashmem ] && echo "SHMEM_BACKING=ashmem" || echo "SHMEM_BACKING=memfd"
    else
        echo "SHMEM_LIB=0"
        echo "SHMEM_BACKING=off"
    fi
    if lsmod 2>/dev/null | grep -q '^honor_boost '; then
        echo "KBOOST_LOADED=1"
        echo "KBOOST_FQ_LIFTED=$(cat /sys/module/honor_boost/parameters/fq_lifted 2>/dev/null || echo 0)"
        echo "KBOOST_FQ_SKIP=$(cat /sys/module/honor_boost/parameters/fq_thermal_skip 2>/dev/null || echo 0)"
        echo "KBOOST_KGSL_CLAMPS=$(cat /sys/module/honor_boost/parameters/kgsl_clamps 2>/dev/null || echo 0)"
        echo "KBOOST_KGSL_VER=$(cat /sys/module/honor_boost/parameters/kgsl_verified 2>/dev/null || echo 0)"
        echo "KBOOST_UDMABUF=$(cat /sys/module/honor_boost/parameters/udmabuf_hits 2>/dev/null || echo 0)"
        echo "KBOOST_CPU_KHZ=$(cat /sys/module/honor_boost/parameters/cpu_unclamp_khz 2>/dev/null || echo 0)"
        echo "KBOOST_GPU_UNCLAMP=$(cat /sys/module/honor_boost/parameters/gpu_unclamp 2>/dev/null || echo 0)"
    else
        echo "KBOOST_LOADED=0"
        echo "KBOOST_FQ_LIFTED=0"
        echo "KBOOST_FQ_SKIP=0"
        echo "KBOOST_KGSL_CLAMPS=0"
        echo "KBOOST_KGSL_VER=0"
        echo "KBOOST_UDMABUF=0"
        echo "KBOOST_CPU_KHZ=0"
        echo "KBOOST_GPU_UNCLAMP=0"
    fi

    # Honor MagicOS debloat status (checks the 17 primary resident Honor bloat packages)
    BLOAT_ACT=$(pm list packages -e 2>/dev/null | grep -cE '^package:(com\.hihonor\.(auto|awareness|brain|assistant|magicvoice|searchservice|aipluginengine|dms|android\.UEInfoCheck|msdp|hncloud|android\.thememanager|android\.pushagent|nearby|hiview|wallet)|com\.honor\.aimm)$' || true)
    echo "HONOR_BLOAT_ACTIVE=${BLOAT_ACT:-0}"
    if [ "${BLOAT_ACT:-0}" = "0" ] && pgrep -f 'com\.hihonor\.(nearby|hiview|android\.pushagent)' >/dev/null 2>&1; then
        echo "HONOR_BLOAT_REBOOT=1"
    else
        echo "HONOR_BLOAT_REBOOT=0"
    fi

    # Active power profile detection
    if [ "$PERF_HONOR_MODE" = "1" ] && [ "$PERF_GPU_MAX_WAKE" = "1" ] && [ "$PERF_CPU_UNLOCK" = "1" ] && [ "$PERF_THERMAL_DOCKED" = "1" ]; then
        echo "PROFILE=docked"
    elif [ "$PERF_HONOR_MODE" = "0" ] && [ "$PERF_GPU_MAX_WAKE" = "0" ] && [ "$PERF_CPU_UNLOCK" = "0" ] && [ "$PERF_THERMAL_DOCKED" = "0" ]; then
        echo "PROFILE=battery"
    else
        echo "PROFILE=custom"
    fi

    # Toggles from persistent config
    echo "PERF_HONOR_MODE=$PERF_HONOR_MODE"
    echo "PERF_GPU_UNLOCK=$PERF_GPU_UNLOCK"
    echo "PERF_GPU_RAMP=$PERF_GPU_RAMP"
    echo "PERF_GPU_MAX_WAKE=$PERF_GPU_MAX_WAKE"
    echo "PERF_CPU_UNLOCK=$PERF_CPU_UNLOCK"
    echo "PERF_THERMAL_DOCKED=$PERF_THERMAL_DOCKED"
    echo "PERF_WALT_BURST=$PERF_WALT_BURST"
    echo "PERF_WALT_PRIME_BIAS=$PERF_WALT_PRIME_BIAS"
    echo "PERF_VM_IO=$PERF_VM_IO"
    echo "PERF_MEM_OPT=$PERF_MEM_OPT"
    echo "PERF_THP_OPT=$PERF_THP_OPT"
    echo "PERF_JEMALLOC=$PERF_JEMALLOC"
    echo "PERF_SHMEM_COMPAT=$PERF_SHMEM_COMPAT"
    echo "PERF_KERNEL_BOOST=$PERF_KERNEL_BOOST"
    echo "PERF_XFCE_OPT=$PERF_XFCE_OPT"
    echo "PERF_CHROMIUM_VULKAN=$PERF_CHROMIUM_VULKAN"
    echo "PERF_PULSEAUDIO=$PERF_PULSEAUDIO"
    echo "PERF_BOOT_PERSIST=$PERF_BOOT_PERSIST"
}

case "${1:-status}" in
    start)          do_start ;;
    wayland-start)  do_start_wayland ;;
    x11-start)      do_start_x11 ;;
    stop)           do_stop ;;
    macos-start)    do_macos_start ;;
    macos-stop)     do_macos_stop ;;
    macos-services) start_macos_services ;;
    macos-log)      do_macos_log ;;
    profile)        do_profile "${2:-}" ;;
    set-macos-opt)  do_set_macos_opt "${2:-}" "${3:-}" ;;
    umount)         do_umount ;;
    status)         do_status ;;
    vnc)            do_vnc ;;
    perf)           apply_perf_tweaks; echo "Perf tweaks applied." ;;
    boot-apply)     SKIP_KBOOST=1 apply_perf_tweaks ;;
    set-toggle)     do_set_toggle "${2:-}" "${3:-}" ;;
    reset-perf)     do_reset_perf ;;
    audio-fix)      PERF_PULSEAUDIO=1; start_pulseaudio; echo "PulseAudio AAudio_sink ready." ;;
    audio-stop)     stop_pulseaudio; echo "PulseAudio stopped." ;;
    debloat)        do_debloat ;;
    restore-bloat)  do_restore_bloat ;;
    free-ram)       do_free_ram ;;
    kernel-profile) [ -x /data/adb/profile-kernel.sh ] && /data/adb/profile-kernel.sh "${2:-3}" || echo "profile-kernel.sh not installed" ;;
    telemetry)      do_telemetry ;;
    shell)
        do_mount
        exec chroot "$MNT" /usr/bin/env -i \
            HOME=/home/droid USER=droid LOGNAME=droid TERM=xterm-256color \
            DISPLAY=:0 PULSE_SERVER=127.0.0.1 \
            VK_ICD_FILENAMES=/opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json \
            MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink \
            TU_DEBUG=noconform,noubwc MESA_VK_WSI_DEBUG=sw QT_X11_NO_MITSHM=1 \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/su -p droid
        ;;
    passwd)
        do_mount
        chroot "$MNT" /bin/su - droid -c "mkdir -p ~/.vnc && vncpasswd ~/.vnc/passwd && chmod 600 ~/.vnc/passwd"
        echo "Restarting VNC to use new password..."
        do_start
        ;;
    *)
        echo "Usage: $0 {start|stop|macos-start|macos-stop|macos-services|macos-log|profile|set-macos-opt|umount|shell|status|vnc|perf|set-toggle|reset-perf|audio-fix|audio-stop|debloat|restore-bloat|free-ram|telemetry|passwd}" >&2
        exit 1
        ;;
esac
