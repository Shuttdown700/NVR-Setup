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
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVME_MOUNT="/mnt/nvme"
FRIGATE_DATA="${NVME_MOUNT}/frigate"
BOOT_CONFIG="/boot/firmware/config.txt"
PCIE_GEN3=false

[[ "${1:-}" == "--pcie-gen3" ]] && PCIE_GEN3=true

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

if [[ ! -f "${REPO_DIR}/.env" ]]; then
    cp "${REPO_DIR}/.env.example" "${REPO_DIR}/.env"
    chmod 600 "${REPO_DIR}/.env"
    chown "$REAL_USER":"$REAL_USER" "${REPO_DIR}/.env"
    die "Created .env from template. Fill in FRIGATE_RTSP_PASSWORD and CLOUDFLARE_TUNNEL_TOKEN in ${REPO_DIR}/.env, then re-run this script."
fi

# -----------------------------------------------------------------------------
# 7. Launch the stack
# -----------------------------------------------------------------------------
log "Starting containers..."
cd "$REPO_DIR"
docker compose pull
docker compose up -d

log "Done. Frigate UI: http://$(hostname -I | awk '{print $1}'):5000"
log "Run ./nvr_health.sh to verify."