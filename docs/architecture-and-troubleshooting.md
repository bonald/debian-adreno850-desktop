# Architecture & Troubleshooting Notes

## Why Native Chroot Instead of a VM or `proot`?

1. **Direct `/dev/kgsl-3d0` GPU access (zero VM overhead):**
   Android virtualization frameworks (Gunyah / AVF) on stock Qualcomm phones generally do not expose bare-metal Adreno GPU passthrough to Linux guests, forcing software rendering (`llvmpipe`) or TCP `virgl` bridges. A native `chroot` shares the host Linux kernel directly and opens `/dev/kgsl-3d0` natively via Mesa Turnip's KGSL backend.
2. **Real glibc & native performance (zero `proot` ptrace overhead):**
   Unlike `proot` (which intercepts every syscall via `ptrace`), `chroot` runs ARM64 glibc binaries at native speed on all 8 cores (~5 GHz peak on Snapdragon 8 Elite Gen 5).
3. **Sparse `ext4` loop image (`rw,suid,dev,exec`):**
   Android's `/data` mount often enforces `nosuid`/`nodev` or Android-specific filesystem quirks. Placing Debian 13 inside a sparse `ext4` image (`/data/adb/debian-gpu.img`) mounted with `rw,suid,dev,exec,noatime` gives standard POSIX permissions, working `sudo`, and takes only ~3 GB of real disk space out of a 32 GB virtual volume.
4. **SELinux stays `Enforcing`:**
   Nothing in this setup disables SELinux. `/dev/kgsl-3d0` is already `0666` on stock Android kernels, and Termux:X11 shares its Unix socket cleanly through a bind mount at `/tmp/.X11-unix`.

---

## Why Each Key Flag / Workaround Exists

| Setting | Reason |
|---|---|
| `GPUId(chip_id=0x44051431, name="Adreno (TM) 850")` | Upstream Mesa 26.3.1 includes Adreno 840 (`0xffff44050A31`) but not yet Adreno 850 (`0x44051431`, KGSL `gen8_14_0`). Adding the `chip_id` to the Adreno 840 `A6xxGPUInfo` (`CHIP.A8XX`, `a8xx_gen2`) entry enables Turnip immediately with zero KGSL faults. |
| `-Dplatforms=x11` (when building Mesa) | Debian 13 (`trixie`) ships an older `wayland-scanner` that fails strict XML DTD validation against Mesa 26.3.1's bundled `wayland-protocols` 1.49 (`attribute frozen`). Since Termux:X11 and TigerVNC are X11-based, building Turnip with `-Dplatforms=x11` compiles cleanly without touching system Wayland packages. |
| `TU_DEBUG=noconform,noubwc` | `noconform` exposes full Vulkan 1.4 capabilities on the unofficial Adreno 850 entry. `noubwc` disables Universal Bandwidth Compression, which otherwise causes corrupted font glyphs and texture artifacts on Adreno 850 when running desktop apps over Zink. |
| `MESA_VK_WSI_DEBUG=sw` | Termux:X11's default DRI3 path stalls on uncached KGSL DMA-BUF CPU readbacks. Benchmarked on Adreno 850: `sw + noubwc` hits **430 FPS** in `glxgears` vs **284 FPS** on DRI3 (`noubwc`) and **173 FPS** on DRI3 with UBWC enabled. Keep `sw + noubwc` for Termux:X11. |
| `CHROMIUM_GPU_FLAGS` (`--enable-features=Vulkan --use-gl=angle --use-angle=vulkan`) | Without explicit Vulkan flags, Brave and Electron apps run `Skia GaneshGL → ANGLE → Mesa 25.0.7 Zink → Turnip` (3 translation layers). Switching directly to `Skia GaneshVulkan + ANGLE Vulkan 1.4` talks straight to Turnip on Adreno 850, delivering **+29%** WebGL2 shader FPS (`123.9 → 159.6 FPS`) with identical pixel output. |
| KGSL `default_pwrlevel=7` + `idle_timer=500` | Stock KGSL sets `default_pwrlevel=22` (`222 MHz` out of `1450 MHz`) and `idle_timer=80 ms`, causing Adreno 850 to nap between UI frames/scrolls and wake at 222 MHz. Raising wake level to `7` (`951 MHz`, or `0` = `1450 MHz` when docked) and `idle_timer=500 ms` lifts `glmark2` `phong` by **+24%** (`134 → 166 FPS`). |
| `PULSE_SERVER=127.0.0.1` + Termux `module-aaudio-sink` | Without a running PulseAudio/PipeWire daemon, Chromium's `AudioService` has no audio sink and HTML5 `<video>` (e.g., YouTube) hangs on a spinning circle because the audio master clock never advances. Running Termux `pulseaudio` with `module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1` and `module-aaudio-sink` streams real 48 kHz audio directly into Android `AudioFlinger`. |
| `QT_X11_NO_MITSHM=1` and `x0vncserver -UseSHM=0` | Stock Android kernels are built with `# CONFIG_SYSVIPC is not set`. Disabling MIT-SHM prevents blank windows in Qt apps and stops `x0vncserver` from failing on `shmget`. |
| No GLX `picom` compositor (`xfwm4` shadows off + `XPresent`) | Using `picom --backend glx` on Termux:X11 with `MESA_VK_WSI_DEBUG=sw` results in a black screen because `GLX_EXT_texture_from_pixmap` does not composite properly over the sw-WSI X11 bridge. `xfwm4`'s XRender compositor keeps Plank transparency working; disabling `show_frame_shadow` + `show_popup_shadow` and setting `vblank_mode=xpresent` removes CPU software shadow blending and tearing. |
| `vm.swappiness=20`, `vfs_cache_pressure=50`, loop `read_ahead_kb=512` | Keeps hot Linux desktop/browser pages in RAM instead of paging early to ZRAM (`qpace-lzq`) and improves sequential reads from `/data/adb/debian-gpu.img`. Note: `LOOP_SET_DIRECT_IO` is rejected with `EINVAL` by Android's F2FS `inlinecrypt` backing store, so standard buffered loop is required. |
| `THP defrag=defer+madvise`, `2048kB=madvise`, `64kB=always` | Stock Android sets `THP.defrag=always` across every hugepage size (`16kB`–`2048kB`), which causes synchronous direct compaction stalls (5–50 ms UI micro-stutters) whenever RAM is fragmented. Switching `defrag` to `defer+madvise` and large sizes to `madvise` removes page-fault stalls while keeping ARM64's hardware 64 KB CONT-PTE TLB coalescing (`always`) and letting `jemalloc`/V8/Mesa opt into 2 MB hugepages via `madvise`. |
| Tuned `jemalloc 5.3` (`/etc/profile.d/allocator-opt.sh`) | Benchmarked on 6 threads inside Debian 13 ARM64: tuned `jemalloc 5.3` (`background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000,metadata_thp:auto`) completes in **33.5 ms** vs **122.7 ms** for `glibc ptmalloc2` (**3.7× faster**) and **45.3 ms** for `mimalloc 3.0`, and also edges out both on Python workloads (`54.1 ms` vs `55.6 ms` / `70.5 ms`). Chromium/Electron wrappers explicitly reset `LD_PRELOAD=/usr/local/lib/libfix-zero-write.so` and `unset MALLOC_CONF` so Chromium's built-in **PartitionAlloc** stays untouched. |
| `aid_inet` (GID 3003) & `aid_net_raw` (GID 3004) | Android's `CONFIG_ANDROID_PARANOID_NETWORK` kernel feature restricts socket creation to processes in GID 3003/3004. Adding `root` and `droid` to those groups makes `apt`, `curl`, `ssh`, and browsers work normally inside the chroot. |
| `APT::Sandbox::User "root";` | Inside an Android kernel chroot, `_apt` is not in `aid_inet` (3003), causing `apt-get update` network calls to fail with `Permission denied` unless sandboxing runs as `root`. |
| `xdg-desktop-portal-gtk` + `color-scheme='prefer-dark'` | GTK4/libadwaita, Chromium, and Electron apps query the FreeDesktop portal (`org.freedesktop.appearance` `color-scheme`) rather than only reading GTK3 `settings.ini`. Autostarting `xdg-desktop-portal-gtk` with `XDG_CURRENT_DESKTOP=XFCE` and setting `gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'` makes all modern toolkits follow dark mode (for Electron/Chromium wrappers, you can also pass `--force-dark-mode`). |

---

## Troubleshooting

### Black screen in Termux:X11
- Make sure you are not running `picom --backend glx`.
- Verify Termux:X11 is running and its socket exists:
  ```sh
  su -c "/data/adb/debian-gpu.sh status"
  ls -la /data/data/com.termux/files/usr/tmp/.X11-unix/X0
  ```
- Restart cleanly:
  ```sh
  su -c "/data/adb/debian-gpu.sh stop && /data/adb/debian-gpu.sh start"
  ```

### Garbled text or corrupted window textures
- Verify `TU_DEBUG` includes `noubwc`:
  ```sh
  su -c "/data/adb/debian-gpu.sh shell"
  echo "$TU_DEBUG"   # should include noconform,noubwc
  ```

### `vulkaninfo` shows `llvmpipe` instead of `Adreno (TM) 850`
1. Confirm the Turnip ICD file exists inside the chroot:
   ```sh
   ls -la /opt/turnip-a850/share/vulkan/icd.d/freedreno_icd.aarch64.json
   ```
2. Confirm `/dev/kgsl-3d0` is visible and readable inside the chroot:
   ```sh
   ls -la /dev/kgsl-3d0
   ```
3. Check your GPU's exact KGSL chip ID if you are on a different Qualcomm SoC (see the main `README.md` section on adapting to other Adreno GPUs).

### `apt-get update` fails with network / socket permission errors
- Ensure `/etc/apt/apt.conf.d/99no-sandbox` contains `APT::Sandbox::User "root";`.
- Ensure `root` and `droid` are members of `aid_inet` (3003):
  ```sh
  id root
  id droid
  ```

### Plank dock didn't appear or looks unstyled
Run inside the chroot as `droid` with `DISPLAY=:0`:
```bash
bash /path/to/setup-macos-desktop.sh
pkill -x plank || true
nohup plank >/tmp/plank.log 2>&1 </dev/null &
```

### YouTube / HTML5 video hangs on a spinning circle, or no audio output
1. **Spinning circle (no audio sink):** Ensure Termux `pulseaudio` is installed (`pkg install pulseaudio` inside Termux) and running with `AAudio_sink`:
   ```sh
   su -c "/data/adb/debian-gpu.sh audio-fix"
   ```
   Or tap **Fix Audio Sink** in **Debian GPU v2.0**. Restart Brave if it was opened before `PULSE_SERVER=127.0.0.1` was exported.
2. **Video plays, but you hear no sound on an external monitor:** When connected via USB-C/HDMI, Android routes `STREAM_MUSIC` to `AUDIO_DEVICE_OUT_HDMI` automatically. If your monitor has no built-in speakers, switch **Media Output** to **This phone** (or Bluetooth) in Android's Control Center media card and turn up speaker media volume.

### CPU clocks capped or Geekbench scores much lower than expected
Honor MagicOS layers **four** separate throttles on non-game / Linux workloads (traced via `/sys/module/cpufreq_qos_info/parameters/freq_qos_enable`):
1. **`core_ctl` parking both 5.01 GHz Prime cores (`cpu6/core_ctl/max_cpus = 0`, `active_cpus = 0`):** Honor's `core_ctl` frequently locks both Prime cores (`cpu6`–`cpu7`) completely offline and parks Big cores (`cpu3`–`cpu5` down to 1 active core), forcing Single-Core and Multi-Core workloads onto smaller cores. **Fix (`PERF_CPU_UNLOCK=1`):** Sets `max_cpus=3/3/2`, `min_cpus=3/3/2`, and `enable=0` on clusters 3 & 6 so all 8 cores stay online.
2. **Honor Frame-Aware Scheduling (`honor_fas` → `fas_cancel_freq_limit`):** Even when `msm_performance` is unlocked, `/sys/kernel/fas/mgr/fas_enable = 1` sees Termux:X11 (`LorieRendererTh`) at 60 FPS/idle and places a kernel `freq_qos` ceiling of `2.18 / 2.42 / 2.42 GHz` across all 3 clusters for the first ~2 seconds of every CPU burst (crippling short Geekbench Single-Core workloads). **Fix (`PERF_CPU_UNLOCK=1`):** Sets `/sys/kernel/fas/mgr/fas_enable = 0`, allowing instant `4.72–5.01 GHz` Prime boost in `<0.4s` without touching `iawareperf`.
3. **`iawareperf-service` (`libqcom_wrapper.so`) & `dubaid` continuously rewriting `msm_performance/cpu_max_freq` and `core_ctl/max_cpus`:** Even with `dubaid` stopped, `vendor.honor.hardware.iawareperf-service` (via `/vendor/lib64/libqcom_wrapper.so`) silently rewrites `/sys/kernel/msm_performance/parameters/cpu_max_freq` down to `2.65 / 2.65 / 3.69 GHz` or `1.73 / 1.73 / 3.69 GHz` and resets `cpu6/core_ctl/max_cpus` to `0` mid-benchmark, while stopping `iawareperf` itself causes UI choppiness. **Fix (`guard_sysfs_node` in `debian-gpu.sh`):** Writes full unlocked values into the real kernel sysfs nodes, then bind-mounts writable tmpfs sinks (with matching SELinux contexts) over `cpu_max_freq`, `fas_enable`, `cooling_switch`, `core_ctl/{enable,min_cpus,max_cpus}`, and `kgsl/thermal_pwrlevel` in the global mount namespace (`su -M`). All vendor daemons stay running smoothly with zero errors, while Qualcomm's hardware CPUCP/LMh (`scmi_limit_notify_cb`) and kernel TSENS (`105 °C` throttle / `125 °C` critical shutdown) continue protecting the silicon directly in firmware/hardware. Toggling the switches off cleanly `umount`s every guard and restores stock behavior.
4. **Honor Launcher focus cap (`mIsLauncherFront: true`):** Leaving Honor's home launcher active on the phone screen triggers `PowerGenius` caps. Keeping **Debian GPU v2.2** open on the phone screen clears `mIsLauncherFront` while displaying live per-cluster `[active/max]` core counts and frequencies.

### USB-C to DisplayPort External Monitor Tips
- Plug in a USB-C to DisplayPort (or USB-C hub with DP/HDMI + keyboard/mouse) cable.
- Open **Termux:X11** on the external display (or switch Android desktop/mirror mode to match the monitor's native resolution).
- In **Termux:X11 Preferences**:
  - **Display resolution mode:** `native` (or `exact` at `1920x1080` / `2560x1440`)
  - **Fullscreen on device display:** On
  - **Show additional keyboard:** Off
  - **Capture external pointer when possible:** On (for hardware mouse / trackpad)
  - **Enable Accessibility service for intercepting system shortcuts:** On (so `Alt+Tab`, `Super+Space`, etc. go to Debian instead of Android)
