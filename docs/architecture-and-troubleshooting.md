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
| `MESA_VK_WSI_DEBUG=sw` | Termux:X11's default DRI3 path stalls on uncached KGSL DMA-BUF CPU readbacks. Software WSI (`sw`) transfers rendered frames over X11 SHM/PutImage and delivers roughly 2x higher on-screen FPS on Termux:X11. |
| `QT_X11_NO_MITSHM=1` and `x0vncserver -UseSHM=0` | Stock Android kernels are built with `# CONFIG_SYSVIPC is not set`. Disabling MIT-SHM prevents blank windows in Qt apps and stops `x0vncserver` from failing on `shmget`. |
| No GLX `picom` compositor | Using `picom --backend glx` on Termux:X11 with `MESA_VK_WSI_DEBUG=sw` results in a black screen because `GLX_EXT_texture_from_pixmap` does not composite properly over the sw-WSI X11 bridge. `xfwm4`'s built-in XRender compositor gives crisp window shadows, dock transparency, and zero black screens while GPU apps still render directly on Turnip + Zink. |
| `aid_inet` (GID 3003) & `aid_net_raw` (GID 3004) | Android's `CONFIG_ANDROID_PARANOID_NETWORK` kernel feature restricts socket creation to processes in GID 3003/3004. Adding `root` and `droid` to those groups makes `apt`, `curl`, `ssh`, and browsers work normally inside the chroot. |
| `APT::Sandbox::User "root";` | Inside an Android kernel chroot, `_apt` is not in `aid_inet` (3003), causing `apt-get update` network calls to fail with `Permission denied` unless sandboxing runs as `root`. |

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

### USB-C to DisplayPort External Monitor Tips
- Plug in a USB-C to DisplayPort (or USB-C hub with DP/HDMI + keyboard/mouse) cable.
- Open **Termux:X11** on the external display (or switch Android desktop/mirror mode to match the monitor's native resolution).
- In **Termux:X11 Preferences**:
  - **Display resolution mode:** `native` (or `exact` at `1920x1080` / `2560x1440`)
  - **Fullscreen on device display:** On
  - **Show additional keyboard:** Off
  - **Capture external pointer when possible:** On (for hardware mouse / trackpad)
  - **Enable Accessibility service for intercepting system shortcuts:** On (so `Alt+Tab`, `Super+Space`, etc. go to Debian instead of Android)
