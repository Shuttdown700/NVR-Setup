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
4. Restore `config/config.yml` from backup if not tracked in the repo.
5. `sudo ./setup.sh`
   - Installs Docker + tooling
   - Finds the existing ext4 partition on the NVMe and mounts it at
     `/mnt/nvme` via fstab (PARTUUID, `nofail`) — **no formatting, ever**
   - Starts the compose stack
6. `./nvr_health.sh` to verify. Frigate UI at `http://<pi-ip>:5000`.

Optional: `sudo ./setup.sh --pcie-gen3` to force PCIe gen3 for the NVMe
(higher throughput; revert if the drive throws I/O errors — some drives are
unstable at gen3 on the Pi 5).

## Notes

- The old Hailo/GPU install script has been removed; no accelerator drivers
  are needed. Frigate should be configured with a CPU detector in
  `config/config.yml` (`detectors: { cpu1: { type: cpu } }`).
- `privileged: true` and the `/dev/video11` mapping were dropped from the
  compose file: the Pi 5 has no H.264 hardware decode block (`/dev/video11`
  is a Pi 4 artifact), and nothing in this stack needs privileged mode.
  `/dev/dri` is kept for the HEVC decoder if you use `preset-rpi-64-h265`.
- `nvr_health.sh` checks undervoltage/throttle flags (`vcgencmd`) and NVMe
  SMART media errors — both relevant to the prior PSU-brownout failure.
- Suggested cron: `*/30 * * * * /home/<user>/nvr-repo/nvr_health.sh >> /var/log/nvr_health.log 2>&1`
