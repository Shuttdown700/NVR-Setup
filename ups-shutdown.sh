#!/usr/bin/env bash
# Called by upsmon as SHUTDOWNCMD when the NUT primary declares FSD.
#
#   sudo /usr/local/sbin/ups-shutdown-pi.sh --dry-run   # stop stack, NO poweroff
#   sudo /usr/local/sbin/ups-shutdown-pi.sh --check     # inspect only, change nothing
#   sudo /usr/local/sbin/ups-shutdown-pi.sh             # real teardown + poweroff
#
# Dry-run is selected by ARGV, not an environment variable: sudo's env_reset can
# strip env vars depending on sudoers, and a silently-ignored safety flag means
# an unintended poweroff.
set -u
exec > >(tee -a /var/log/ups-shutdown.log) 2>&1

STACK_DIR="/home/sagepi/NVR-Setup"
NVME_MOUNT="/mnt/nvme"

MODE="run"
case "${1:-}" in
    --dry-run) MODE="dryrun" ;;
    --check)   MODE="check" ;;
    "")        MODE="run" ;;
    *) echo "unknown argument: $1 (expected --dry-run, --check, or nothing)"; exit 2 ;;
esac

echo "=== $(date -Is) UPS shutdown (secondary), mode=${MODE} ==="

# --- check mode: report readiness, touch nothing -----------------------------
if [ "$MODE" = "check" ]; then
    echo "stack dir      : ${STACK_DIR} $([ -d "$STACK_DIR" ] && echo OK || echo MISSING)"
    echo "nvme mount     : ${NVME_MOUNT} $(mountpoint -q "$NVME_MOUNT" && echo MOUNTED || echo 'NOT MOUNTED')"
    echo "running        : $(docker ps -q | wc -l) container(s)"
    echo "=== check complete, nothing changed ==="
    exit 0
fi

# NOTE: --dry-run still STOPS CONTAINERS and UNMOUNTS. It only skips the
# poweroff. It is a rehearsal of the teardown, not a no-op. Use --check for
# a genuinely read-only look.
if [ "$MODE" = "dryrun" ]; then
    echo "--- DRY RUN: containers WILL be stopped; the Pi will NOT power off ---"
fi

if [ -d "$STACK_DIR" ]; then
    echo "--- stopping Frigate stack: $STACK_DIR"
    timeout 60 docker compose --project-directory "$STACK_DIR" down --timeout 45 \
        || echo "WARN: compose down failed or timed out"
fi

remaining=$(docker ps -q)
if [ -n "$remaining" ]; then
    echo "WARN: forcing remaining containers: $remaining"
    # shellcheck disable=SC2086
    timeout 25 docker stop -t 15 $remaining || true
fi

systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
sync

# Flush recordings to the NVMe. ext4 replays its journal on the next boot, so a
# lazy unmount here is not a data risk.
if mountpoint -q "$NVME_MOUNT"; then
    if umount "$NVME_MOUNT" 2>/dev/null; then
        echo "unmounted cleanly: $NVME_MOUNT"
    else
        echo "WARN: busy, forcing: $NVME_MOUNT"
        fuser -km "$NVME_MOUNT" 2>/dev/null
        sleep 3
        umount -l "$NVME_MOUNT" 2>/dev/null && echo "lazy-unmounted: $NVME_MOUNT"
    fi
fi

sync

if [ "$MODE" = "dryrun" ]; then
    echo "=== DRY RUN complete — NOT powering off ==="
    echo "Bring things back with:  sudo mount ${NVME_MOUNT} && sudo systemctl start docker && cd ${STACK_DIR} && sudo docker compose up -d"
    exit 0
fi

echo "=== teardown complete, powering off ==="
/sbin/shutdown -h +0