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
#   su -c "/data/adb/debian-gpu.sh macos-stop"       - Stop macOS 27.2 VM & xnu_fb_view
#   su -c "/data/adb/debian-gpu.sh macos-log"        - Show recent macOS VM & XNU dmesg logs
#   su -c "/data/adb/debian-gpu.sh umount"           - Stop services/VM and unmount chroot image
#   su -c "/data/adb/debian-gpu.sh shell"            - Interactive bash shell as droid
#   su -c "/data/adb/debian-gpu.sh status"           - Show running services & remote URLs
#   su -c "/data/adb/debian-gpu.sh perf"             - Apply all enabled perf tweaks from config
#   su -c "/data/adb/debian-gpu.sh set-toggle K V"   - Persist & live-apply one toggle (0/1)
#   su -c "/data/adb/debian-gpu.sh reset-perf"       - Restore stock defaults for all toggles
#   su -c "/data/adb/debian-gpu.sh audio-fix"        - Start/repair Termux PulseAudio AAudio_sink
#   su -c "/data/adb/debian-gpu.sh telemetry"        - Machine-readable live status for Debian GPU APK
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
PERF_THP_OPT=1
PERF_JEMALLOC=1
PERF_XFCE_OPT=1
PERF_CHROMIUM_VULKAN=1
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=1
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
    PERF_THP_OPT=1
    PERF_JEMALLOC=1
    PERF_XFCE_OPT=1
    PERF_CHROMIUM_VULKAN=1
    PERF_PULSEAUDIO=1
    PERF_BOOT_PERSIST=1
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
    mountpoint -q "$MNT/mnt/android" || mount --bind /storage/emulated/0 "$MNT/mnt/android"
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

    # Keep Termux, Termux:X11, and Debian GPU Manager exempt from Doze/bg throttling
    for pkg in com.termux com.termux.x11 com.debiangpu.manager; do
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

    # 2. Adreno 850 GPU thermal unlock (0 = 1450 MHz max)
    if [ "$PERF_GPU_UNLOCK" = "1" ]; then
        guard_sysfs_node /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "0" gpu_thermal_pwrlevel
    else
        unguard_sysfs_node /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel "0"
    fi

    # 3. Adreno 850 KGSL wake level & idle timer (+24% FPS in glmark2)
    if [ "$PERF_GPU_MAX_WAKE" = "1" ]; then
        (echo 0 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 500 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
    elif [ "$PERF_GPU_RAMP" = "1" ]; then
        (echo 7 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 500 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
    else
        (echo 22 > /sys/class/kgsl/kgsl-3d0/default_pwrlevel) 2>/dev/null || true
        (echo 80 > /sys/class/kgsl/kgsl-3d0/idle_timer) 2>/dev/null || true
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
        for p in 0 3 6; do
            chmod 644 "/sys/devices/system/cpu/cpufreq/policy$p/scaling_max_freq" 2>/dev/null || true
            hw=$(cat "/sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_max_freq" 2>/dev/null || true)
            [ -n "$hw" ] && (echo "$hw" > "/sys/devices/system/cpu/cpufreq/policy$p/scaling_max_freq") 2>/dev/null || true
        done
    else
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

    # 6. Memory & chroot loop I/O tuning
    LDEV=$(get_loop_dev || true)
    if [ "$PERF_VM_IO" = "1" ]; then
        (echo 20 > /proc/sys/vm/swappiness) 2>/dev/null || true
        (echo 50 > /proc/sys/vm/vfs_cache_pressure) 2>/dev/null || true
        [ -n "$LDEV" ] && (echo 512 > "/sys/block/$LDEV/queue/read_ahead_kb") 2>/dev/null || true
    else
        (echo 60 > /proc/sys/vm/swappiness) 2>/dev/null || true
        (echo 100 > /proc/sys/vm/vfs_cache_pressure) 2>/dev/null || true
        [ -n "$LDEV" ] && (echo 128 > "/sys/block/$LDEV/queue/read_ahead_kb") 2>/dev/null || true
    fi

    # 7. Transparent Huge Pages defrag stutter fix (keep ARM64 64KB CONT-PTE always)
    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
        if [ "$PERF_THP_OPT" = "1" ]; then
            (echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag) 2>/dev/null || true
            (echo madvise > /sys/kernel/mm/transparent_hugepage/enabled) 2>/dev/null || true
            for sz in 128kB 256kB 512kB 1024kB 2048kB; do
                (echo madvise > "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/enabled") 2>/dev/null || true
            done
            (echo always > /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled) 2>/dev/null || true
        else
            (echo always > /sys/kernel/mm/transparent_hugepage/defrag) 2>/dev/null || true
            (echo always > /sys/kernel/mm/transparent_hugepage/enabled) 2>/dev/null || true
            for sz in 64kB 128kB 256kB 512kB 1024kB 2048kB; do
                (echo always > "/sys/kernel/mm/transparent_hugepage/hugepages-$sz/enabled") 2>/dev/null || true
            done
        fi
    fi

    # 8. Sync chroot configs & boot persistence
    apply_chromium_flags
    apply_allocator_opt
    apply_xfce_tweaks
    sync_boot_script
}

start_pulseaudio() {
    load_conf
    [ "$PERF_PULSEAUDIO" = "1" ] || return 0
    su "$TUID" -g 3003 -c "
        export PREFIX=$TPREFIX HOME=$THOME TMPDIR=$TPREFIX/tmp PATH=$TPREFIX/bin:/system/bin PULSE_SERVER=127.0.0.1
        if ! pgrep -x pulseaudio >/dev/null 2>&1; then
            pulseaudio --start --load='module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1' --exit-idle-time=-1 >/dev/null 2>&1 || true
            sleep 0.5
        fi
        if ! pactl list short sinks 2>/dev/null | grep -qiE 'AAudio_sink|OpenSL'; then
            pactl load-module module-aaudio-sink >/dev/null 2>&1 || pactl load-module module-sles-sink >/dev/null 2>&1 || true
            sleep 0.2
        fi
        SINK=\$(pactl list short sinks 2>/dev/null | awk '/AAudio_sink|OpenSL/{print \$2; exit}')
        if [ -n \"\$SINK\" ]; then
            pactl set-default-sink \"\$SINK\" >/dev/null 2>&1 || true
            pactl set-sink-mute \"\$SINK\" 0 >/dev/null 2>&1 || true
            pactl set-sink-volume \"\$SINK\" 100% >/dev/null 2>&1 || true
            for idx in \$(pactl list short sink-inputs 2>/dev/null | awk '{print \$1}'); do
                pactl move-sink-input \"\$idx\" \"\$SINK\" >/dev/null 2>&1 || true
            done
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
        PERF_HONOR_MODE|PERF_GPU_UNLOCK|PERF_GPU_RAMP|PERF_GPU_MAX_WAKE|PERF_CPU_UNLOCK|PERF_THERMAL_DOCKED|PERF_WALT_BURST|PERF_WALT_PRIME_BIAS|PERF_VM_IO|PERF_THP_OPT|PERF_JEMALLOC|PERF_XFCE_OPT|PERF_CHROMIUM_VULKAN|PERF_PULSEAUDIO|PERF_BOOT_PERSIST)
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
    cat > "$CONF" <<'EOF'
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
PERF_THP_OPT=0
PERF_JEMALLOC=0
PERF_XFCE_OPT=0
PERF_CHROMIUM_VULKAN=0
PERF_PULSEAUDIO=1
PERF_BOOT_PERSIST=0
EOF
    chmod 644 "$CONF"
    apply_perf_tweaks
    echo "Restored stock defaults."
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
                 xfce4-session xfwm4 xfce4-panel xfdesktop xfsettingsd xfconfd plank; do
            pkill -9 -x "$p" 2>/dev/null || true
        done
        pkill -9 -f "[w]ebsockify.*6080" 2>/dev/null || true
        pkill -9 -f "[d]bus-run-session -- (i3|startxfce4)" 2>/dev/null || true
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

do_macos_stop() {
    pkill -TERM -x xnu_fb_view 2>/dev/null || true
    pkill -TERM -f "[r]un-xnulinux-vm.sh" 2>/dev/null || true
    pkill -TERM -x crosvm 2>/dev/null || true
    i=0
    while (pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1) && [ "$i" -lt 10 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    pkill -KILL -x xnu_fb_view 2>/dev/null || true
    pkill -KILL -f "[r]un-xnulinux-vm.sh" 2>/dev/null || true
    pkill -KILL -x crosvm 2>/dev/null || true
    if [ -r /sys/power/wake_lock ] && [ -w /sys/power/wake_unlock ]; then
        for wl in $(tr ' ' '\n' < /sys/power/wake_lock 2>/dev/null | grep '^xnulinux_vm_' || true); do
            echo "$wl" > /sys/power/wake_unlock 2>/dev/null || true
        done
    fi
    echo "macOS 27 VM stopped."
}

do_macos_start() {
    if [ ! -x "$MACOS_SCRIPT" ]; then
        echo "Error: $MACOS_SCRIPT not found or not executable." >&2
        exit 1
    fi
    do_mount
    ensure_macos_bind
    apply_perf_tweaks
    start_termux_x11

    # Free Termux:X11 (:0) and RAM by stopping Debian desktop & any prior VM instance
    if pgrep -x xfwm4 >/dev/null 2>&1 || pgrep -x plank >/dev/null 2>&1 || pgrep -x x0vncserver >/dev/null 2>&1; then
        echo "Stopping Debian XFCE4 desktop before starting macOS 27..."
        kill_desktop_procs
    fi
    if pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -f "[r]un-xnulinux-vm.sh" >/dev/null 2>&1; then
        do_macos_stop >/dev/null 2>&1 || true
    fi
    sleep 0.5

    # Reset XNU dmesg log so readiness reflects this boot
    : > "$MACOS_DIR/xnu-dmesg.log" 2>/dev/null || true
    : > "$MACOS_LOG" 2>/dev/null || true

    FB_W="${FB_WIDTH:-1920}"
    FB_H="${FB_HEIGHT:-1080}"

    # Launch zero-copy X11 framebuffer viewer inside chroot as root (needs /proc/<crosvm>/fd access)
    if [ -x "$MNT/usr/local/bin/xnu_fb_view" ]; then
        setsid chroot "$MNT" /usr/bin/env -i \
            DISPLAY=:0 \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/bin/xnu_fb_view --fullscreen --size "${FB_W}x${FB_H}" \
            >"$MNT$MACOS_VIEW_LOG" 2>&1 </dev/null &
        sleep 0.5
    else
        echo "Warning: $MNT/usr/local/bin/xnu_fb_view not found."
    fi

    # Launch Gunyah + Adreno 850 Venus macOS 27.2 VM detached from caller stdio
    setsid sh "$MACOS_SCRIPT" >"$MACOS_LOG" 2>&1 </dev/null &

    # Wait up to 8s for crosvm to come up
    i=0
    while ! pgrep -x crosvm >/dev/null 2>&1 && [ "$i" -lt 16 ]; do
        sleep 0.5
        i=$((i + 1))
    done

    # Promote viewer & Termux:X11 into Android top-app scheduling group
    for p in $(pidof xnu_fb_view termux-x11 2>/dev/null); do
        [ -w /dev/cpuset/top-app/cgroup.procs ] && echo "$p" > /dev/cpuset/top-app/cgroup.procs 2>/dev/null || true
        [ -w /dev/cpuctl/top-app/cgroup.procs ] && echo "$p" > /dev/cpuctl/top-app/cgroup.procs 2>/dev/null || true
    done

    VM_PID=$(pgrep -o -x crosvm 2>/dev/null || true)
    VIEW_PID=$(pgrep -o -x xnu_fb_view 2>/dev/null || true)
    if [ -n "$VM_PID" ]; then
        echo "macOS 27.2 VM booting on Gunyah (Adreno 850 Venus, ${FB_W}x${FB_H})"
        echo "crosvm PID: $VM_PID | xnu_fb_view PID: ${VIEW_PID:-none}"
        echo "Log: $MACOS_LOG"
        echo "Display appears in Termux:X11 automatically once XNU completes first swap (~90s)."
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

do_start() {
    do_mount
    if pgrep -x crosvm >/dev/null 2>&1 || pgrep -x xnu_fb_view >/dev/null 2>&1 || pgrep -f "[r]un-xnulinux-vm.sh" >/dev/null 2>&1; then
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
    pgrep -x xfwm4 >/dev/null 2>&1 && echo "DESKTOP=1" || echo "DESKTOP=0"
    pgrep -x plank >/dev/null 2>&1 && echo "PLANK=1" || echo "PLANK=0"
    [ -x "$MACOS_SCRIPT" ] && echo "MACOS_AVAIL=1" || echo "MACOS_AVAIL=0"
    if pgrep -x crosvm >/dev/null 2>&1; then
        echo "MACOS_VM=1"
        grep -q "XnuDisplay: first swap submitted" "$MACOS_DIR/xnu-dmesg.log" 2>/dev/null && echo "MACOS_READY=1" || echo "MACOS_READY=0"
    else
        echo "MACOS_VM=0"
        echo "MACOS_READY=0"
    fi
    pgrep -x xnu_fb_view >/dev/null 2>&1 && echo "MACOS_VIEW=1" || echo "MACOS_VIEW=0"
    (pgrep -x x0vncserver >/dev/null 2>&1 || pgrep -x X0tigervnc >/dev/null 2>&1) && echo "VNC=1" || echo "VNC=0"
    pgrep -f 'websockify.*6080' >/dev/null 2>&1 && echo "NOVNC=1" || echo "NOVNC=0"
    if pgrep -x pulseaudio >/dev/null 2>&1; then
        SINKS=$(su "$TUID" -g 3003 -c "export PREFIX=$TPREFIX PATH=$TPREFIX/bin:/system/bin PULSE_SERVER=127.0.0.1; pactl list short sinks 2>/dev/null" 2>/dev/null || true)
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
    echo "PERF_THP_OPT=$PERF_THP_OPT"
    echo "PERF_JEMALLOC=$PERF_JEMALLOC"
    echo "PERF_XFCE_OPT=$PERF_XFCE_OPT"
    echo "PERF_CHROMIUM_VULKAN=$PERF_CHROMIUM_VULKAN"
    echo "PERF_PULSEAUDIO=$PERF_PULSEAUDIO"
    echo "PERF_BOOT_PERSIST=$PERF_BOOT_PERSIST"
}

case "${1:-status}" in
    start)       do_start ;;
    stop)        do_stop ;;
    macos-start) do_macos_start ;;
    macos-stop)  do_macos_stop ;;
    macos-log)   do_macos_log ;;
    umount)      do_umount ;;
    status)      do_status ;;
    vnc)         do_vnc ;;
    perf)        apply_perf_tweaks; echo "Perf tweaks applied." ;;
    boot-apply)  apply_perf_tweaks ;;
    set-toggle)  do_set_toggle "${2:-}" "${3:-}" ;;
    reset-perf)  do_reset_perf ;;
    audio-fix)   PERF_PULSEAUDIO=1; start_pulseaudio; echo "PulseAudio AAudio_sink ready." ;;
    audio-stop)  stop_pulseaudio; echo "PulseAudio stopped." ;;
    telemetry)   do_telemetry ;;
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
        echo "Usage: $0 {start|stop|macos-start|macos-stop|macos-log|umount|shell|status|vnc|perf|set-toggle|reset-perf|audio-fix|audio-stop|telemetry|passwd}" >&2
        exit 1
        ;;
esac
