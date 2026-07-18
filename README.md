# Pi 5 NVR — Frigate on NVMe

Rebuild-from-scratch repo for the Pi 5 NVR. Designed for the failure mode where
the SD card dies and the OS must be reflashed while **all recordings on the
NVMe survive untouched**. `setup.sh` never formats or deletes anything.

## Layout

```
setup.sh            # one-shot bootstrap (idempotent, non-destructive)
nvr_health.sh       # diagnostics; exit 0 = healthy, 1 = failure (cron-friendly)
docker-compose.yml  # frigate + cloudflared; secrets injected from .env
.env.example        # template for secrets (copy to .env, chmod 600)
config/             # Frigate appdata (config.yml + its SQLite DB live here)
```

## Disaster-recovery runbook (SD card death)

1. Flash Raspberry Pi OS Lite 64-bit to a new SD card, boot, get on the network.
2. Clone this repo (or restore it from backup):
   `git clone <repo> && cd nvr-repo`
3. `cp .env.example .env` and fill in the RTSP password and Cloudflare tunnel
   token, then `chmod 600 .env`.
4. Nothing to restore for camera config — `setup.sh` seeds `config/config.yml`
   from the tracked `config.yml.example`. (The SQLite DB / past event metadata
   in `config/` is lost with the SD card, but recordings on NVMe survive.)
5. `sudo ./setup.sh`
   - Installs Docker + tooling
   - Finds the existing ext4 partition on the NVMe and mounts it at
     `/mnt/nvme` via fstab (PARTUUID, `nofail`) — **no formatting, ever**
   - Starts the compose stack
6. `./nvr_health.sh` to verify. Frigate UI at `http://<pi-ip>:5000`.

Optional: `sudo ./setup.sh --pcie-gen3` to force PCIe gen3 for the NVMe
(higher throughput; revert if the drive throws I/O errors — some drives are
unstable at gen3 on the Pi 5).

## Remote desktop (RealVNC Viewer)

Current Raspberry Pi OS no longer ships RealVNC *Server* (the desktop moved to
Wayland; `vncserver-x11-serviced` is gone). The built-in server is **wayvnc**,
and RealVNC *Viewer* connects to it fine once two defaults are fixed, which
`setup.sh` handles automatically:

- Enables RSA-AES auth (generates `/etc/wayvnc/rsa_key.pem`) — wayvnc's default
  VeNCrypt/TLS scheme is incompatible with RealVNC Viewer.
- Sets `address=0.0.0.0` — the default `::` listens IPv6-only, which shows up
  in RealVNC Viewer as "no route to host".

Connect with RealVNC Viewer to `<pi-ip>:5900` and authenticate with the Pi's
own username/password (PAM). First connection will show an "unsigned identity"
prompt — expected, accept it.

Requires the **desktop image** (or `rpd-wayland-all` installed); on Lite there
is no compositor and the script skips VNC with a warning. Headless with no
monitor attached: wayvnc serves a virtual `NOOP-1` display; set its resolution
via the desktop's Screen Configuration tool if it comes up tiny.

## Notes

- `config.yml.example` is the tracked, sanitized camera config. `setup.sh`
  seeds `config/config.yml` from it on first run (never overwrites an
  existing one). RTSP creds are injected at runtime via Frigate's
  `{FRIGATE_RTSP_PASSWORD}` env substitution — safe to commit.
- The old Hailo/GPU install script has been removed; no accelerator drivers
  are needed. The config uses a CPU detector.
- `ffmpeg.hwaccel_args: preset-rpi-64-h264` was removed from the config: it
  targets the Pi 4's V4L2 decoder, which doesn't exist on the Pi 5 (no H.264
  hardware decode block). H.264 decode is CPU-only on this box. If the
  cameras are ever switched to H.265, use `preset-rpi-64-h265` — the Pi 5
  does have an HEVC decoder, and `/dev/dri` is already mapped for it.
- `privileged: true` and the `/dev/video11` mapping were dropped from the
  compose file: the Pi 5 has no H.264 hardware decode block (`/dev/video11`
  is a Pi 4 artifact), and nothing in this stack needs privileged mode.
  `/dev/dri` is kept for the HEVC decoder if you use `preset-rpi-64-h265`.
- `nvr_health.sh` checks undervoltage/throttle flags (`vcgencmd`) and NVMe
  SMART media errors — both relevant to the prior PSU-brownout failure.
- Suggested cron: `*/30 * * * * /home/<user>/nvr-repo/nvr_health.sh >> /var/log/nvr_health.log 2>&1`
