#!/usr/bin/env bash
# One monitoring tick for the V620 GPU burn — run every minute by cron (SSH-drop proof).
# Logs telemetry, scans for NEW hardware faults, enforces a hard thermal ceiling, honors a deadline.
# The LOAD itself is a daemon-managed `gpuburn` docker container (survives drops); this tick supervises it.
D=/sys/class/drm/card1/device; HW=$(echo "$D"/hwmon/hwmon*)
LOG=/var/log/gpu-stress; mkdir -p "$LOG"
CSV="$LOG/burn-telemetry.csv"; ALERT="$LOG/burn-alerts.log"; MARK="$LOG/.dmesg_lines"; DEADLINE_F="$LOG/burn-deadline"
CEIL=${CEIL:-101}; RESUME=${RESUME:-95}   # 101 = failsafe above the GPU's own ~99C hardware throttle -> run continuous, let HW regulate
IMG=ghcr.io/ggml-org/llama.cpp:server-rocm
MODEL=/models/ornith-1.0-35b-Q4_K_M.gguf
g(){ cat "$1" 2>/dev/null || echo 0; }
now=$(date +%s); junc=$(( $(g "$HW"/temp2_input)/1000 ))
running(){ docker ps --format '{{.Names}}' | grep -qx gpuburn; }
start_load(){ docker rm -f gpuburn >/dev/null 2>&1
  docker run -d --name gpuburn --restart unless-stopped --no-healthcheck --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined \
    --group-add video -v /data/models/llm-models:/models --entrypoint bash "$IMG" \
    -c "while true; do /app/llama bench -m $MODEL -ngl 99 -p 4096 -n 256 -r 300; done" >/dev/null 2>&1; }

# deadline reached -> stop load + self-remove the cron line
if [ -f "$DEADLINE_F" ] && [ "$now" -ge "$(g "$DEADLINE_F")" ]; then
  docker rm -f gpuburn >/dev/null 2>&1
  echo "$(date +%FT%T) BURN COMPLETE (deadline) — load stopped" >> "$ALERT"
  crontab -l 2>/dev/null | grep -v gpu-burn-tick | crontab - 2>/dev/null
  exit 0
fi

# thermal ceiling / resume governor
state=run
if [ "$junc" -ge "$CEIL" ]; then docker rm -f gpuburn >/dev/null 2>&1; echo "$(date +%FT%T) ALERT junc ${junc}C >= ${CEIL} -> load paused" >> "$ALERT"; fi
if ! running && [ "$junc" -le "$RESUME" ]; then start_load; fi
running && state=run || state=cooling

# NEW hardware-fault scan (dmesg line marker so we don't re-alert)
tot=$(dmesg 2>/dev/null | wc -l); prev=$(g "$MARK"); [ "${prev:-0}" -gt "$tot" ] && prev=0
NEW=$(dmesg 2>/dev/null | tail -n +$((prev+1)) \
  | grep -iE "amdgpu.*(reset|FWSM|Adapter removed|ring .*timeout|GPU fault|VM_L2|page fault|uncorrectable|hang|xgmi|RAS)|amdgpu.*ECC.*(error|correct|fault)|pcieport.*(error|AER)|Uncorrected|mce: \[Hardware Error\]" \
  | grep -viE "ECC is (active|not presented|disabled)|GECC is enabled|MCE.*decoding enabled" | tail -4)
echo "$tot" > "$MARK"
[ -n "$NEW" ] && echo "$(date +%FT%T) ALERT dmesg: $(echo "$NEW" | tr '\n' '|')" >> "$ALERT"

# per-minute telemetry
[ -f "$CSV" ] || echo "ts,junc_C,mem_C,power_W,busy_pct,sclk_MHz,fan_rpm,state" > "$CSV"
fan=$(ipmitool sdr type Fan 2>/dev/null | head -1 | awk -F'|' '{gsub(/[^0-9]/,"",$5);print $5}')
echo "$(date +%FT%T),$junc,$(( $(g "$HW"/temp3_input)/1000 )),$(( $(g "$HW"/power1_average)/1000000 )),$(g "$D"/gpu_busy_percent),$(grep '\*' "$D"/pp_dpm_sclk 2>/dev/null|grep -oE '[0-9]+Mhz'|head -1|tr -d 'Mhz'),${fan:-0},$state" >> "$CSV"
