#!/usr/bin/env bash
# Deploy the PERSISTENT (non-ephemeral) full-throttle V620 burn-in on gpu-server.
# Installs + enables two systemd services so the test survives reboots:
#   - gpu-telemetry.service   : logs rocm-smi (temp/power/clocks/use) to /var/log/gpu-stress/telemetry.csv
#   - llama-gpu-stress.service : loops llama-bench continuously at full clocks (-ngl 99), no throttling
#
# Server has proper cooling (R282-Z93 blowers) -> run flat-out, monitor that clocks/temps hold.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# PREREQS (must be in place first):
#  - Chassis fans forced high in the BMC web UI (this firmware has no scriptable fan control;
#    the BMC can't read the add-in GPU, so its auto-curve leaves fans idling -> GPU cooks).
#  - gpu-thermal-guard.service running (clock-throttle backstop).
#  - The llama-server (port 8080) is stopped first (bench needs the model's VRAM).

install -m0755 "$HERE/gpu-telemetry.sh"         /root/gpu-telemetry.sh
install -m0644 "$HERE/llama-gpu-stress.service" /etc/systemd/system/llama-gpu-stress.service
install -m0644 "$HERE/gpu-telemetry.service"    /etc/systemd/system/gpu-telemetry.service
mkdir -p /var/log/gpu-stress
docker stop llama-server 2>/dev/null || true    # free VRAM for the bench loop

systemctl daemon-reload
systemctl enable --now gpu-telemetry.service
systemctl enable --now llama-gpu-stress.service

echo "Deployed. Both services are enabled (start on boot) with Restart=always."
echo "Watch:"
echo "  journalctl -u llama-gpu-stress -f"
echo "  tail -f /var/log/gpu-stress/telemetry.csv"
echo "  dmesg -w | grep -i amdgpu     # watch for ring resets / FWSM"
echo "Stop:   systemctl disable --now llama-gpu-stress gpu-telemetry"
