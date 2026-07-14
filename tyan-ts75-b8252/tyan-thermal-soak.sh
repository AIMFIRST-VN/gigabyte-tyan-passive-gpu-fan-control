#!/usr/bin/env bash
# tyan-thermal-soak.sh -- controlled CPU% / GPU thermal LOAD + VERIFY + monitor for the
# Tyan TS75-B8252 (S8252) with a passive Radeon Pro V620.  (Board-agnostic except the
# fan-RPM SDR sensor names.)
#
# Uses ONE general tool -- stress-ng -- for BOTH loads (no model, no VRAM juggling, no need
# to stop the vision server): --cpu-load gives a verifiable PARTIAL CPU load, --gpu drives
# the GPU via Mesa/radeonsi GL. Every few seconds it VERIFIES and prints the ACTUAL load it
# achieved -- CPU busy% (mpstat) and GPU busy% (sysfs) -- next to CPU Tctl, GPU junction/edge
# and LEFT/RIGHT fan RPM, so you get a real measured "50% CPU + 100% GPU" baseline to size
# the fan duty cap / OCR worker count against. Logs CSV, scans ECC/RAS/MCE/AER, aborts on cap.
#
# Usage:  tyan-thermal-soak.sh [gpu|cpu|both|all] [minutes] [profile]
#   env:  CPU_PCT=50   load EVERY core to 50% (default 100 = flat out) -- the point of the tool
#         NGPU=1       number of stress-ng GPU workers (default 1)
#         CARD=/sys/class/drm/card1/device  LFAN=SYS_FAN_1  RFAN=SYS_FAN_4  GABORT=100 CABORT=95
#   defaults: both 10  (profile unset = keep the current gpu-fan-control profile)
# Needs: stress-ng (both loads), sysstat/mpstat (CPU verify), ipmitool, gpu-fan-control service.
set -u
LOAD=${1:-both}; MIN=${2:-10}; PROFILE=${3:-}
CPU_PCT=${CPU_PCT:-100}; NGPU=${NGPU:-1}
GABORT=${GABORT:-100}      # GPU junction abort (Tjunction/throttle 110C)
CABORT=${CABORT:-95}       # EPYC Tctl abort (Rome Tjmax ~95C)
CARD=${CARD:-/sys/class/drm/card1/device}
LFAN=${LFAN:-SYS_FAN_1}; RFAN=${RFAN:-SYS_FAN_4}   # left(cooling) / right(far) bank sample
CSV=/var/log/tyan-soak-$(date +%Y%m%d-%H%M%S).csv
CHW=""; for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] && CHW="$h" && break; done

gj(){ echo $(( $(cat "$CARD"/hwmon/hwmon*/temp2_input 2>/dev/null||echo 0)/1000 )); }   # junction
ge(){ echo $(( $(cat "$CARD"/hwmon/hwmon*/temp1_input 2>/dev/null||echo 0)/1000 )); }   # edge
ct(){ [ -n "$CHW" ] && echo $(( $(cat "$CHW"/temp1_input 2>/dev/null||echo 0)/1000 )) || echo 0; }
gbusy(){ cat "$CARD"/gpu_busy_percent 2>/dev/null; }
cpubusy(){ LC_ALL=C mpstat 1 1 2>/dev/null | awk '/all/{i=$NF} END{if(i!="")printf "%.0f",100-i; else print "?"}'; }
fanrpm(){ ipmitool sdr type Fan 2>/dev/null | grep -m1 "$1" | grep -oE '[0-9]+ RPM' | grep -oE '[0-9]+'; }

FAULT_RE='amdgpu[^]]*(reset|hang|fault|timed? ?out|failed)|ring [a-z0-9_]+ (timeout|test failed)|GPU (fault|reset|hang)|VM_L2|VMC page fault|[Uu]ncorrectable|\b(ECC|EDC) error|RAS: |GECC|FWSM|Adapter removed|PCIe Bus Error|\bAER\b|Hardware Error|\bMCE\b'
ecc(){ cat "$CARD"/ras/*_err_count 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i} END{print s+0}'; }
kfaults(){ journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -iE "$FAULT_RE"; }

cleanup(){ pkill -f 'stress-ng' 2>/dev/null; pkill -x yes 2>/dev/null; }
trap cleanup EXIT INT TERM

if [ -n "$PROFILE" ]; then
  sed -i "s/^PROFILE=.*/PROFILE=$PROFILE/" /etc/gpu-fan-control.conf && systemctl restart gpu-fan-control && sleep 2
fi
echo "soak: load=$LOAD min=$MIN cpu_pct=$CPU_PCT ngpu=$NGPU profile=${PROFILE:-<unchanged>} csv=$CSV"

# --- build ONE stress-ng invocation for the requested loads ---
ARGS=()
case "$LOAD" in cpu|both|all) ARGS+=(--cpu "$(nproc)" --cpu-load "$CPU_PCT") ;; esac
case "$LOAD" in gpu|both|all) ARGS+=(--gpu "$NGPU") ;; esac
if [ "${#ARGS[@]}" -gt 0 ]; then
  nice -n 19 stress-ng "${ARGS[@]}" --timeout "$((MIN+1))m" --metrics-brief >/tmp/stress-ng.log 2>&1 &
fi

ALERTS=${CSV%.csv}.alerts.log; : > "$ALERTS"
echo "epoch,cpu_busy,cpu_tctl,gpu_busy,gpu_junc,gpu_edge,fan_L,fan_R,ecc_err,kfaults" > "$CSV"
echo "  time  CPU%  Tctl | GPU%  gjunc gedge |  fanL   fanR |  ecc flt"
pj=0; pc=0; START=$(date +%s); END=$((START+MIN*60)); ECC0=$(ecc)
while [ "$(date +%s)" -lt "$END" ]; do
  cb=$(cpubusy); c=$(ct); gb=$(gbusy); j=$(gj); e=$(ge); fl=$(fanrpm "$LFAN"); fr=$(fanrpm "$RFAN"); now=$(date +%s)
  ne=$(( $(ecc) - ECC0 )); nf=$(kfaults "$START" | wc -l)
  [ "$j" -gt "$pj" ] && pj=$j; [ "$c" -gt "$pc" ] && pc=$c
  echo "$now,$cb,$c,${gb:-0},$j,$e,${fl:-0},${fr:-0},$ne,$nf" >> "$CSV"
  flag=""; { [ "$ne" -gt 0 ] || [ "$nf" -gt 0 ]; } && flag="  <-- FAULT!"
  printf "  %4ds %3s%%  %3sC | %3s%%  %3sC  %3sC | %5s  %5s | %3s %2s%s\n" \
    "$((now-START))" "$cb" "$c" "${gb:-?}" "$j" "$e" "${fl:-?}" "${fr:-?}" "$ne" "$nf" "$flag"
  if [ "$j" -ge "$GABORT" ] || [ "$c" -ge "$CABORT" ]; then echo "  !! ABORT: gpu_junc=$j (cap $GABORT) cpu_tctl=$c (cap $CABORT)"; break; fi
  sleep 10
done
kfaults "$START" > "$ALERTS"; cleanup
FAULTS=$(wc -l < "$ALERTS"); ECCN=$(( $(ecc) - ECC0 ))
echo "=== done. peak GPU junction=${pj}C  peak CPU Tctl=${pc}C  ECC errors=${ECCN}  kernel faults=${FAULTS} ==="
if [ "$FAULTS" -gt 0 ] || [ "$ECCN" -gt 0 ]; then echo "--- FAULT LINES ($ALERTS) ---"; cat "$ALERTS"; else echo "  CLEAN: 0 ECC errors, 0 GPU/RAS/MCE/AER faults."; fi
echo "  CSV=$CSV  ALERTS=$ALERTS  stress-ng metrics: /tmp/stress-ng.log"
