#!/bin/bash
# High-rate power/rail logger — catch the NEXT spontaneous power-off with detail.
# Samples 12V rails + GPU/CPU rails + SYS_POWER + GPU junction every ~5s to /data/powerlog/rails.csv.
# CSV lives on /data so it survives the power-off; run under systemd (Restart=always) to survive reboots.
CSV=/data/powerlog/rails.csv
mkdir -p /data/powerlog
[ -f "$CSV" ] || echo "ts,P_12V,P_12V_GPU0,P_12V_GPU1,P_12V_GPU2,VR_P0_VIN,P_5V,P_3V3,SYS_POWER_W,GPU_junc_C,GPU_pwr_W,uptime_s" > "$CSV"
val(){ printf '%s\n' "$1" | awk -F'|' -v k="$2" 'index($1,k)==1 {gsub(/[^0-9.]/,"",$2); print $2; exit}'; }
gsys(){ cat /sys/class/drm/card1/device/hwmon/hwmon*/"$1" 2>/dev/null | head -1; }
while true; do
  S="$(ipmitool sensor 2>/dev/null)"
  junc=$(( $(gsys temp2_input || echo 0) / 1000 ))
  pwr=$(( $(gsys power1_average || echo 0) / 1000000 ))
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  echo "$(date +%FT%T),$(val "$S" 'P_12V ')|$(val "$S" P_12V_GPU0),$(val "$S" P_12V_GPU1),$(val "$S" P_12V_GPU2),$(val "$S" VR_P0_VIN),$(val "$S" 'P_5V '),$(val "$S" P_3V3),$(val "$S" SYS_POWER),$junc,$pwr,$up" >> "$CSV"
  sleep 4
done
