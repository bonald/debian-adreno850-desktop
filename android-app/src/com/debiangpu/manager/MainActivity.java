package com.debiangpu.manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    private static final int COL_BG = Color.parseColor("#0F1117");
    private static final int COL_CARD = Color.parseColor("#181B24");
    private static final int COL_CARD_BORDER = Color.parseColor("#2A2F42");
    private static final int COL_TEXT = Color.parseColor("#E6E9F2");
    private static final int COL_MUTED = Color.parseColor("#8B92A8");
    private static final int COL_BLUE = Color.parseColor("#3B82F6");
    private static final int COL_CYAN = Color.parseColor("#0EA5E9");
    private static final int COL_GREEN = Color.parseColor("#22C55E");
    private static final int COL_RED = Color.parseColor("#EF4444");
    private static final int COL_AMBER = Color.parseColor("#F59E0B");
    private static final int COL_PURPLE = Color.parseColor("#8B5CF6");
    private static final int COL_SURFACE_BTN = Color.parseColor("#242938");
    private static final int COL_CONSOLE_BG = Color.parseColor("#0B0D12");
    private static final int COL_BAR_TRACK = Color.parseColor("#11141D");

    private static final long LIVE_POLL_MS = 2500L;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());

    // Header
    private Button btnLiveToggle;
    private volatile boolean liveEnabled = true;

    // Live telemetry views
    private MeterRow meterCpu0, meterCpu3, meterCpu6, meterGpu;
    private TextView tvGpuDetail, tvThermalsLine, tvPowerLine, tvMemLine, tvLauncherWarn;

    // System status badges
    private TextView badgeRoot, badgeMount, badgeX11, badgeDesktop, badgeMacos, badgeAudio, badgeVnc, badgeBrowserGpu, badgeAllocator;
    private TextView tvNoVncUrl, tvVncAddr, tvDiskInfo, tvConsole, tvBusyStatus;
    private ScrollView consoleScroll;

    // Persistent perf switches
    private final Map<String, Switch> toggleSwitches = new HashMap<>();
    private boolean updatingSwitches = false;

    private volatile String currentTailscaleIp = "";
    private volatile boolean busy = false;
    private volatile boolean refreshing = false;

    private final Runnable livePollRunnable = new Runnable() {
        @Override
        public void run() {
            if (liveEnabled && !busy && !refreshing) {
                refreshStatus(true);
            }
            if (liveEnabled) {
                ui.postDelayed(this, LIVE_POLL_MS);
            }
        }
    };

    private static class MeterRow {
        TextView tvValue;
        View fillView;
        View restView;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());
        refreshStatus(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        ui.removeCallbacks(livePollRunnable);
        if (!busy) {
            refreshStatus(true);
        }
        if (liveEnabled) {
            ui.postDelayed(livePollRunnable, LIVE_POLL_MS);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        ui.removeCallbacks(livePollRunnable);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        ui.removeCallbacks(livePollRunnable);
        executor.shutdownNow();
    }

    private int dp(int v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private GradientDrawable rounded(int fillColor, int strokeColor, int radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fillColor);
        d.setCornerRadius(dp(radiusDp));
        if (strokeColor != 0) {
            d.setStroke(dp(1), strokeColor);
        }
        return d;
    }

    private View buildUi() {
        ScrollView rootScroll = new ScrollView(this);
        rootScroll.setBackgroundColor(COL_BG);
        rootScroll.setFillViewport(true);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        final int padH = dp(14), padTop = dp(14), padBot = dp(28);
        root.setPadding(padH, padTop, padH, padBot);
        rootScroll.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            root.setPadding(padH + bars.left, padTop + bars.top, padH + bars.right, padBot + bars.bottom);
            return insets;
        });
        rootScroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // --- Header ---
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(dp(4), dp(6), dp(4), dp(14));

        LinearLayout titleBox = new LinearLayout(this);
        titleBox.setOrientation(LinearLayout.VERTICAL);

        LinearLayout titleLine = new LinearLayout(this);
        titleLine.setOrientation(LinearLayout.HORIZONTAL);
        titleLine.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("Debian GPU");
        title.setTextColor(COL_TEXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        titleLine.addView(title);

        TextView verPill = new TextView(this);
        verPill.setText("v2.4");
        verPill.setTextColor(Color.parseColor("#7DCFFF"));
        verPill.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        verPill.setTypeface(Typeface.DEFAULT_BOLD);
        verPill.setPadding(dp(7), dp(2), dp(7), dp(2));
        verPill.setBackground(rounded(Color.parseColor("#142838"), 0, 10));
        LinearLayout.LayoutParams verLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        verLp.leftMargin = dp(8);
        titleLine.addView(verPill, verLp);
        titleBox.addView(titleLine);

        TextView subtitle = new TextView(this);
        subtitle.setText("Adreno 850 Turnip (Mesa 27.0) · Vulkan 1.4");
        subtitle.setTextColor(COL_MUTED);
        subtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        titleBox.addView(subtitle);
        header.addView(titleBox, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        btnLiveToggle = makeButton("Live", Color.parseColor("#143322"), Color.parseColor("#4ADE80"), true);
        btnLiveToggle.setOnClickListener(v -> toggleLivePolling());
        LinearLayout.LayoutParams liveLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36));
        liveLp.rightMargin = dp(6);
        header.addView(btnLiveToggle, liveLp);

        Button btnRefresh = makeButton("Refresh", COL_SURFACE_BTN, COL_TEXT, false);
        btnRefresh.setOnClickListener(v -> refreshStatus(false));
        header.addView(btnRefresh, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(36)));
        root.addView(header);

        // --- Live CPU / GPU / Thermal Telemetry Card ---
        LinearLayout teleCard = makeCard("LIVE CPU / GPU / THERMAL TELEMETRY");
        meterCpu0 = addMeterRow(teleCard, "CPU Little (0-2)", COL_BLUE);
        meterCpu3 = addMeterRow(teleCard, "CPU Big (3-5)", COL_CYAN);
        meterCpu6 = addMeterRow(teleCard, "CPU Prime (6-7)", COL_PURPLE);
        meterGpu = addMeterRow(teleCard, "Adreno 850 GPU", COL_GREEN);

        tvGpuDetail = makeInfoLine(teleCard, "KGSL: —", COL_MUTED, 11, true);
        tvThermalsLine = makeInfoLine(teleCard, "Temps: —", Color.parseColor("#A9B1D6"), 12, true);
        tvPowerLine = makeInfoLine(teleCard, "Power: —", COL_MUTED, 11, true);
        tvMemLine = makeInfoLine(teleCard, "Memory: —", COL_MUTED, 11, true);

        tvLauncherWarn = new TextView(this);
        tvLauncherWarn.setText("Honor Launcher is active on phone screen — PowerGenius caps CPU to ~2.4 GHz until another app is open on phone.");
        tvLauncherWarn.setTextColor(Color.parseColor("#FBBF24"));
        tvLauncherWarn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tvLauncherWarn.setBackground(rounded(Color.parseColor("#332914"), Color.parseColor("#664D1A"), 8));
        tvLauncherWarn.setPadding(dp(10), dp(7), dp(10), dp(7));
        LinearLayout.LayoutParams warnLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        warnLp.topMargin = dp(8);
        tvLauncherWarn.setVisibility(View.GONE);
        teleCard.addView(tvLauncherWarn, warnLp);
        root.addView(teleCard);

        // --- Live Status Card ---
        LinearLayout statusCard = makeCard("SYSTEM STATUS");
        badgeRoot = addStatusRow(statusCard, "Root (KernelSU)");
        badgeRoot.setOnClickListener(v -> {
            Intent ksu = getPackageManager().getLaunchIntentForPackage("me.weishu.kernelsu");
            if (ksu != null) {
                startActivity(ksu);
            } else {
                Toast.makeText(this, "Grant root to Debian GPU in KernelSU Manager", Toast.LENGTH_LONG).show();
            }
        });
        badgeMount = addStatusRow(statusCard, "Debian 13 Chroot");
        badgeX11 = addStatusRow(statusCard, "Termux:X11 (:0)");
        badgeDesktop = addStatusRow(statusCard, "Desktop (XFCE4 + Plank)");
        badgeMacos = addStatusRow(statusCard, "macOS 27.2 VM (Gunyah)");
        badgeAudio = addStatusRow(statusCard, "PulseAudio (AAudio :4713)");
        badgeVnc = addStatusRow(statusCard, "Remote X (VNC + noVNC)");
        badgeBrowserGpu = addStatusRow(statusCard, "Brave / Electron GPU");
        badgeAllocator = addStatusRow(statusCard, "Desktop Allocator");

        tvDiskInfo = makeInfoLine(statusCard, "Image: /data/adb/debian-gpu.img", COL_MUTED, 11, false);
        root.addView(statusCard);

        // --- Desktop Controls Card ---
        LinearLayout ctrlCard = makeCard("DESKTOP CONTROLS");

        LinearLayout row1 = makeRow();
        Button btnStart = makeButton("Start Desktop", COL_GREEN, Color.parseColor("#062010"), true);
        btnStart.setOnClickListener(v -> runRootAction("Starting Debian GPU desktop...",
                "/data/adb/debian-gpu.sh start", true));
        Button btnOpen = makeButton("Open Display", COL_BLUE, Color.WHITE, true);
        btnOpen.setOnClickListener(v -> openTermuxX11());
        addWeighted(row1, btnStart, 0, dp(5));
        addWeighted(row1, btnOpen, dp(5), 0);
        ctrlCard.addView(row1);

        LinearLayout rowMacos = makeRow();
        rowMacos.setPadding(0, dp(8), 0, 0);
        Button btnStartMacos = makeButton("Start macOS 27", Color.parseColor("#6366F1"), Color.WHITE, true);
        btnStartMacos.setOnClickListener(v -> runRootAction("Starting macOS 27.2 VM (Gunyah + Venus)...",
                "/data/adb/debian-gpu.sh macos-start", true));
        Button btnStopMacos = makeButton("Stop macOS", Color.parseColor("#3B1B22"),
                Color.parseColor("#FCA5A5"), false);
        btnStopMacos.setOnClickListener(v -> runRootAction("Stopping macOS 27.2 VM...",
                "/data/adb/debian-gpu.sh macos-stop", false));
        addWeighted(rowMacos, btnStartMacos, 0, dp(5));
        addWeighted(rowMacos, btnStopMacos, dp(5), 0);
        ctrlCard.addView(rowMacos);

        LinearLayout row2 = makeRow();
        row2.setPadding(0, dp(8), 0, 0);
        Button btnStop = makeButton("Stop Desktop", COL_SURFACE_BTN, COL_TEXT, false);
        btnStop.setOnClickListener(v -> runRootAction("Stopping desktop & VNC...",
                "/data/adb/debian-gpu.sh stop", false));
        Button btnUmount = makeButton("Unmount Image", Color.parseColor("#3B1B22"),
                Color.parseColor("#FCA5A5"), false);
        btnUmount.setOnClickListener(v -> runRootAction("Stopping & unmounting ext4 image...",
                "/data/adb/debian-gpu.sh umount", false));
        addWeighted(row2, btnStop, 0, dp(5));
        addWeighted(row2, btnUmount, dp(5), 0);
        ctrlCard.addView(row2);

        LinearLayout row3 = makeRow();
        row3.setPadding(0, dp(8), 0, 0);
        Button btnApplyPerf = makeButton("Apply Perf Now", COL_PURPLE, Color.WHITE, true);
        btnApplyPerf.setOnClickListener(v -> runRootAction("Applying persistent performance tweaks...",
                "/data/adb/debian-gpu.sh perf", false));
        Button btnFixAudio = makeButton("Fix Audio Sink", Color.parseColor("#133040"),
                Color.parseColor("#7DCFFF"), true);
        btnFixAudio.setOnClickListener(v -> runRootAction("Repairing Termux PulseAudio AAudio_sink...",
                "/data/adb/debian-gpu.sh audio-fix", false));
        addWeighted(row3, btnApplyPerf, 0, dp(5));
        addWeighted(row3, btnFixAudio, dp(5), 0);
        ctrlCard.addView(row3);
        root.addView(ctrlCard);

        // --- Persistent Performance & GPU Tweaks Card ---
        LinearLayout perfCard = makeCard("PERFORMANCE & GPU TWEAKS (PERSISTENT)");
        addToggleRow(perfCard, "PERF_HONOR_MODE", "Honor Performance Mode",
                "Sets SmartModeStatus=4 and exempts Termux:X11 from background limits");
        addToggleRow(perfCard, "PERF_GPU_UNLOCK", "Unlock Adreno 850 Max Clock",
                "Sets KGSL thermal_pwrlevel=0 (full 1450 MHz ceiling)");
        addToggleRow(perfCard, "PERF_GPU_RAMP", "GPU Fast Ramp (+24% FPS)",
                "Wake at 951 MHz (pwrlevel 7) + 500ms idle timer (prevents 222 MHz drops)");
        addToggleRow(perfCard, "PERF_GPU_MAX_WAKE", "GPU Max Wake (Docked)",
                "Wake directly at 1450 MHz (pwrlevel 0) for zero ramp lag when plugged in");
        addToggleRow(perfCard, "PERF_CPU_UNLOCK", "Unlock 8 Cores & Disable FAS Cap",
                "Keeps all 8 cores active (core_ctl), disables honor_fas 2.4 GHz clamp, 5.01 GHz max");
        addToggleRow(perfCard, "PERF_THERMAL_DOCKED", "Docked Thermal Mode (No 40°C Cap)",
                "Pauses dubaid & skin cooling_switch (keeps iawareperf UI boost & HW 105°C LMh safe)");
        addToggleRow(perfCard, "PERF_WALT_BURST", "WALT CPU Burst Tuning",
                "hispeed_load=70, predictive load (pl=1), higher hispeed freqs (2.19/2.65/3.57 GHz)");
        addToggleRow(perfCard, "PERF_WALT_PRIME_BIAS", "WALT Prime-Bias (5.01 GHz Migrate)",
                "Lowers cluster0/1 upmigrate (95->40/45%) + asymcap_boost for faster 1C/UI bursts");
        addToggleRow(perfCard, "PERF_VM_IO", "RAM & Chroot Disk I/O Tuning",
                "vm.swappiness=20, vfs_cache_pressure=50, loop read-ahead 512 KB");
        addToggleRow(perfCard, "PERF_THP_OPT", "THP Defrag Fix (ARM64 64K)",
                "defrag=defer+madvise, 2MB=madvise, 64KB CONT-PTE=always (no compaction stalls)");
        addToggleRow(perfCard, "PERF_JEMALLOC", "jemalloc 5.3 Allocator (3.7x Faster)",
                "Tuned jemalloc for XFCE/Mesa/shells (auto-excluded from Chromium PartitionAlloc)");
        addToggleRow(perfCard, "PERF_XFCE_OPT", "XFCE4 No Shadows + XPresent",
                "Disables CPU XRender frame/popup shadows & enables smooth XPresent sync");
        addToggleRow(perfCard, "PERF_CHROMIUM_VULKAN", "Native Vulkan (Brave / Electron)",
                "Skia GaneshVulkan + ANGLE Vulkan directly on Turnip Mesa 27.0 (+29% WebGL)");
        addToggleRow(perfCard, "PERF_PULSEAUDIO", "PulseAudio Bridge (AAudio :4713)",
                "Auto-starts Android audio bridge for YouTube & Linux apps");
        addToggleRow(perfCard, "PERF_BOOT_PERSIST", "Auto-Apply on Reboot (service.d)",
                "Installs KernelSU boot hook to re-apply enabled sysfs tweaks on startup");

        Button btnResetPerf = makeButton("Restore Stock Defaults", Color.parseColor("#2A2226"),
                Color.parseColor("#FCA5A5"), false);
        LinearLayout.LayoutParams resetLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        resetLp.topMargin = dp(10);
        btnResetPerf.setOnClickListener(v -> confirmResetPerf());
        perfCard.addView(btnResetPerf, resetLp);
        root.addView(perfCard);

        // --- Remote X Access Card ---
        LinearLayout remoteCard = makeCard("REMOTE X (TAILSCALE ONLY)");

        tvNoVncUrl = new TextView(this);
        tvNoVncUrl.setTextColor(Color.parseColor("#7DCFFF"));
        tvNoVncUrl.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvNoVncUrl.setTypeface(Typeface.MONOSPACE);
        tvNoVncUrl.setText("noVNC: —");
        remoteCard.addView(tvNoVncUrl);

        tvVncAddr = new TextView(this);
        tvVncAddr.setTextColor(COL_MUTED);
        tvVncAddr.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvVncAddr.setTypeface(Typeface.MONOSPACE);
        tvVncAddr.setPadding(0, dp(3), 0, dp(10));
        tvVncAddr.setText("VNC:   —");
        remoteCard.addView(tvVncAddr);

        LinearLayout rRow1 = makeRow();
        Button btnCopyWeb = makeButton("Copy noVNC", COL_SURFACE_BTN, COL_TEXT, false);
        btnCopyWeb.setOnClickListener(v -> {
            String ip = TextUtils.isEmpty(currentTailscaleIp) ? "127.0.0.1" : currentTailscaleIp;
            copyText("noVNC URL", "http://" + ip + ":6080/vnc.html");
        });
        Button btnCopyVnc = makeButton("Copy VNC", COL_SURFACE_BTN, COL_TEXT, false);
        btnCopyVnc.setOnClickListener(v -> {
            String ip = TextUtils.isEmpty(currentTailscaleIp) ? "127.0.0.1" : currentTailscaleIp;
            copyText("VNC Address", ip + ":5900");
        });
        Button btnOpenWeb = makeButton("Open Web", COL_PURPLE, Color.WHITE, false);
        btnOpenWeb.setOnClickListener(v -> {
            String ip = TextUtils.isEmpty(currentTailscaleIp) ? "127.0.0.1" : currentTailscaleIp;
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("http://" + ip + ":6080/vnc.html")));
        });
        addWeighted(rRow1, btnCopyWeb, 0, dp(4));
        addWeighted(rRow1, btnCopyVnc, dp(4), dp(4));
        addWeighted(rRow1, btnOpenWeb, dp(4), 0);
        remoteCard.addView(rRow1);

        Button btnPasswd = makeButton("Change VNC Password", COL_SURFACE_BTN, COL_TEXT, false);
        LinearLayout.LayoutParams passLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        passLp.topMargin = dp(8);
        btnPasswd.setOnClickListener(v -> showVncPasswordDialog());
        remoteCard.addView(btnPasswd, passLp);
        root.addView(remoteCard);

        // --- Quick Tools Card ---
        LinearLayout toolsCard = makeCard("QUICK TOOLS");
        LinearLayout tRow1 = makeRow();
        Button btnTerm = makeButton("Launch Terminal", COL_SURFACE_BTN, COL_TEXT, false);
        btnTerm.setOnClickListener(v -> runRootAction("Opening terminal on DISPLAY=:0...",
                "chroot /data/local/debian-gpu /bin/su - droid -c '. /etc/profile.d/turnip-a850.sh && nohup xfce4-terminal >/dev/null 2>&1 </dev/null &'",
                true));
        Button btnBrave = makeButton("Launch Brave", COL_SURFACE_BTN, COL_TEXT, false);
        btnBrave.setOnClickListener(v -> runRootAction("Opening Brave (Vulkan) on DISPLAY=:0...",
                "chroot /data/local/debian-gpu /bin/su - droid -c '. /etc/profile.d/turnip-a850.sh && nohup /usr/local/bin/brave-browser-stable >/tmp/brave.log 2>&1 </dev/null &'",
                true));
        addWeighted(tRow1, btnTerm, 0, dp(5));
        addWeighted(tRow1, btnBrave, dp(5), 0);
        toolsCard.addView(tRow1);

        LinearLayout tRow2 = makeRow();
        tRow2.setPadding(0, dp(8), 0, 0);
        Button btnGpuCheck = makeButton("Verify GPU", COL_SURFACE_BTN, COL_TEXT, false);
        btnGpuCheck.setOnClickListener(v -> runRootAction("Probing Adreno 850 Turnip + Zink...",
                "chroot /data/local/debian-gpu /bin/su - droid -c '. /etc/profile.d/turnip-a850.sh && vulkaninfo --summary 2>&1 | grep -E \"apiVersion|deviceName|driverName|driverInfo\" && echo \"---\" && glxinfo -B 2>&1 | grep -E \"Accelerated|renderer string|core profile version\"'",
                false));
        Button btnRestartVnc = makeButton("Restart VNC", COL_SURFACE_BTN, COL_TEXT, false);
        btnRestartVnc.setOnClickListener(v -> runRootAction("Restarting VNC + Tailscale proxy...",
                "/data/adb/debian-gpu.sh vnc", false));
        addWeighted(tRow2, btnGpuCheck, 0, dp(5));
        addWeighted(tRow2, btnRestartVnc, dp(5), 0);
        toolsCard.addView(tRow2);

        LinearLayout tRow3 = makeRow();
        tRow3.setPadding(0, dp(8), 0, 0);
        Button btnMacosLog = makeButton("macOS Log", COL_SURFACE_BTN, Color.parseColor("#C7D2FE"), false);
        btnMacosLog.setOnClickListener(v -> runRootAction("Reading macOS VM & XNU dmesg log...",
                "/data/adb/debian-gpu.sh macos-log", false));
        Button btnAudioFix = makeButton("Fix AVF Audio", COL_SURFACE_BTN, COL_MUTED, false);
        btnAudioFix.setOnClickListener(v -> runRootAction("Applying crosvm_vu_snd SELinux audio rules...",
                "/data/adb/fix-terminal.sh", false));
        addWeighted(tRow3, btnMacosLog, 0, dp(5));
        addWeighted(tRow3, btnAudioFix, dp(5), 0);
        toolsCard.addView(tRow3);
        root.addView(toolsCard);

        // --- Console Output Card ---
        LinearLayout logCard = makeCard("CONSOLE OUTPUT");
        LinearLayout logTop = makeRow();
        logTop.setGravity(Gravity.CENTER_VERTICAL);
        logTop.setPadding(0, 0, 0, dp(6));

        tvBusyStatus = new TextView(this);
        tvBusyStatus.setTextColor(COL_GREEN);
        tvBusyStatus.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvBusyStatus.setText("Idle");
        logTop.addView(tvBusyStatus, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button btnClear = makeButton("Clear", COL_SURFACE_BTN, COL_MUTED, false);
        btnClear.setOnClickListener(v -> tvConsole.setText(""));
        logTop.addView(btnClear, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(30)));
        logCard.addView(logTop);

        consoleScroll = new ScrollView(this);
        consoleScroll.setBackground(rounded(COL_CONSOLE_BG, COL_CARD_BORDER, 10));
        consoleScroll.setPadding(dp(10), dp(10), dp(10), dp(10));
        tvConsole = new TextView(this);
        tvConsole.setTextColor(Color.parseColor("#A9B1D6"));
        tvConsole.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tvConsole.setTypeface(Typeface.MONOSPACE);
        tvConsole.setTextIsSelectable(true);
        tvConsole.setText("Ready.\n");
        consoleScroll.addView(tvConsole);
        logCard.addView(consoleScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(160)));
        root.addView(logCard);

        return rootScroll;
    }

    private void toggleLivePolling() {
        liveEnabled = !liveEnabled;
        ui.removeCallbacks(livePollRunnable);
        if (liveEnabled) {
            btnLiveToggle.setText("Live");
            btnLiveToggle.setTextColor(Color.parseColor("#4ADE80"));
            btnLiveToggle.setBackground(rounded(Color.parseColor("#143322"), 0, 10));
            ui.postDelayed(livePollRunnable, LIVE_POLL_MS);
            refreshStatus(true);
        } else {
            btnLiveToggle.setText("Paused");
            btnLiveToggle.setTextColor(COL_MUTED);
            btnLiveToggle.setBackground(rounded(COL_SURFACE_BTN, 0, 10));
        }
    }

    private LinearLayout makeCard(String headerTitle) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(rounded(COL_CARD, COL_CARD_BORDER, 14));
        card.setPadding(dp(14), dp(13), dp(14), dp(13));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(12);
        card.setLayoutParams(lp);

        TextView tv = new TextView(this);
        tv.setText(headerTitle);
        tv.setTextColor(COL_MUTED);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tv.setTypeface(Typeface.DEFAULT_BOLD);
        tv.setLetterSpacing(0.08f);
        tv.setPadding(0, 0, 0, dp(8));
        card.addView(tv);
        return card;
    }

    private TextView makeInfoLine(LinearLayout parent, String text, int color, int sp, boolean mono) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextColor(color);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        if (mono) tv.setTypeface(Typeface.MONOSPACE);
        tv.setPadding(0, dp(4), 0, 0);
        parent.addView(tv);
        return tv;
    }

    private MeterRow addMeterRow(LinearLayout parent, String label, int barColor) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(0, dp(3), 0, dp(6));

        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setGravity(Gravity.CENTER_VERTICAL);

        TextView tvLabel = new TextView(this);
        tvLabel.setText(label);
        tvLabel.setTextColor(COL_TEXT);
        tvLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvLabel.setTypeface(Typeface.DEFAULT_BOLD);
        top.addView(tvLabel, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView tvVal = new TextView(this);
        tvVal.setText("—");
        tvVal.setTextColor(Color.parseColor("#A9B1D6"));
        tvVal.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tvVal.setTypeface(Typeface.MONOSPACE);
        top.addView(tvVal);
        box.addView(top);

        LinearLayout barTrack = new LinearLayout(this);
        barTrack.setOrientation(LinearLayout.HORIZONTAL);
        barTrack.setBackground(rounded(COL_BAR_TRACK, COL_CARD_BORDER, 4));
        LinearLayout.LayoutParams trackLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(7));
        trackLp.topMargin = dp(4);

        View fill = new View(this);
        fill.setBackground(rounded(barColor, 0, 4));
        View rest = new View(this);
        barTrack.addView(fill, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.01f));
        barTrack.addView(rest, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.99f));
        box.addView(barTrack, trackLp);

        parent.addView(box);
        MeterRow mr = new MeterRow();
        mr.tvValue = tvVal;
        mr.fillView = fill;
        mr.restView = rest;
        return mr;
    }

    private void updateMeter(MeterRow mr, String text, float fraction, int barColor, int textColor) {
        float f = Math.max(0.01f, Math.min(1.0f, fraction));
        mr.tvValue.setText(text);
        mr.tvValue.setTextColor(textColor);
        mr.fillView.setBackground(rounded(barColor, 0, 4));
        LinearLayout.LayoutParams flp = (LinearLayout.LayoutParams) mr.fillView.getLayoutParams();
        LinearLayout.LayoutParams rlp = (LinearLayout.LayoutParams) mr.restView.getLayoutParams();
        flp.weight = f;
        rlp.weight = Math.max(0.001f, 1.0f - f);
        mr.fillView.setLayoutParams(flp);
        mr.restView.setLayoutParams(rlp);
    }

    private void addToggleRow(LinearLayout parent, String key, String title, String desc) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(6), 0, dp(6));

        LinearLayout textCol = new LinearLayout(this);
        textCol.setOrientation(LinearLayout.VERTICAL);

        TextView tvT = new TextView(this);
        tvT.setText(title);
        tvT.setTextColor(COL_TEXT);
        tvT.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tvT.setTypeface(Typeface.DEFAULT_BOLD);
        textCol.addView(tvT);

        TextView tvD = new TextView(this);
        tvD.setText(desc);
        tvD.setTextColor(COL_MUTED);
        tvD.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        textCol.addView(tvD);

        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        tlp.rightMargin = dp(10);
        row.addView(textCol, tlp);

        Switch sw = new Switch(this);
        ColorStateList thumbTint = new ColorStateList(
                new int[][]{new int[]{android.R.attr.state_checked}, new int[]{}},
                new int[]{Color.parseColor("#4ADE80"), Color.parseColor("#9CA3AF")});
        ColorStateList trackTint = new ColorStateList(
                new int[][]{new int[]{android.R.attr.state_checked}, new int[]{}},
                new int[]{Color.parseColor("#166534"), Color.parseColor("#374151")});
        sw.setThumbTintList(thumbTint);
        sw.setTrackTintList(trackTint);
        sw.setOnCheckedChangeListener((buttonView, isChecked) -> {
            if (updatingSwitches) return;
            String val = isChecked ? "1" : "0";
            runRootAction("Toggle " + title + " -> " + (isChecked ? "ON" : "OFF"),
                    "/data/adb/debian-gpu.sh set-toggle " + key + " " + val, false);
        });
        row.addView(sw);
        parent.addView(row);

        // Subtle divider
        View div = new View(this);
        div.setBackgroundColor(Color.parseColor("#202434"));
        parent.addView(div, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1));

        toggleSwitches.put(key, sw);
    }

    private TextView addStatusRow(LinearLayout parent, String label) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(4), 0, dp(4));

        TextView tvLabel = new TextView(this);
        tvLabel.setText(label);
        tvLabel.setTextColor(COL_TEXT);
        tvLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        row.addView(tvLabel, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView badge = new TextView(this);
        badge.setText("...");
        badge.setTextColor(COL_MUTED);
        badge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        badge.setTypeface(Typeface.DEFAULT_BOLD);
        badge.setPadding(dp(9), dp(3), dp(9), dp(3));
        badge.setBackground(rounded(COL_SURFACE_BTN, 0, 12));
        row.addView(badge);

        parent.addView(row);
        return badge;
    }

    private LinearLayout makeRow() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return row;
    }

    private void addWeighted(LinearLayout row, View v, int leftMargin, int rightMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(42), 1f);
        lp.leftMargin = leftMargin;
        lp.rightMargin = rightMargin;
        row.addView(v, lp);
    }

    private Button makeButton(String text, int bg, int fg, boolean bold) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(fg);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        if (bold) b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setBackground(rounded(bg, 0, 10));
        b.setPadding(dp(10), 0, dp(10), 0);
        return b;
    }

    private void setBadge(TextView badge, String text, int fg, int bg) {
        badge.setText(text);
        badge.setTextColor(fg);
        badge.setBackground(rounded(bg, 0, 12));
    }

    private void appendLog(String msg) {
        ui.post(() -> {
            tvConsole.append(msg + "\n");
            consoleScroll.post(() -> consoleScroll.fullScroll(View.FOCUS_DOWN));
        });
    }

    private void setBusy(boolean state, String label) {
        busy = state;
        ui.post(() -> {
            tvBusyStatus.setText(label);
            tvBusyStatus.setTextColor(state ? COL_AMBER : COL_GREEN);
        });
    }

    private void copyText(String label, String text) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) {
            cm.setPrimaryClip(ClipData.newPlainText(label, text));
            Toast.makeText(this, "Copied " + label, Toast.LENGTH_SHORT).show();
        }
    }

    private void openTermuxX11() {
        try {
            Intent i = new Intent();
            i.setComponent(new ComponentName("com.termux.x11", "com.termux.x11.MainActivity"));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception e) {
            Toast.makeText(this, "Termux:X11 not found: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void confirmResetPerf() {
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Restore Stock Defaults?")
                .setMessage("Resets CPU/GPU/WALT/VM/XFCE/Vulkan toggles back to stock defaults (keeps PulseAudio enabled).")
                .setPositiveButton("Restore", (d, w) ->
                        runRootAction("Restoring stock defaults...", "/data/adb/debian-gpu.sh reset-perf", false))
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void showVncPasswordDialog() {
        final EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        input.setHint("New VNC password (6-8 chars)");
        input.setTextColor(COL_TEXT);
        input.setHintTextColor(COL_MUTED);
        input.setPadding(dp(16), dp(14), dp(16), dp(14));

        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Change VNC Password")
                .setView(input)
                .setPositiveButton("Update", (d, w) -> {
                    String pw = input.getText().toString();
                    if (pw.length() < 6) {
                        Toast.makeText(this, "Password must be at least 6 characters", Toast.LENGTH_SHORT).show();
                        return;
                    }
                    String escaped = pw.replace("'", "'\"'\"'");
                    String cmd = "chroot /data/local/debian-gpu /bin/su - droid -c "
                            + "\"mkdir -p ~/.vnc && printf '%s\\n' '" + escaped + "' | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd\" "
                            + "&& /data/adb/debian-gpu.sh vnc";
                    runRootAction("Updating VNC password & restarting VNC...", cmd, false);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private static class CmdResult {
        int code;
        String output;
        CmdResult(int code, String output) {
            this.code = code;
            this.output = output;
        }
    }

    private CmdResult execSu(String script) {
        try {
            Process p = new ProcessBuilder("su", "-M").redirectErrorStream(true).start();
            OutputStream os = p.getOutputStream();
            os.write((script + "\nexit\n").getBytes(StandardCharsets.UTF_8));
            os.flush();
            os.close();
            StringBuilder sb = new StringBuilder();
            BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append('\n');
            }
            int code = p.waitFor();
            return new CmdResult(code, sb.toString().trim());
        } catch (Exception e) {
            return new CmdResult(-1, "su error: " + e.getMessage());
        }
    }

    private void runRootAction(String title, String script, boolean openDisplayAfter) {
        if (busy) {
            Toast.makeText(this, "Another action is already running", Toast.LENGTH_SHORT).show();
            return;
        }
        setBusy(true, title);
        appendLog("$ " + title);
        executor.execute(() -> {
            CmdResult r = execSu(script);
            if (!TextUtils.isEmpty(r.output)) {
                appendLog(r.output);
            }
            appendLog(r.code == 0 ? "[OK]" : "[EXIT " + r.code + "]");
            setBusy(false, r.code == 0 ? "Done" : "Finished with code " + r.code);
            refreshStatusInternal();
            if (openDisplayAfter && r.code == 0) {
                ui.postDelayed(this::openTermuxX11, 500);
            }
        });
    }

    private void refreshStatus(boolean silent) {
        if (busy || refreshing) return;
        refreshing = true;
        if (!silent) {
            setBusy(true, "Refreshing telemetry...");
        }
        executor.execute(() -> {
            try {
                refreshStatusInternal();
            } finally {
                refreshing = false;
                if (!silent) {
                    setBusy(false, "Up to date");
                }
            }
        });
    }

    private static long parseLongSafe(String s, long def) {
        try {
            return Long.parseLong(s.trim());
        } catch (Exception e) {
            return def;
        }
    }

    private static String fmtGhz(long khz) {
        return String.format(Locale.US, "%.2f", khz / 1_000_000.0);
    }

    private void refreshStatusInternal() {
        CmdResult r = execSu("/data/adb/debian-gpu.sh telemetry");
        final Map<String, String> m = new HashMap<>();
        if (r.code == 0 && r.output != null) {
            for (String line : r.output.split("\n")) {
                int idx = line.indexOf('=');
                if (idx <= 0) continue;
                m.put(line.substring(0, idx).trim(), line.substring(idx + 1).trim());
            }
        }

        final boolean hasRoot = "1".equals(m.get("ROOT"));
        final boolean mounted = "1".equals(m.get("MOUNT"));
        final boolean x11 = "1".equals(m.get("X11"));
        final boolean desktop = "1".equals(m.get("DESKTOP"));
        final boolean plank = "1".equals(m.get("PLANK"));
        final boolean macosAvail = "1".equals(m.get("MACOS_AVAIL"));
        final boolean macosVm = "1".equals(m.get("MACOS_VM"));
        final boolean macosView = "1".equals(m.get("MACOS_VIEW"));
        final boolean macosReady = "1".equals(m.get("MACOS_READY"));
        final boolean vnc = "1".equals(m.get("VNC"));
        final boolean novnc = "1".equals(m.get("NOVNC"));
        final String pulse = m.getOrDefault("PULSE", "stopped");
        final String ts = m.getOrDefault("TS", "");
        final String disk = m.getOrDefault("DISK", "");
        currentTailscaleIp = ts;

        final long c0Cur = parseLongSafe(m.get("CPU0_CUR"), 0);
        final long c0Max = parseLongSafe(m.get("CPU0_MAX"), 3744000);
        final long c0Hw = Math.max(1, parseLongSafe(m.get("CPU0_HW"), 3744000));
        final String c0Act = m.getOrDefault("CPU0_ACT", "3");

        final long c3Cur = parseLongSafe(m.get("CPU3_CUR"), 0);
        final long c3Max = parseLongSafe(m.get("CPU3_MAX"), 4032000);
        final long c3Hw = Math.max(1, parseLongSafe(m.get("CPU3_HW"), 4032000));
        final String c3Act = m.getOrDefault("CPU3_ACT", "3");

        final long c6Cur = parseLongSafe(m.get("CPU6_CUR"), 0);
        final long c6Max = parseLongSafe(m.get("CPU6_MAX"), 5011200);
        final long c6Hw = Math.max(1, parseLongSafe(m.get("CPU6_HW"), 5011200));
        final String c6Act = m.getOrDefault("CPU6_ACT", "2");

        final String fasEn = m.getOrDefault("FAS_EN", "?");
        final String dubaiSvc = m.getOrDefault("DUBAID_SVC", "?");

        final long gpuCur = parseLongSafe(m.get("GPU_CUR"), 0);
        final long gpuMax = Math.max(1, parseLongSafe(m.get("GPU_MAX"), 1450));
        final long gpuBusy = parseLongSafe(m.get("GPU_BUSY"), 0);
        final String gpuTherm = m.getOrDefault("GPU_THERM_LVL", "?");
        final String gpuWake = m.getOrDefault("GPU_WAKE_MHZ", "?");
        final String gpuIdle = m.getOrDefault("GPU_IDLE_MS", "?");

        final String tCpu = m.getOrDefault("TEMP_CPU", "?");
        final String tGpu = m.getOrDefault("TEMP_GPU", "?");
        final String tSkin = m.getOrDefault("TEMP_SKIN", "?");
        final String tStat = m.getOrDefault("THERM_STATUS", "?");
        final String bCap = m.getOrDefault("BATT_CAP", "?");
        final String bTemp = m.getOrDefault("BATT_TEMP", "?");
        final String bStat = m.getOrDefault("BATT_STAT", "?");
        final String honorMode = m.getOrDefault("HONOR_MODE", "?");
        final boolean launcherFront = "true".equalsIgnoreCase(m.getOrDefault("LAUNCHER_FRONT", "false"));

        final String memUsed = m.getOrDefault("MEM_USED", "?");
        final String memTot = m.getOrDefault("MEM_TOTAL", "?");
        final String swpUsed = m.getOrDefault("SWAP_USED", "?");
        final String swpTot = m.getOrDefault("SWAP_TOTAL", "?");
        final String swappiness = m.getOrDefault("SWAPPINESS", "?");
        final String loopRa = m.getOrDefault("LOOP_RA", "?");
        final String thpDefrag = m.getOrDefault("THP_DEFRAG", "?");
        final boolean vulkanOn = "1".equals(m.get("PERF_CHROMIUM_VULKAN"));
        final boolean jemallocOn = "1".equals(m.get("PERF_JEMALLOC"));

        ui.post(() -> {
            int okBg = Color.parseColor("#143322");
            int okFg = Color.parseColor("#4ADE80");
            int offBg = Color.parseColor("#2A2226");
            int offFg = Color.parseColor("#F87171");
            int warnBg = Color.parseColor("#332914");
            int warnFg = Color.parseColor("#FBBF24");
            int infoBg = Color.parseColor("#142838");
            int infoFg = Color.parseColor("#7DCFFF");

            // Update CPU & GPU live meters
            boolean c0Capped = c0Max < (c0Hw - 100000) || "0".equals(c0Act);
            boolean c3Capped = c3Max < (c3Hw - 100000) || "0".equals(c3Act);
            boolean c6Capped = c6Max < (c6Hw - 100000) || "0".equals(c6Act);

            updateMeter(meterCpu0,
                    "[" + c0Act + "/3] " + fmtGhz(c0Cur) + " / " + fmtGhz(c0Max) + " GHz",
                    (float) c0Cur / c0Hw,
                    c0Capped ? COL_AMBER : COL_BLUE,
                    c0Capped ? warnFg : Color.parseColor("#A9B1D6"));

            updateMeter(meterCpu3,
                    "[" + c3Act + "/3] " + fmtGhz(c3Cur) + " / " + fmtGhz(c3Max) + " GHz",
                    (float) c3Cur / c3Hw,
                    c3Capped ? COL_AMBER : COL_CYAN,
                    c3Capped ? warnFg : Color.parseColor("#A9B1D6"));

            updateMeter(meterCpu6,
                    "[" + c6Act + "/2] " + fmtGhz(c6Cur) + " / " + fmtGhz(c6Max) + " GHz",
                    (float) c6Cur / c6Hw,
                    c6Capped ? COL_AMBER : COL_PURPLE,
                    c6Capped ? warnFg : Color.parseColor("#A9B1D6"));

            boolean gpuCapped = !"0".equals(gpuTherm);
            updateMeter(meterGpu,
                    gpuCur + " / " + gpuMax + " MHz · " + gpuBusy + "%",
                    (float) gpuCur / gpuMax,
                    gpuCapped ? COL_AMBER : COL_GREEN,
                    gpuCapped ? warnFg : okFg);

            tvGpuDetail.setText("KGSL: thermal_lvl=" + gpuTherm
                    + " · wake=" + gpuWake + " MHz · idle=" + gpuIdle + " ms");

            String thermLabel = "0".equals(tStat) ? "0 (Cool)"
                    : "1".equals(tStat) ? "1 (Light)"
                    : "2".equals(tStat) ? "2 (Mod)" : tStat;
            tvThermalsLine.setText("CPU " + tCpu + "°C · GPU " + tGpu + "°C · Skin " + tSkin + "°C · Thm " + thermLabel);

            String modeLabel = "4".equals(honorMode) ? "Performance"
                    : "1".equals(honorMode) ? "Normal"
                    : "3".equals(honorMode) ? "PowerSave" : honorMode;
            tvPowerLine.setText("Battery " + bCap + "% (" + bTemp + "°C, " + bStat + ") · Honor: " + modeLabel
                    + " · FAS:" + ("0".equals(fasEn) ? "off" : "on") + " · dubaid:" + ("stopped".equals(dubaiSvc) ? "paused" : "on"));
            tvMemLine.setText("RAM " + memUsed + "/" + memTot + " MB · ZRAM " + swpUsed + "/" + swpTot
                    + " MB · swp=" + swappiness + " · RA=" + loopRa + "K · THP=" + thpDefrag);

            tvLauncherWarn.setVisibility((launcherFront && (c0Capped || c6Capped)) ? View.VISIBLE : View.GONE);

            // System badges
            setBadge(badgeRoot, hasRoot ? "Granted" : "Tap to Grant in KSU", hasRoot ? okFg : offFg, hasRoot ? okBg : offBg);
            setBadge(badgeMount, mounted ? "Mounted" : "Unmounted", mounted ? okFg : offFg, mounted ? okBg : offBg);
            setBadge(badgeX11, x11 ? "Running" : "Stopped", x11 ? okFg : offFg, x11 ? okBg : offBg);

            if (desktop && plank) {
                setBadge(badgeDesktop, "Running", okFg, okBg);
            } else if (desktop) {
                setBadge(badgeDesktop, "XFCE only", warnFg, warnBg);
            } else {
                setBadge(badgeDesktop, "Stopped", offFg, offBg);
            }

            if (!macosAvail) {
                setBadge(badgeMacos, "Not Installed", COL_MUTED, COL_SURFACE_BTN);
            } else if (macosVm && macosView && macosReady) {
                setBadge(badgeMacos, "Running", okFg, okBg);
            } else if (macosVm && !macosView) {
                setBadge(badgeMacos, "VM Only", warnFg, warnBg);
            } else if (macosVm) {
                setBadge(badgeMacos, "Booting...", warnFg, warnBg);
            } else if (macosView) {
                setBadge(badgeMacos, "Viewer Only", warnFg, warnBg);
            } else {
                setBadge(badgeMacos, "Stopped", offFg, offBg);
            }

            if ("aaudio".equals(pulse)) {
                setBadge(badgeAudio, "AAudio Live", okFg, okBg);
            } else if ("null".equals(pulse)) {
                setBadge(badgeAudio, "Null Sink", warnFg, warnBg);
            } else {
                setBadge(badgeAudio, "Stopped", offFg, offBg);
            }

            if (vnc && novnc) {
                setBadge(badgeVnc, "VNC + Web", okFg, okBg);
            } else if (vnc || novnc) {
                setBadge(badgeVnc, vnc ? "VNC only" : "Web only", warnFg, warnBg);
            } else {
                setBadge(badgeVnc, "Stopped", offFg, offBg);
            }

            setBadge(badgeBrowserGpu, vulkanOn ? "Native Vulkan" : "Zink GL",
                    vulkanOn ? infoFg : warnFg, vulkanOn ? infoBg : warnBg);
            setBadge(badgeAllocator, jemallocOn ? "jemalloc 5.3" : "glibc",
                    jemallocOn ? okFg : COL_MUTED, jemallocOn ? okBg : COL_SURFACE_BTN);

            String host = TextUtils.isEmpty(ts) ? "127.0.0.1" : ts;
            tvNoVncUrl.setText("noVNC: http://" + host + ":6080/vnc.html");
            tvVncAddr.setText("VNC:   " + host + ":5900" + (TextUtils.isEmpty(ts) ? " (Tailscale offline)" : " (Tailscale)"));
            tvDiskInfo.setText(TextUtils.isEmpty(disk)
                    ? "Image: /data/adb/debian-gpu.img (unmounted)"
                    : "Chroot disk: " + disk + " · /data/adb/debian-gpu.img");

            // Sync toggle switches cleanly without re-triggering listeners
            updatingSwitches = true;
            try {
                for (Map.Entry<String, Switch> e : toggleSwitches.entrySet()) {
                    String v = m.get(e.getKey());
                    if (v != null) {
                        e.getValue().setChecked("1".equals(v));
                    }
                }
            } finally {
                updatingSwitches = false;
            }
        });
    }
}
