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

# ---------------------------------------------------------------- 4. UPS / NUT
#
# This Pi is a NUT *secondary*: the UPS is on the primary (the NAS) and we
# learn about outages over the LAN. Two independent things can break, and
# neither announces itself — the whole point of checking here:
#   (a) the link to the primary (upsmon dead, bad creds, router/LAN down)
#   (b) the local shutdown path (SHUTDOWNCMD missing/non-executable)
# upsmon does NOT validate SHUTDOWNCMD at startup, so a missing script looks
# perfectly healthy right up until the one moment it matters.
echo
echo "--- 4. UPS / NUT ---"

UPS_SHUTDOWN_SCRIPT="/usr/local/sbin/ups-shutdown-pi.sh"

# Resolve the UPS identity from upsmon.conf so this stays in sync with setup.sh
UPS_TARGET=""
if [[ -r /etc/nut/upsmon.conf ]]; then
    UPS_TARGET=$(awk '/^[[:space:]]*MONITOR[[:space:]]/{print $2; exit}' /etc/nut/upsmon.conf 2>/dev/null)
elif sudo -n true 2>/dev/null; then
    UPS_TARGET=$(sudo awk '/^[[:space:]]*MONITOR[[:space:]]/{print $2; exit}' /etc/nut/upsmon.conf 2>/dev/null)
fi

if [[ -z "$UPS_TARGET" ]] && ! command -v upsc >/dev/null 2>&1; then
    info "NUT not configured on this host — UPS checks skipped"
else
    # --- 4a. upsmon service ---
    if systemctl is-active --quiet nut-monitor; then
        ok "nut-monitor running"
    else
        bad "nut-monitor NOT running — this Pi will hard-cut on a power failure"
    fi

    # --- 4b. shutdown path ---
    if [[ -x "$UPS_SHUTDOWN_SCRIPT" ]]; then
        ok "Shutdown script present and executable"
    elif [[ -e "$UPS_SHUTDOWN_SCRIPT" ]]; then
        bad "$UPS_SHUTDOWN_SCRIPT exists but is NOT executable — shutdown would fail"
    else
        bad "$UPS_SHUTDOWN_SCRIPT MISSING — upsmon has nothing to run on FSD"
    fi

    # /run/nut must exist or upsmon can't write its PID file, which silently
    # breaks 'upsmon -c fsd' and 'upsmon -c reload'. Pi OS omits the tmpfiles
    # snippet that creates it.
    if [[ -d /run/nut ]]; then
        ok "/run/nut present"
    else
        bad "/run/nut missing — 'upsmon -c fsd' and reload will fail"
    fi

    # --- 4c. link to the primary + battery state ---
    if [[ -z "$UPS_TARGET" ]]; then
        bad "No MONITOR line found in /etc/nut/upsmon.conf"
    else
        info "Monitoring: $UPS_TARGET"
        UPSDATA=$(upsc "$UPS_TARGET" 2>/dev/null)
        if [[ -z "$UPSDATA" ]]; then
            bad "Cannot reach $UPS_TARGET — primary down, LAN down, or bad credentials"
        else
            ok "Reached NUT primary"

            ups_var() { echo "$UPSDATA" | awk -F': ' -v k="$1" '$1==k{print $2; exit}'; }

            STATUS=$(ups_var ups.status)
            CHARGE=$(ups_var battery.charge)
            RUNTIME=$(ups_var battery.runtime)
            LOAD=$(ups_var ups.load)
            INV=$(ups_var input.voltage)
            BATTV=$(ups_var battery.voltage)

            [[ -n "$RUNTIME" ]] && RUNMIN=$((RUNTIME / 60)) || RUNMIN="?"
            info "Load: ${LOAD:-?}% | input: ${INV:-?}V | battery: ${BATTV:-?}V | runtime: ${RUNMIN} min"

            # Status is a space-separated flag list: OL, OB, LB, RB, CHRG, etc.
            case " $STATUS " in
                *" OB "*)
                    bad "UPS ON BATTERY (${STATUS}) — mains lost, ${RUNMIN} min remaining" ;;
                *" OL "*)
                    ok "UPS on line power (${STATUS})" ;;
                "  "|"")
                    bad "UPS status unavailable" ;;
                *)
                    bad "UPS in unexpected state: ${STATUS}" ;;
            esac

            # Explicit flags worth surfacing regardless of OL/OB
            [[ " $STATUS " == *" LB "* ]] && bad "LOW BATTERY flag set — shutdown imminent"
            [[ " $STATUS " == *" RB "* ]] && bad "REPLACE BATTERY flag set — pack is failing"
            [[ " $STATUS " == *" OVER "* ]] && bad "UPS OVERLOADED — reduce connected load"
            [[ " $STATUS " == *" ALARM "* ]] && bad "UPS alarm condition present"

            if [[ -n "$CHARGE" ]]; then
                if [[ "$CHARGE" -ge 90 ]]; then
                    ok "Battery charge: ${CHARGE}%"
                elif [[ "$CHARGE" -ge 50 ]]; then
                    info "Battery charge: ${CHARGE}% (recharging?)"
                else
                    bad "Battery charge low: ${CHARGE}%"
                fi
            fi

            # Runtime is the number that actually matters for a clean teardown.
            # Compare against the primary's own low-runtime threshold if exposed.
            RTLOW=$(ups_var battery.runtime.low)
            if [[ -n "$RUNTIME" && -n "$RTLOW" ]] && [[ "$RUNTIME" -lt "$RTLOW" ]]; then
                bad "Runtime ${RUNMIN} min is below the configured low threshold ($((RTLOW / 60)) min)"
            fi
        fi
    fi

    # --- 4d. last shutdown event ---
    # A stale killpower flag means a previous shutdown didn't complete cleanly.
    if [[ -f /etc/killpower ]]; then
        bad "/etc/killpower present — leftover from an incomplete UPS shutdown"
    fi
    if [[ -r /var/log/ups-shutdown.log ]]; then
        LASTUPS=$(grep -a '^=== ' /var/log/ups-shutdown.log 2>/dev/null | tail -1)
        [[ -n "$LASTUPS" ]] && info "Last shutdown log entry: ${LASTUPS}"
    fi
fi

# ---------------------------------------------------------------- 5. REMOTE ACCESS
echo
echo "--- 5. REMOTE ACCESS (VNC) ---"
if systemctl is-enabled --quiet wayvnc 2>/dev/null || pgrep -x wayvnc >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -q ':5900 '; then
        ok "wayvnc listening on :5900"
    else
        bad "wayvnc enabled but nothing listening on :5900"
    fi
else
    info "wayvnc not enabled (headless/SSH-only setup?)"
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