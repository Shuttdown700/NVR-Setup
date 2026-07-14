#!/bin/bash
# nvr_health.sh — Pi 5 NVR diagnostics
# Exit code: 0 = healthy, 1 = one or more failures (usable in cron/monitoring)

FAIL=0
NVME_MOUNT="/mnt/nvme"
FRIGATE_DATA="${NVME_MOUNT}/frigate"

ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
info() { echo "  [--]   $*"; }

echo "=== NVR HEALTH CHECK — $(date '+%F %T') ==="

# ---------------------------------------------------------------- 1. SYSTEM
echo
echo "--- 1. SYSTEM ---"
free -h | awk '/^Mem:/{print "  [--]   RAM: " $3 " / " $2}'

CORES=$(nproc)
LOAD1=$(cut -d' ' -f1 /proc/loadavg)
LOAD_PCT=$(echo "scale=0; ($LOAD1 / $CORES) * 100 / 1" | bc)
info "Load (1m): $LOAD1 on $CORES cores (${LOAD_PCT}%)"
[[ "$LOAD_PCT" -lt 90 ]] && ok "CPU load nominal" || bad "CPU load high (${LOAD_PCT}%)"

CPU_TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
if [[ -n "$CPU_TEMP" ]]; then
    [[ "${CPU_TEMP%.*}" -lt 75 ]] && ok "CPU temp: ${CPU_TEMP}C" || bad "CPU temp high: ${CPU_TEMP}C"
fi

# Undervoltage / throttling — key given past PSU brownout history
if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED=$(vcgencmd get_throttled | cut -d= -f2)
    if [[ "$THROTTLED" == "0x0" ]]; then
        ok "No throttling/undervoltage flags (0x0)"
    else
        bad "Throttle flags: $THROTTLED  (bit0=undervolt now, bit16=undervolt occurred, bit1/17=freq cap, bit2/18=throttled)"
    fi
fi

# ---------------------------------------------------------------- 2. NVME
echo
echo "--- 2. NVME STORAGE ---"
if mountpoint -q "$NVME_MOUNT"; then
    ok "Mounted at $NVME_MOUNT"
    read -r SIZE USED AVAIL PCT <<< "$(df -h --output=size,used,avail,pcent "$NVME_MOUNT" | tail -1)"
    info "Space: $USED / $SIZE used ($PCT), $AVAIL free"
    PCT_NUM=${PCT%\%}
    [[ "$PCT_NUM" -lt 90 ]] && ok "Disk usage under 90%" || bad "Disk usage at ${PCT} — check Frigate retention settings"
    FRIG_SIZE=$(du -sh "$FRIGATE_DATA" 2>/dev/null | cut -f1)
    info "Frigate data: ${FRIG_SIZE:-unknown}"

    # Read/write sanity — catches the silent-remount-ro failure mode
    if touch "${NVME_MOUNT}/.healthcheck" 2>/dev/null; then
        rm -f "${NVME_MOUNT}/.healthcheck"
        ok "Filesystem writable"
    else
        bad "Filesystem NOT writable (remounted read-only? check dmesg for I/O errors)"
    fi

    # NVMe SMART: temp + spare + error log
    NVME_DEV=$(findmnt -no SOURCE "$NVME_MOUNT" | sed 's/p[0-9]*$//')
    if command -v nvme >/dev/null 2>&1 && [[ -b "$NVME_DEV" ]]; then
        SMART=$(sudo nvme smart-log "$NVME_DEV" 2>/dev/null)
        if [[ -n "$SMART" ]]; then
            NVME_TEMP=$(echo "$SMART" | awk -F: '/^temperature/{gsub(/[^0-9]/,"",$2); print $2; exit}')
            SPARE=$(echo "$SMART"  | awk -F: '/available_spare /{gsub(/[^0-9]/,"",$2); print $2; exit}')
            MERR=$(echo "$SMART"   | awk -F: '/media_errors/{gsub(/[^0-9]/,"",$2); print $2; exit}')
            info "NVMe temp: ${NVME_TEMP:-?}C | spare: ${SPARE:-?}% | media errors: ${MERR:-?}"
            [[ "${MERR:-0}" -eq 0 ]] && ok "No NVMe media errors" || bad "NVMe media errors: $MERR"
        else
            info "smart-log unavailable (run with sudo for SMART data)"
        fi
    fi
else
    bad "NVMe NOT MOUNTED at $NVME_MOUNT — recordings unavailable"
fi

# ---------------------------------------------------------------- 3. DOCKER
echo
echo "--- 3. DOCKER / FRIGATE ---"
if systemctl is-active --quiet docker; then
    ok "Docker daemon running"
else
    bad "Docker daemon not running"
fi

for C in frigate cloudflared; do
    STATE=$(docker inspect -f '{{.State.Status}}' "$C" 2>/dev/null)
    if [[ "$STATE" == "running" ]]; then
        RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$C" 2>/dev/null)
        ok "$C running (restarts since create: ${RESTARTS:-?})"
    else
        bad "$C is '${STATE:-missing}'"
    fi
done

# Frigate API — the real "is it working" test
STATS=$(curl -fsS -m 5 http://localhost:5000/api/stats 2>/dev/null)
if [[ -n "$STATS" ]]; then
    ok "Frigate API responding"
    if command -v jq >/dev/null 2>&1; then
        echo "$STATS" | jq -r '.cameras | to_entries[] |
            "  [--]   cam \(.key): fps=\(.value.camera_fps // 0) detect_fps=\(.value.detection_fps // 0)"' 2>/dev/null
        echo "$STATS" | jq -r '.cameras | to_entries[] | select((.value.camera_fps // 0) == 0) |
            "  [FAIL] cam \(.key): 0 fps — stream down?"' 2>/dev/null | grep -q FAIL && FAIL=1
    fi
else
    bad "Frigate API not responding on :5000"
fi

# Recording freshness — is anything actually being written?
if mountpoint -q "$NVME_MOUNT"; then
    NEWEST=$(find "${FRIGATE_DATA}/recordings" -type f -mmin -15 -print -quit 2>/dev/null)
    if [[ -n "$NEWEST" ]]; then
        ok "Recordings written in last 15 min"
    else
        bad "No recording files written in last 15 min (check camera config / record: enabled)"
    fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
    echo "=== RESULT: HEALTHY ==="
else
    echo "=== RESULT: FAILURES DETECTED ==="
fi
exit $FAIL
