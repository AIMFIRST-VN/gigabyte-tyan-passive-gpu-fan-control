#!/usr/bin/env bash
# Host-side V620 telemetry logger -> CSV (no container / rocm-smi needed).
# Reads amdgpu sysfs + one ipmitool fan sample every INTERVAL seconds.
set -u
D=/sys/class/drm/card1/device               # V620 (03:00.0); card0 is the BMC VGA
HW=$(echo "$D"/hwmon/hwmon*)
LOG=/var/log/gpu-stress; mkdir -p "$LOG"; CSV="$LOG/telemetry.csv"
INTERVAL=${INTERVAL:-5}
g(){ cat "$1" 2>/dev/null || echo 0; }
mhz(){ grep '\*' "$1" 2>/dev/null | grep -oE '[0-9]+Mhz' | head -1 | tr -d 'Mhz'; }
[ -f "$CSV" ] || echo "ts,busy_pct,power_W,edge_C,junction_C,mem_C,sclk_MHz,mclk_MHz,vram_used_MiB,fan1_rpm" > "$CSV"
while :; do
  fan=$(ipmitool sdr type Fan 2>/dev/null | head -1 | awk -F'|' '{gsub(/ |RPM/,"",$5);print $5}')
  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$(date +%FT%T)" "$(g "$D"/gpu_busy_percent)" "$(( $(g "$HW"/power1_average)/1000000 ))" \
    "$(( $(g "$HW"/temp1_input)/1000 ))" "$(( $(g "$HW"/temp2_input)/1000 ))" "$(( $(g "$HW"/temp3_input)/1000 ))" \
    "$(mhz "$D"/pp_dpm_sclk)" "$(mhz "$D"/pp_dpm_mclk)" "$(( $(g "$D"/mem_info_vram_used)/1048576 ))" "${fan:-0}" \
    >> "$CSV"
  sleep "$INTERVAL"
done
