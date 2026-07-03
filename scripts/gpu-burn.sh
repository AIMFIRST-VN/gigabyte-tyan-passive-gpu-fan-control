#!/usr/bin/env bash
# GPU robustness / hardware-fault burn-in for the V620 (default 7h).
# Full-load llama.cpp bench loop + thermal-safety governor + per-minute telemetry +
# continuous HARDWARE-FAULT detection. Goal: shake out any HW issues on used hardware.
# Detached + crash-safe. Fans are controlled by the BMC (this only runs load + protects temp).
set -u
D=/sys/class/drm/card1/device; HW=$(echo "$D"/hwmon/hwmon*)
IMG=ghcr.io/ggml-org/llama.cpp:server-rocm
MODEL=/models/ornith-1.0-35b-Q4_K_M.gguf
DUR=${DUR:-25200}          # 7h
HOT=${HOT:-90}; COOL=${COOL:-80}   # governor thresholds (junction °C)
LOG=/var/log/gpu-stress; mkdir -p "$LOG"
CSV="$LOG/burn-telemetry.csv"; ALERT="$LOG/burn-alerts.log"; STAT="$LOG/burn-status.log"
junc(){ echo $(( $(cat "$HW"/temp2_input)/1000 )); }
run(){  docker rm -f gpuburn >/dev/null 2>&1
  docker run -d --name gpuburn --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined \
    --group-add video -v /data/models/llm-models:/models --entrypoint bash "$IMG" \
    -c "while true; do /app/llama bench -m $MODEL -ngl 99 -p 4096 -n 256 -r 4 2>&1 | tee -a /tmp/bench.out; done" >/dev/null 2>&1; }
stop(){ docker rm -f gpuburn >/dev/null 2>&1; }
alert(){ echo "$(date +%FT%T) ALERT: $*" >> "$ALERT"; logger -t gpu-burn "ALERT: $*"; }

: > "$ALERT"
echo "ts,junc_C,mem_C,power_W,busy_pct,sclk_MHz,fan_rpm,state" > "$CSV"
BASE=$(dmesg | wc -l)            # only catch NEW dmesg faults from here on
run; state=run; last=0; restarts=0
echo "$(date +%FT%T) BURN START dur=${DUR}s HOT=${HOT} COOL=${COOL}" > "$STAT"
END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  j=$(junc)
  # thermal governor (load-based, since the clock cap is ineffective under compute)
  if [ "$state" = run ]  && [ "$j" -ge "$HOT" ];  then stop; state=cool; echo "$(date +%T) junc ${j}C -> PAUSE" >> "$STAT"; fi
  if [ "$state" = cool ] && [ "$j" -le "$COOL" ]; then run;  state=run;  echo "$(date +%T) junc ${j}C -> RESUME" >> "$STAT"; fi
  # unexpected container death while running = a crash worth flagging
  if [ "$state" = run ] && ! docker ps --format "{{.Names}}" | grep -q gpuburn; then alert "bench container died (possible driver/GPU crash) — restarting"; run; restarts=$((restarts+1)); fi
  # NEW hardware faults in kernel log
  NEW=$(dmesg | tail -n +$((BASE+1)) | grep -iE "amdgpu.*(reset|FWSM|Adapter removed|ring .*timeout|GPU fault|VM_L2|page fault|ECC|uncorrectable|hang)|pcieport.*(error|AER)|Uncorrected|mce:" | tail -3)
  if [ -n "$NEW" ]; then alert "dmesg: $(echo "$NEW" | tr '\n' '|')"; BASE=$(dmesg | wc -l); fi
  # per-minute telemetry
  now=$(date +%s)
  if [ $(( now - last )) -ge 60 ]; then
    fan=$(ipmitool sdr type Fan 2>/dev/null | head -1 | awk -F'|' '{gsub(/[^0-9]/,"",$5);print $5}')
    echo "$(date +%FT%T),$j,$(( $(cat "$HW"/temp3_input)/1000 )),$(( $(cat "$HW"/power1_average)/1000000 )),$(cat "$D"/gpu_busy_percent),$(grep '\*' "$D"/pp_dpm_sclk|grep -oE '[0-9]+Mhz'|head -1|tr -d 'Mhz'),${fan:-0},$state" >> "$CSV"
    last=$now
  fi
  sleep 5
done
stop
echo "$(date +%FT%T) BURN COMPLETE restarts=$restarts alerts=$(wc -l < "$ALERT")" >> "$STAT"
