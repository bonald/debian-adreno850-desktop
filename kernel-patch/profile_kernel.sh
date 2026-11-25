#!/system/bin/sh
# Safe zero-risk live kernel profiler using Linux tracefs.
# Non-destructive: preserves existing tracefs/perfetto/kprobe events, cleans up
# ONLY its own probes via EXIT/INT/TERM trap, and avoids overlapping honor_boost.ko.

set -eu
SECS="${1:-3}"
case "$SECS" in
    ''|*[!0-9]*) echo "Usage: $0 [1..30]" >&2; exit 1 ;;
esac
[ "$SECS" -ge 1 ] && [ "$SECS" -le 30 ] || { echo "Seconds must be 1..30" >&2; exit 1; }

T=/sys/kernel/tracing
ORIG_TRACING_ON=$(cat "$T/tracing_on" 2>/dev/null || echo 0)
ADDED_KP=0
ENABLED_EVS=""

cleanup() {
    for ev in $ENABLED_EVS; do
        [ -w "$T/events/$ev/enable" ] && echo 0 > "$T/events/$ev/enable" 2>/dev/null || true
    done
    if [ "$ADDED_KP" = "1" ]; then
        for p in hb_prof_fq hb_prof_kgsl hb_prof_udma; do
            [ -w "$T/events/kprobes/$p/enable" ] && echo 0 > "$T/events/kprobes/$p/enable" 2>/dev/null || true
            echo "-:$p" >> "$T/kprobe_events" 2>/dev/null || true
        done
    fi
    echo "$ORIG_TRACING_ON" > "$T/tracing_on" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Do not overlap kprobe_events with honor_boost.ko's live kprobes
if ! lsmod 2>/dev/null | grep -q '^honor_boost '; then
    echo "p:hb_prof_fq freq_qos_update_request req=%x0 val=%x1:s32" >> "$T/kprobe_events" 2>/dev/null || true
    echo "p:hb_prof_kgsl gen8_hwsched_gmu_based_dcvs_pwr_ops dev=%x0 val=%x1:u32 op=%x2:u32" >> "$T/kprobe_events" 2>/dev/null || true
    echo "p:hb_prof_udma udmabuf_create" >> "$T/kprobe_events" 2>/dev/null || true
    ADDED_KP=1
    for p in hb_prof_fq hb_prof_kgsl hb_prof_udma; do
        [ -w "$T/events/kprobes/$p/enable" ] && echo 1 > "$T/events/kprobes/$p/enable" 2>/dev/null || true
    done
fi

for ev in vmscan/mm_vmscan_direct_reclaim_begin vmscan/mm_vmscan_kswapd_wake compaction/mm_compaction_begin; do
    if [ -w "$T/events/$ev/enable" ] && [ "$(cat "$T/events/$ev/enable" 2>/dev/null || echo 0)" = "0" ]; then
        echo 1 > "$T/events/$ev/enable" 2>/dev/null || true
        ENABLED_EVS="$ENABLED_EVS $ev"
    fi
done

Z1=$(cat /sys/block/zram0/hyperhold_zswapd_stat 2>/dev/null || true)
echo 1 > "$T/tracing_on"
sleep "$SECS"
echo 0 > "$T/tracing_on"
Z2=$(cat /sys/block/zram0/hyperhold_zswapd_stat 2>/dev/null || true)

echo "=== Kernel Profile (${SECS}s) ==="
grep -E '(hb_prof_|mm_vmscan_|mm_compaction_)' "$T/trace" | awk '{print $5}' | sort | uniq -c | sort -rn | head -n 15
if [ "$ADDED_KP" = "1" ]; then
    echo "--- Top freq_qos values ---"
    grep 'hb_prof_fq:' "$T/trace" | sed -n 's/.*val=\([-0-9]*\).*/val=\1/p' | sort | uniq -c | sort -rn | head -n 10
    echo "--- Top KGSL GMU DCVS ops ---"
    grep 'hb_prof_kgsl:' "$T/trace" | sed -n 's/.*\(val=[0-9]* op=[0-9]*\).*/\1/p' | sort | uniq -c | sort -rn | head -n 10
fi
echo "--- HyperHold zswapd ---"
echo "Before: $(echo "$Z1" | tr '\n' ' ')"
echo "After:  $(echo "$Z2" | tr '\n' ' ')"
if [ -d /sys/module/honor_boost/parameters ]; then
    echo "--- honor_boost.ko live counters ---"
    for f in /sys/module/honor_boost/parameters/*; do
        printf "  %s=%s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
    done
fi
