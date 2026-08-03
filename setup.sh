#!/bin/bash
# =============================================================================
# setup.sh — Pi 5 NVR bootstrap (Frigate + Cloudflare Tunnel, NVMe storage)
#
# Purpose: rebuild this NVR from a fresh Raspberry Pi OS (64-bit) flash.
# Design guarantees:
#   * NEVER formats, partitions, or deletes anything on the NVMe.
#     If it can't find a mountable ext4 filesystem, it stops and tells you.
#   * Idempotent — safe to re-run at any time.
#   * All secrets live in .env (see .env.example), not in this repo.
#
# Usage:
#   sudo ./setup.sh              # normal rebuild
#   sudo ./setup.sh --pcie-gen3  # also force PCIe gen3 in config.txt (faster
#                                # NVMe; some drives are unstable — optional)
#   sudo ./setup.sh --skip-ups   # skip UPS/NUT configuration
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVME_MOUNT="/mnt/nvme"
FRIGATE_DATA="${NVME_MOUNT}/frigate"
BOOT_CONFIG="/boot/firmware/config.txt"
PCIE_GEN3=false
SKIP_UPS=false

for arg in "$@"; do
    case "$arg" in
        --pcie-gen3) PCIE_GEN3=true ;;
        --skip-ups)  SKIP_UPS=true ;;
    esac
done

log()  { echo -e "\e[1;32m[setup]\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m  $*"; }
die()  { echo -e "\e[1;31m[fatal]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./setup.sh"

# The user who invoked sudo (for docker group membership)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

# -----------------------------------------------------------------------------
# 1. Base packages
# -----------------------------------------------------------------------------
log "Installing base packages..."
apt-get update -qq
apt-get install -y -qq \
    curl ca-certificates gnupg \
    nvme-cli smartmontools \
    jq bc

# -----------------------------------------------------------------------------
# 2. Docker (official convenience script; skipped if already present)
# -----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

if ! id -nG "$REAL_USER" | grep -qw docker; then
    log "Adding $REAL_USER to docker group (re-login required to take effect)"
    usermod -aG docker "$REAL_USER"
fi

# -----------------------------------------------------------------------------
# 3. NVMe: locate, verify, mount — NON-DESTRUCTIVE, no formatting ever
# -----------------------------------------------------------------------------
log "Locating NVMe..."
NVME_DEV=""
for d in /dev/nvme0n1 /dev/nvme1n1; do
    [[ -b "$d" ]] && NVME_DEV="$d" && break
done
[[ -n "$NVME_DEV" ]] || die "No NVMe block device found. Check the M.2 HAT ribbon/seating and 'dmesg | grep -i nvme'."

# Prefer first partition; fall back to whole-disk filesystem
PART=""
if [[ -b "${NVME_DEV}p1" ]]; then
    PART="${NVME_DEV}p1"
elif blkid -o value -s TYPE "$NVME_DEV" >/dev/null 2>&1; then
    PART="$NVME_DEV"
fi
[[ -n "$PART" ]] || die "NVMe found ($NVME_DEV) but no partition/filesystem detected.
This script will NOT format anything (your recordings live here).
If this is genuinely a brand-new blank drive, partition it manually:
    sudo parted $NVME_DEV mklabel gpt mkpart primary ext4 0% 100%
    sudo mkfs.ext4 -L nvr ${NVME_DEV}p1
then re-run this script."

FSTYPE="$(blkid -o value -s TYPE "$PART" || true)"
[[ "$FSTYPE" == "ext4" ]] || die "Filesystem on $PART is '${FSTYPE:-none}', expected ext4. Refusing to touch it — investigate manually."

PARTUUID="$(blkid -o value -s PARTUUID "$PART" || true)"
if [[ -n "$PARTUUID" ]]; then
    FSTAB_SRC="PARTUUID=${PARTUUID}"
else
    FSTAB_SRC="UUID=$(blkid -o value -s UUID "$PART")"
fi

mkdir -p "$NVME_MOUNT"
if ! grep -qs " ${NVME_MOUNT} " /etc/fstab; then
    log "Adding fstab entry for $PART -> $NVME_MOUNT"
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    echo "${FSTAB_SRC}  ${NVME_MOUNT}  ext4  defaults,noatime,nofail  0  2" >> /etc/fstab
    systemctl daemon-reload
else
    log "fstab entry for $NVME_MOUNT already present"
fi

mountpoint -q "$NVME_MOUNT" || mount "$NVME_MOUNT"
mountpoint -q "$NVME_MOUNT" || die "Failed to mount $PART at $NVME_MOUNT"
log "NVMe mounted: $(df -h --output=size,used,avail "$NVME_MOUNT" | tail -1 | xargs)"

# Existing recordings are preserved — mkdir -p only creates what's missing.
mkdir -p "${FRIGATE_DATA}/recordings"

# -----------------------------------------------------------------------------
# 4. Optional: PCIe gen3 (faster NVMe throughput; skip if drive misbehaves)
# -----------------------------------------------------------------------------
if $PCIE_GEN3 && [[ -f "$BOOT_CONFIG" ]]; then
    if ! grep -q "^dtparam=pciex1_gen=3" "$BOOT_CONFIG"; then
        log "Enabling PCIe gen3 in $BOOT_CONFIG (takes effect after reboot)"
        printf "\n# NVMe PCIe gen3 (added by nvr setup.sh)\ndtparam=pciex1_gen=3\n" >> "$BOOT_CONFIG"
    else
        log "PCIe gen3 already enabled"
    fi
fi

# -----------------------------------------------------------------------------
# 5. Remote desktop: wayvnc, configured for RealVNC Viewer compatibility
#
# Current Pi OS (Wayland default) no longer ships RealVNC Server; the built-in
# VNC server is wayvnc. RealVNC *Viewer* still works against it, but only with
# RSA-AES auth enabled (wayvnc >= 0.7) and an IPv4 listen address — the
# defaults (VeNCrypt/TLS, address=::) are incompatible / IPv6-only.
# -----------------------------------------------------------------------------
WAYVNC_CONF="/etc/wayvnc/config"

set_wayvnc_opt() {  # set_wayvnc_opt key value — idempotent key=value editor
    local key="$1" val="$2"
    if grep -q "^#\?${key}=" "$WAYVNC_CONF" 2>/dev/null; then
        sed -i "s|^#\?${key}=.*|${key}=${val}|" "$WAYVNC_CONF"
    else
        echo "${key}=${val}" >> "$WAYVNC_CONF"
    fi
}

if [[ -f /boot/firmware/config.txt ]] && systemctl list-unit-files --type=target 2>/dev/null | grep -q graphical.target; then
    if command -v raspi-config >/dev/null 2>&1; then
        log "Enabling VNC via raspi-config (wayvnc)..."
        raspi-config nonint do_vnc 0 || warn "raspi-config do_vnc failed — is a desktop session installed? (Lite images have no compositor for wayvnc)"
    fi

    if command -v wayvnc >/dev/null 2>&1 && [[ -d /etc/wayvnc || -f "$WAYVNC_CONF" ]]; then
        mkdir -p /etc/wayvnc
        [[ -f "$WAYVNC_CONF" ]] && cp "$WAYVNC_CONF" "${WAYVNC_CONF}.bak.$(date +%s)" || touch "$WAYVNC_CONF"

        # RSA key for RSA-AES auth (the scheme RealVNC Viewer supports)
        if [[ ! -f /etc/wayvnc/rsa_key.pem ]]; then
            log "Generating wayvnc RSA key for RealVNC Viewer auth..."
            ssh-keygen -m pem -f /etc/wayvnc/rsa_key.pem -t rsa -N "" -q
        fi

        set_wayvnc_opt use_relative_paths true
        set_wayvnc_opt enable_auth true
        set_wayvnc_opt enable_pam true              # log in with the Pi's own user/password
        set_wayvnc_opt rsa_private_key_file rsa_key.pem
        set_wayvnc_opt address 0.0.0.0              # default '::' is IPv6-only; RealVNC Viewer can't reach it
        set_wayvnc_opt port 5900

        systemctl enable wayvnc 2>/dev/null || true
        systemctl restart wayvnc 2>/dev/null || warn "Couldn't restart wayvnc service — it may start with the desktop session instead"
        log "VNC ready: connect RealVNC Viewer to $(hostname -I | awk '{print $1}'):5900 (Pi username/password)"
    else
        warn "wayvnc not present — VNC skipped. Install the desktop ('sudo apt install rpd-wayland-all' or reflash with the desktop image) and re-run."
    fi
else
    warn "No graphical target detected (Lite image?) — VNC setup skipped."
fi

# -----------------------------------------------------------------------------
# 6. Frigate appdata + secrets
# -----------------------------------------------------------------------------
CONFIG_DIR="${REPO_DIR}/config"
mkdir -p "$CONFIG_DIR"

if [[ ! -f "${CONFIG_DIR}/config.yml" ]]; then
    if [[ -f "${REPO_DIR}/config.yml.example" ]]; then
        log "No config/config.yml found — seeding from config.yml.example"
        cp "${REPO_DIR}/config.yml.example" "${CONFIG_DIR}/config.yml"
    else
        warn "No config/config.yml and no example template. Frigate will start with defaults."
    fi
else
    log "Existing config/config.yml preserved"
fi

# Make sure the UPS keys exist in .env.example so a fresh clone knows about them
if [[ -f "${REPO_DIR}/.env.example" ]] && ! grep -q '^UPS_SERVER=' "${REPO_DIR}/.env.example"; then
    log "Adding UPS_* keys to .env.example"
    cat >> "${REPO_DIR}/.env.example" <<'EOF'

# --- UPS / NUT (this Pi is a NUT *secondary*; the UPS is on the NUT primary) ---
# Leave blank to skip UPS configuration entirely.
UPS_NAME=cyberpower
UPS_SERVER=XXX.XXX.XXX.XXX
UPS_USER=upsmon-pi
UPS_PASSWORD=changeme
EOF
fi

if [[ ! -f "${REPO_DIR}/.env" ]]; then
    cp "${REPO_DIR}/.env.example" "${REPO_DIR}/.env"
    chmod 600 "${REPO_DIR}/.env"
    chown "$REAL_USER":"$REAL_USER" "${REPO_DIR}/.env"
    die "Created .env from template. Fill in FRIGATE_RTSP_PASSWORD, CLOUDFLARE_TUNNEL_TOKEN and UPS_PASSWORD in ${REPO_DIR}/.env, then re-run this script."
fi

# -----------------------------------------------------------------------------
# 7. UPS monitoring — NUT secondary (nut-client only)
#
# The UPS is plugged into the NUT *primary* (the Debian NAS). This Pi runs
# upsmon in secondary mode: it watches the primary over the LAN and, when the
# primary declares FSD, tears down the Frigate stack and halts. The primary
# waits (HOSTSYNC) for us to disconnect before it powers the UPS outlets off.
#
# NOTE: this creates a LAN dependency — the router must be on UPS battery too,
# or this Pi never hears about the outage.
# -----------------------------------------------------------------------------
if $SKIP_UPS; then
    warn "--skip-ups given — UPS/NUT configuration skipped."
else
    # Read UPS_* keys out of .env WITHOUT sourcing it. Sourcing would execute
    # the file, and .env values are conventionally unquoted — a password
    # containing '#', '$', spaces or '(' would either be mangled or run as a
    # command. This parser only ever does string assignment.
    read_env_var() {   # read_env_var FILE KEY -> value on stdout
        local f="$1" k="$2" line
        [[ -f "$f" ]] || return 0
        line="$(grep -m1 -E "^[[:space:]]*${k}=" "$f" || true)"
        [[ -n "$line" ]] || return 0
        line="${line#*=}"
        line="${line%\"}"; line="${line#\"}"      # strip paired double quotes
        line="${line%\'}"; line="${line#\'}"      # strip paired single quotes
        printf '%s' "$line"
    }

    UPS_NAME="$(read_env_var "${REPO_DIR}/.env" UPS_NAME)"
    UPS_SERVER="$(read_env_var "${REPO_DIR}/.env" UPS_SERVER)"
    UPS_USER="$(read_env_var "${REPO_DIR}/.env" UPS_USER)"
    UPS_PASSWORD="$(read_env_var "${REPO_DIR}/.env" UPS_PASSWORD)"
    UPS_NAME="${UPS_NAME:-cyberpower}"
    UPS_USER="${UPS_USER:-upsmon-pi}"

    if [[ -z "$UPS_SERVER" || -z "$UPS_PASSWORD" ]]; then
        warn "UPS_SERVER / UPS_PASSWORD not set in .env — skipping NUT setup."
        warn "Fill them in and re-run to enable coordinated UPS shutdown."
    else
        log "Configuring NUT secondary against ${UPS_NAME}@${UPS_SERVER}..."
        apt-get install -y -qq nut-client

        # --- 7a. /run/nut tmpfiles ---
        # Pi OS's nut-client omits nut-common-tmpfiles.conf, so /run/nut is never
        # created and upsmon can't write its PID file. That silently breaks
        # 'upsmon -c fsd' and 'upsmon -c reload'. Provide it ourselves.
        if [[ ! -f /usr/lib/tmpfiles.d/nut-common-tmpfiles.conf ]] \
           && [[ ! -f /etc/tmpfiles.d/nut-common-tmpfiles.conf ]]; then
            log "Creating /etc/tmpfiles.d/nut-common-tmpfiles.conf (missing on Pi OS)"
            cat > /etc/tmpfiles.d/nut-common-tmpfiles.conf <<'EOF'
# Runtime state directory for NUT. Upstream ships this as
# /usr/lib/tmpfiles.d/nut-common-tmpfiles.conf; Pi OS's nut-client omits it.
d /run/nut 0770 root nut -
EOF
        fi
        systemd-tmpfiles --create /etc/tmpfiles.d/nut-common-tmpfiles.conf 2>/dev/null || true
        [[ -d /run/nut ]] || { mkdir -p /run/nut; chown root:nut /run/nut; chmod 0770 /run/nut; }

        # --- 7b. nut.conf: netclient mode ---
        if grep -q '^MODE=netclient' /etc/nut/nut.conf 2>/dev/null; then
            log "nut.conf already in netclient mode"
        else
            cp /etc/nut/nut.conf "/etc/nut/nut.conf.bak.$(date +%s)" 2>/dev/null || true
            sed -i 's/^MODE=.*/MODE=netclient/' /etc/nut/nut.conf 2>/dev/null || true
            grep -q '^MODE=' /etc/nut/nut.conf 2>/dev/null || echo "MODE=netclient" >> /etc/nut/nut.conf
        fi

        # --- 7c. Shutdown script ---
        # upsmon does NOT validate SHUTDOWNCMD at startup: a missing or
        # non-executable script looks perfectly healthy until the one moment it
        # matters. Written before upsmon.conf references it, deliberately.
        log "Installing /usr/local/sbin/ups-shutdown-pi.sh"
        cat > /usr/local/sbin/ups-shutdown-pi.sh <<EOF
#!/usr/bin/env bash
# Called by upsmon as SHUTDOWNCMD when the NUT primary declares FSD.
# Generated by NVR setup.sh — re-run setup.sh to regenerate.
#
# Dry run (does everything except the final poweroff):
#   sudo UPS_SHUTDOWN_DRYRUN=1 /usr/local/sbin/ups-shutdown-pi.sh
set -u
exec >>/var/log/ups-shutdown.log 2>&1

DRYRUN="\${UPS_SHUTDOWN_DRYRUN:-0}"
STACK_DIR="${REPO_DIR}"
NVME_MOUNT="${NVME_MOUNT}"

echo "=== \$(date -Is) UPS shutdown (secondary), dryrun=\${DRYRUN} ==="

if [ -d "\$STACK_DIR" ]; then
    echo "--- stopping Frigate stack: \$STACK_DIR"
    timeout 60 docker compose --project-directory "\$STACK_DIR" down --timeout 45 \\
        || echo "WARN: compose down failed or timed out"
fi

remaining=\$(docker ps -q)
if [ -n "\$remaining" ]; then
    echo "WARN: forcing remaining containers: \$remaining"
    timeout 25 docker stop -t 15 \$remaining || true
fi

systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
sync

# Flush recordings to the NVMe. Unmount is best-effort: ext4 replays its
# journal on the next boot, so a lazy unmount here is not a data risk.
if mountpoint -q "\$NVME_MOUNT"; then
    if umount "\$NVME_MOUNT" 2>/dev/null; then
        echo "unmounted cleanly: \$NVME_MOUNT"
    else
        echo "WARN: busy, forcing: \$NVME_MOUNT"
        fuser -km "\$NVME_MOUNT" 2>/dev/null
        sleep 3
        umount -l "\$NVME_MOUNT" 2>/dev/null && echo "lazy-unmounted: \$NVME_MOUNT"
    fi
fi

sync
if [ "\$DRYRUN" = "1" ]; then
    echo "=== DRY RUN: teardown complete, NOT powering off ==="
    exit 0
fi
echo "=== teardown complete, powering off ==="
/sbin/shutdown -h +0
EOF
        chmod 750 /usr/local/sbin/ups-shutdown-pi.sh
        touch /var/log/ups-shutdown.log
        chmod 640 /var/log/ups-shutdown.log

        # --- 7d. upsmon.conf ---
        # Write a purpose-built file rather than appending to the stock 24KB
        # template — appending risks duplicate MONITOR/MINSUPPLIES directives,
        # and upsmon takes the LAST occurrence, which is easy to get wrong.
        if [[ -f /etc/nut/upsmon.conf ]] && ! grep -q 'generated by NVR setup.sh' /etc/nut/upsmon.conf; then
            cp /etc/nut/upsmon.conf "/etc/nut/upsmon.conf.stock.$(date +%s)"
            log "Backed up stock upsmon.conf"
        fi
        cat > /etc/nut/upsmon.conf <<EOF
# generated by NVR setup.sh — edits will be overwritten on re-run.
# Secrets come from ${REPO_DIR}/.env (UPS_* keys).

MONITOR ${UPS_NAME}@${UPS_SERVER} 1 ${UPS_USER} ${UPS_PASSWORD} secondary

MINSUPPLIES 1
SHUTDOWNCMD "/usr/local/sbin/ups-shutdown-pi.sh"
POWERDOWNFLAG /etc/killpower

POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
NOCOMMWARNTIME 300
FINALDELAY 5

NOTIFYFLAG ONLINE   SYSLOG
NOTIFYFLAG ONBATT   SYSLOG
NOTIFYFLAG LOWBATT  SYSLOG
NOTIFYFLAG FSD      SYSLOG
NOTIFYFLAG COMMOK   SYSLOG
NOTIFYFLAG COMMBAD  SYSLOG
NOTIFYFLAG SHUTDOWN SYSLOG
NOTIFYFLAG NOCOMM   SYSLOG
EOF
        chown root:nut /etc/nut/upsmon.conf
        chmod 640 /etc/nut/upsmon.conf

        # --- 7e. Verify we can actually reach the primary before enabling ---
        if upsc "${UPS_NAME}@${UPS_SERVER}" >/dev/null 2>&1; then
            log "Reached ${UPS_NAME}@${UPS_SERVER} — status: $(upsc "${UPS_NAME}@${UPS_SERVER}" ups.status 2>/dev/null || echo '?')"
        else
            warn "Cannot reach ${UPS_NAME}@${UPS_SERVER}:3493."
            warn "Check on the primary: LISTEN address in upsd.conf, and that"
            warn "[${UPS_USER}] exists in upsd.users with 'upsmon secondary'."
        fi

        systemctl enable nut-monitor >/dev/null 2>&1 || true
        systemctl restart nut-monitor
        sleep 2
        if systemctl is-active --quiet nut-monitor; then
            log "nut-monitor running as secondary"
        else
            warn "nut-monitor failed — check 'journalctl -u nut-monitor -n 30'"
        fi

        # --- 7f. EEPROM sanity check (advisory only) ---
        # With POWER_OFF_ON_HALT=1 the Pi enters a deep sleep state on halt and
        # needs a real power cycle to return — which is exactly what the UPS
        # does when it re-energises its outlets. Without it the Pi may sit dark.
        if command -v rpi-eeprom-config >/dev/null 2>&1; then
            if rpi-eeprom-config | grep -q '^POWER_OFF_ON_HALT=1'; then
                log "EEPROM: POWER_OFF_ON_HALT=1 (good)"
            else
                warn "EEPROM: POWER_OFF_ON_HALT is not 1."
                warn "Set it with 'sudo -E rpi-eeprom-config --edit' so the Pi"
                warn "reliably powers back up when the UPS restores its outlets."
            fi
        fi

        log "UPS setup done. Dry-run the teardown before trusting it:"
        log "  sudo UPS_SHUTDOWN_DRYRUN=1 /usr/local/sbin/ups-shutdown-pi.sh"
    fi
fi

# -----------------------------------------------------------------------------
# 8. Launch the stack
# -----------------------------------------------------------------------------
log "Starting containers..."
cd "$REPO_DIR"
docker compose pull
docker compose up -d

log "Done. Frigate UI: http://$(hostname -I | awk '{print $1}'):5000"
log "Run ./nvr_health.sh to verify."