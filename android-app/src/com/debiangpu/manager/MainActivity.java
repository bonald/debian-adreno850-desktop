package com.debiangpu.manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
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
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends Activity {

    private static final int COL_BG = Color.parseColor("#0F1117");
    private static final int COL_CARD = Color.parseColor("#181B24");
    private static final int COL_CARD_BORDER = Color.parseColor("#2A2F42");
    private static final int COL_TEXT = Color.parseColor("#E6E9F2");
    private static final int COL_MUTED = Color.parseColor("#8B92A8");
    private static final int COL_BLUE = Color.parseColor("#3B82F6");
    private static final int COL_GREEN = Color.parseColor("#22C55E");
    private static final int COL_AMBER = Color.parseColor("#F59E0B");
    private static final int COL_PURPLE = Color.parseColor("#8B5CF6");
    private static final int COL_SURFACE_BTN = Color.parseColor("#242938");
    private static final int COL_CONSOLE_BG = Color.parseColor("#0B0D12");

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());

    private TextView badgeRoot, badgeMount, badgeX11, badgeDesktop, badgeVnc, badgeGpu;
    private TextView tvNoVncUrl, tvVncAddr, tvDiskInfo, tvConsole, tvBusyStatus;
    private ScrollView consoleScroll;

    private volatile String currentTailscaleIp = "";
    private volatile boolean busy = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());
        refreshStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (!busy) {
            refreshStatus();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
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
        final int padH = dp(16), padTop = dp(16), padBot = dp(28);
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
        header.setPadding(dp(4), dp(8), dp(4), dp(16));

        LinearLayout titleBox = new LinearLayout(this);
        titleBox.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);

        TextView title = new TextView(this);
        title.setText("Debian GPU");
        title.setTextColor(COL_TEXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        titleBox.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("Adreno 850 Turnip · Vulkan 1.4 · OpenGL 4.6");
        subtitle.setTextColor(COL_MUTED);
        subtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        titleBox.addView(subtitle);
        header.addView(titleBox, titleLp);

        Button btnRefresh = makeButton("Refresh", COL_SURFACE_BTN, COL_TEXT, false);
        btnRefresh.setOnClickListener(v -> refreshStatus());
        header.addView(btnRefresh, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(38)));
        root.addView(header);

        // --- Live Status Card ---
        LinearLayout statusCard = makeCard("SYSTEM STATUS");
        badgeRoot = addStatusRow(statusCard, "Root (su -M)");
        badgeRoot.setOnClickListener(v -> {
            Intent ksu = getPackageManager().getLaunchIntentForPackage("me.weishu.kernelsu");
            if (ksu != null) {
                startActivity(ksu);
            } else {
                Toast.makeText(this, "Grant root to Debian GPU in KernelSU / Magisk", Toast.LENGTH_LONG).show();
            }
        });
        badgeMount = addStatusRow(statusCard, "Debian 13 Chroot");
        badgeX11 = addStatusRow(statusCard, "Termux:X11 (:0)");
        badgeDesktop = addStatusRow(statusCard, "macOS Desktop (XFCE + Plank)");
        badgeVnc = addStatusRow(statusCard, "Remote X (VNC + noVNC)");
        badgeGpu = addStatusRow(statusCard, "Adreno GPU");

        tvDiskInfo = new TextView(this);
        tvDiskInfo.setTextColor(COL_MUTED);
        tvDiskInfo.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvDiskInfo.setPadding(0, dp(8), 0, 0);
        tvDiskInfo.setText("Image: /data/adb/debian-gpu.img");
        statusCard.addView(tvDiskInfo);
        root.addView(statusCard);

        // --- Desktop Controls Card ---
        LinearLayout ctrlCard = makeCard("DESKTOP CONTROLS");

        LinearLayout row1 = makeRow();
        Button btnStart = makeButton("Start Desktop", COL_GREEN, Color.parseColor("#062010"), true);
        btnStart.setOnClickListener(v -> runRootAction("Starting Debian GPU desktop...",
                "/data/adb/debian-gpu.sh start", true));
        Button btnOpen = makeButton("Open Display", COL_BLUE, Color.WHITE, true);
        btnOpen.setOnClickListener(v -> openTermuxX11());
        addWeighted(row1, btnStart, 0, dp(6));
        addWeighted(row1, btnOpen, dp(6), 0);
        ctrlCard.addView(row1);

        LinearLayout row2 = makeRow();
        row2.setPadding(0, dp(10), 0, 0);
        Button btnStop = makeButton("Stop Desktop", COL_SURFACE_BTN, COL_TEXT, false);
        btnStop.setOnClickListener(v -> runRootAction("Stopping desktop & VNC...",
                "/data/adb/debian-gpu.sh stop", false));
        Button btnUmount = makeButton("Unmount Image", Color.parseColor("#3B1B22"),
                Color.parseColor("#FCA5A5"), false);
        btnUmount.setOnClickListener(v -> runRootAction("Stopping & unmounting ext4 image...",
                "/data/adb/debian-gpu.sh umount", false));
        addWeighted(row2, btnStop, 0, dp(6));
        addWeighted(row2, btnUmount, dp(6), 0);
        ctrlCard.addView(row2);
        root.addView(ctrlCard);

        // --- Remote X Access Card ---
        LinearLayout remoteCard = makeCard("REMOTE X (TAILSCALE ONLY)");

        tvNoVncUrl = new TextView(this);
        tvNoVncUrl.setTextColor(Color.parseColor("#7DCFFF"));
        tvNoVncUrl.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tvNoVncUrl.setTypeface(Typeface.MONOSPACE);
        tvNoVncUrl.setText("noVNC: —");
        remoteCard.addView(tvNoVncUrl);

        tvVncAddr = new TextView(this);
        tvVncAddr.setTextColor(COL_MUTED);
        tvVncAddr.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tvVncAddr.setTypeface(Typeface.MONOSPACE);
        tvVncAddr.setPadding(0, dp(4), 0, dp(12));
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
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse("http://" + ip + ":6080/vnc.html"));
            startActivity(i);
        });
        addWeighted(rRow1, btnCopyWeb, 0, dp(4));
        addWeighted(rRow1, btnCopyVnc, dp(4), dp(4));
        addWeighted(rRow1, btnOpenWeb, dp(4), 0);
        remoteCard.addView(rRow1);

        Button btnPasswd = makeButton("Change VNC Password", COL_SURFACE_BTN, COL_TEXT, false);
        LinearLayout.LayoutParams passLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        passLp.topMargin = dp(10);
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
        Button btnGpuCheck = makeButton("Verify GPU", COL_SURFACE_BTN, COL_TEXT, false);
        btnGpuCheck.setOnClickListener(v -> runRootAction("Probing Adreno 850 Turnip + Zink...",
                "chroot /data/local/debian-gpu /bin/su - droid -c '. /etc/profile.d/turnip-a850.sh && vulkaninfo --summary 2>&1 | grep -E \"apiVersion|deviceName|driverName|driverInfo\" && echo \"---\" && glxinfo -B 2>&1 | grep -E \"Accelerated|renderer string|core profile version\"'",
                false));
        addWeighted(tRow1, btnTerm, 0, dp(6));
        addWeighted(tRow1, btnGpuCheck, dp(6), 0);
        toolsCard.addView(tRow1);

        Button btnBench = makeButton("Run 720p GPU Benchmark (glmark2)", COL_SURFACE_BTN, COL_MUTED, false);
        LinearLayout.LayoutParams benchLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        benchLp.topMargin = dp(10);
        btnBench.setOnClickListener(v -> runRootAction("Running 720p offscreen glmark2...",
                "/data/adb/debian-gpu.sh verify --bench", false));
        toolsCard.addView(btnBench, benchLp);
        root.addView(toolsCard);

        // --- Console Output Card ---
        LinearLayout logCard = makeCard("CONSOLE OUTPUT");
        tvBusyStatus = new TextView(this);
        tvBusyStatus.setTextColor(COL_AMBER);
        tvBusyStatus.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tvBusyStatus.setPadding(0, 0, 0, dp(6));
        tvBusyStatus.setText("Idle");
        logCard.addView(tvBusyStatus);

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
                ViewGroup.LayoutParams.MATCH_PARENT, dp(170)));
        root.addView(logCard);

        return rootScroll;
    }

    private LinearLayout makeCard(String headerTitle) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(rounded(COL_CARD, COL_CARD_BORDER, 14));
        card.setPadding(dp(14), dp(14), dp(14), dp(14));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(14);
        card.setLayoutParams(lp);

        TextView tv = new TextView(this);
        tv.setText(headerTitle);
        tv.setTextColor(COL_MUTED);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tv.setTypeface(Typeface.DEFAULT_BOLD);
        tv.setLetterSpacing(0.08f);
        tv.setPadding(0, 0, 0, dp(10));
        card.addView(tv);
        return card;
    }

    private TextView addStatusRow(LinearLayout parent, String label) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(4), 0, dp(4));

        TextView tvLabel = new TextView(this);
        tvLabel.setText(label);
        tvLabel.setTextColor(COL_TEXT);
        tvLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        row.addView(tvLabel, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView badge = new TextView(this);
        badge.setText("...");
        badge.setTextColor(COL_MUTED);
        badge.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        badge.setTypeface(Typeface.DEFAULT_BOLD);
        badge.setPadding(dp(10), dp(3), dp(10), dp(3));
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
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(44), 1f);
        lp.leftMargin = leftMargin;
        lp.rightMargin = rightMargin;
        row.addView(v, lp);
    }

    private Button makeButton(String text, int bg, int fg, boolean bold) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(fg);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
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
                            + "&& /data/adb/debian-gpu.sh start";
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
            // -M enters the global mount namespace so chroot & Termux:X11 mounts are visible
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

    private void refreshStatus() {
        if (busy) return;
        setBusy(true, "Refreshing status...");
        executor.execute(() -> {
            refreshStatusInternal();
            setBusy(false, "Up to date");
        });
    }

    private void refreshStatusInternal() {
        String probe = ""
                + "echo ROOT=1\n"
                + "mountpoint -q /data/local/debian-gpu && echo MOUNT=1 || echo MOUNT=0\n"
                + "([ -S /data/data/com.termux/files/usr/tmp/.X11-unix/X0 ] || [ -S /data/local/debian-gpu/tmp/.X11-unix/X0 ] || ss -xl 2>/dev/null | grep -q 'X11-unix/X0') && (pgrep -f 'termux.x11' >/dev/null 2>&1 || pgrep -f 'Xwayland' >/dev/null 2>&1 || ss -xl 2>/dev/null | grep -q 'X11-unix/X0') && echo X11=1 || echo X11=0\n"
                + "pgrep -x xfwm4 >/dev/null 2>&1 && echo DESKTOP=1 || echo DESKTOP=0\n"
                + "pgrep -x plank >/dev/null 2>&1 && echo PLANK=1 || echo PLANK=0\n"
                + "(pgrep -x x0vncserver >/dev/null 2>&1 || pgrep -x X0tigervnc >/dev/null 2>&1) && echo VNC=1 || echo VNC=0\n"
                + "pgrep -f 'websockify.*6080' >/dev/null 2>&1 && echo NOVNC=1 || echo NOVNC=0\n"
                + "TS=$(ip -4 addr show dev tun1 2>/dev/null | awk '/inet / {split($2,a,\"/\"); print a[1]; exit}' || ip -4 addr show 2>/dev/null | awk '/inet 100\\./ {split($2,a,\"/\"); print a[1]; exit}')\n"
                + "echo TS=$TS\n"
                + "CLK=$(cat /sys/class/kgsl/kgsl-3d0/clock_mhz 2>/dev/null || echo '?')\n"
                + "BUSY=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d ' ' || echo '?')\n"
                + "echo GPU=\"${CLK}MHz (${BUSY})\"\n"
                + "DISK=$(df -h /data/local/debian-gpu 2>/dev/null | awk 'NR==2{print $3\" / \"$2\" (\"$5\")\"}')\n"
                + "echo DISK=\"$DISK\"\n";

        CmdResult r = execSu(probe);
        boolean hasRoot = false, mounted = false, x11 = false, desktop = false, plank = false, vnc = false, novnc = false;
        String ts = "", gpu = "Adreno GPU", disk = "";

        if (r.code == 0 && r.output != null) {
            for (String line : r.output.split("\n")) {
                int idx = line.indexOf('=');
                if (idx <= 0) continue;
                String k = line.substring(0, idx).trim();
                String v = line.substring(idx + 1).trim();
                switch (k) {
                    case "ROOT": hasRoot = "1".equals(v); break;
                    case "MOUNT": mounted = "1".equals(v); break;
                    case "X11": x11 = "1".equals(v); break;
                    case "DESKTOP": desktop = "1".equals(v); break;
                    case "PLANK": plank = "1".equals(v); break;
                    case "VNC": vnc = "1".equals(v); break;
                    case "NOVNC": novnc = "1".equals(v); break;
                    case "TS": ts = v; break;
                    case "GPU": gpu = v; break;
                    case "DISK": disk = v; break;
                }
            }
        }

        final boolean fRoot = hasRoot, fMounted = mounted, fX11 = x11, fDesktop = desktop, fPlank = plank, fVnc = vnc, fNovnc = novnc;
        final String fTs = ts, fGpu = gpu, fDisk = disk;
        currentTailscaleIp = ts;

        ui.post(() -> {
            int okBg = Color.parseColor("#143322");
            int okFg = Color.parseColor("#4ADE80");
            int offBg = Color.parseColor("#2A2226");
            int offFg = Color.parseColor("#F87171");
            int warnBg = Color.parseColor("#332914");
            int warnFg = Color.parseColor("#FBBF24");

            setBadge(badgeRoot, fRoot ? "Granted" : "Tap to Grant Root", fRoot ? okFg : offFg, fRoot ? okBg : offBg);
            setBadge(badgeMount, fMounted ? "Mounted" : "Unmounted", fMounted ? okFg : offFg, fMounted ? okBg : offBg);
            setBadge(badgeX11, fX11 ? "Running" : "Stopped", fX11 ? okFg : offFg, fX11 ? okBg : offBg);
            if (fDesktop && fPlank) {
                setBadge(badgeDesktop, "Running", okFg, okBg);
            } else if (fDesktop) {
                setBadge(badgeDesktop, "XFCE only", warnFg, warnBg);
            } else {
                setBadge(badgeDesktop, "Stopped", offFg, offBg);
            }
            if (fVnc && fNovnc) {
                setBadge(badgeVnc, "VNC + Web", okFg, okBg);
            } else if (fVnc || fNovnc) {
                setBadge(badgeVnc, fVnc ? "VNC only" : "Web only", warnFg, warnBg);
            } else {
                setBadge(badgeVnc, "Stopped", offFg, offBg);
            }
            setBadge(badgeGpu, fGpu, Color.parseColor("#7DCFFF"), Color.parseColor("#142838"));

            String host = TextUtils.isEmpty(fTs) ? "127.0.0.1" : fTs;
            tvNoVncUrl.setText("noVNC: http://" + host + ":6080/vnc.html");
            tvVncAddr.setText("VNC:   " + host + ":5900" + (TextUtils.isEmpty(fTs) ? " (Tailscale offline)" : " (Tailscale)"));
            tvDiskInfo.setText(TextUtils.isEmpty(fDisk)
                    ? "Image: /data/adb/debian-gpu.img (unmounted)"
                    : "Chroot disk: " + fDisk + "  ·  /data/adb/debian-gpu.img");
        });
    }
}
