#!/usr/bin/env bash
# tyan-thermal-soak.sh -- GPU / CPU / combined thermal soak + live monitor for the
# Tyan TS75-B8252 (S8252) with a passive Radeon Pro V620.
#
# Drives the chassis fans via gpu-fan-control.service (optionally set a profile),
# applies the chosen load, logs GPU junction/edge + CPU Tctl + fan RPM + GPU busy to
# a CSV, prints a live table, and ABORTS if the GPU junction or CPU Tctl crosses a cap.
#
# Usage:  tyan-thermal-soak.sh [gpu|cpu|both] [minutes] [profile]
#   defaults: both  10  (leave profile unset to keep the current one)
# Needs: docker + the llama.cpp ROCm image & model (GPU load), stress-ng or coreutils
#        `yes` (CPU load), ipmitool, and the gpu-fan-control service installed.
set -u
LOAD=${1:-both}; MIN=${2:-10}; PROFILE=${3:-}
GABORT=${GABORT:-100}      # GPU junction abort (Tjunction/throttle is 110C)
CABORT=${CABORT:-95}       # EPYC Tctl abort (Rome Tjmax ~95C)
IMG=ghcr.io/ggml-org/llama.cpp:server-rocm
MODEL=/models/llm-models/ornith-1.0-35b-Q4_K_M.gguf
CARD=/sys/class/drm/card1/device
CSV=/var/log/tyan-soak-$(date +%Y%m%d-%H%M%S).csv
CHW=""; for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = k10temp ] && CHW="$h" && break; done

gj(){ echo $(( $(cat "$CARD"/hwmon/hwmon*/temp2_input 2>/dev/null||echo 0)/1000 )); }   # junction
ge(){ echo $(( $(cat "$CARD"/hwmon/hwmon*/temp1_input 2>/dev/null||echo 0)/1000 )); }   # edge
ct(){ [ -n "$CHW" ] && echo $(( $(cat "$CHW"/temp1_input 2>/dev/null||echo 0)/1000 )) || echo 0; }
fan(){ ipmitool sdr type Fan 2>/dev/null|grep -m1 SYS_FAN_1|grep -oE '[0-9]+ RPM'|grep -oE '[0-9]+'; }
gbusy(){ cat "$CARD"/gpu_busy_percent 2>/dev/null; }
# hardware-fault detection: GPU RAS/ECC error counters + kernel-log fault scan
FAULT_RE='amdgpu[^]]*(reset|hang|fault|timed? ?out|failed)|ring [a-z0-9_]+ (timeout|test failed)|GPU (fault|reset|hang)|VM_L2|VMC page fault|[Uu]ncorrectable|\b(ECC|EDC) error|RAS: |GECC|FWSM|Adapter removed|PCIe Bus Error|\bAER\b|Hardware Error|\bMCE\b'
ecc(){ cat "$CARD"/ras/*_err_count 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i} END{print s+0}'; }
kfaults(){ journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -iE "$FAULT_RE"; }

cleanup(){ docker rm -f soak-gpu >/dev/null 2>&1; pkill -f 'stress-ng' 2>/dev/null; pkill -x yes 2>/dev/null; pkill -9 -f nvmeheat 2>/dev/null; rm -f /data/.nvme_soak_test 2>/dev/null; }
trap cleanup EXIT INT TERM

if [ -n "$PROFILE" ]; then
  sed -i "s/^PROFILE=.*/PROFILE=$PROFILE/" /etc/gpu-fan-control.conf && systemctl restart gpu-fan-control && sleep 2
fi
echo "soak: load=$LOAD minutes=$MIN profile=${PROFILE:-<unchanged>} csv=$CSV"

case "$LOAD" in gpu|both)
  docker rm -f soak-gpu >/dev/null 2>&1
  docker run -d --name soak-gpu --device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined \
    --group-add video -v /opt/models:/models:ro --entrypoint bash "$IMG" \
    -c "while true; do /app/llama bench -m $MODEL -p 4096 -n 128 -ngl 99 -r 5; done" >/dev/null 2>&1 ;;
esac
case "$LOAD" in cpu|both|all)
  # nice 19 so a full-core burn never starves sshd / the fan daemon
  if command -v stress-ng >/dev/null 2>&1; then nice -n 19 stress-ng --cpu "$(nproc)" --timeout "$((MIN+1))m" >/dev/null 2>&1 &
  else for _ in $(seq 1 "$(nproc)"); do nice -n 19 timeout "$((MIN+1))m" yes >/dev/null 2>&1 & done; fi ;;
esac
case "$LOAD" in nvme|all)   # high random-IO on the boot NVMe; nice+ionice so it yields to system IO
  if command -v fio >/dev/null 2>&1; then
    nice -n 19 ionice -c3 fio --name=nvmeheat --filename=/data/.nvme_soak_test --size=4G --rw=randrw \
      --rwmixread=60 --bs=128k --iodepth=32 --numjobs=4 --direct=1 --runtime="$((MIN*60+10))" --time_based >/dev/null 2>&1 &
  else echo "  (fio not installed; skipping nvme load)"; fi ;;
esac

ALERTS=${CSV%.csv}.alerts.log; : > "$ALERTS"
echo "epoch,gpu_junc,gpu_edge,cpu_tctl,fan_rpm,gpu_busy,ecc_err,kfaults" > "$CSV"
echo "  time   gjunc gedge  cpu   fan     busy  ecc  flt"
pj=0; pc=0; START=$(date +%s); END=$((START+MIN*60)); ECC0=$(ecc)
while [ "$(date +%s)" -lt "$END" ]; do
  j=$(gj); e=$(ge); c=$(ct); f=$(fan); b=$(gbusy); now=$(date +%s)
  ne=$(( $(ecc) - ECC0 )); nf=$(kfaults "$START" | wc -l)
  [ "$j" -gt "$pj" ] && pj=$j; [ "$c" -gt "$pc" ] && pc=$c
  echo "$now,$j,$e,$c,${f:-0},${b:-0},$ne,$nf" >> "$CSV"
  flag=""; { [ "$ne" -gt 0 ] || [ "$nf" -gt 0 ]; } && flag="  <-- FAULT!"
  printf "  %4ds  %3sC  %3sC  %3sC %6s  %3s%%  %3s  %2s%s\n" "$((now-START))" "$j" "$e" "$c" "${f:-?}" "${b:-?}" "$ne" "$nf" "$flag"
  if [ "$j" -ge "$GABORT" ] || [ "$c" -ge "$CABORT" ]; then echo "  !! ABORT: gpu_junc=$j (cap $GABORT) cpu_tctl=$c (cap $CABORT)"; break; fi
  sleep 10
done
kfaults "$START" > "$ALERTS"
cleanup
FAULTS=$(wc -l < "$ALERTS"); ECCN=$(( $(ecc) - ECC0 ))
echo "=== done. peak GPU junction=${pj}C  peak CPU Tctl=${pc}C  ECC errors=${ECCN}  kernel faults=${FAULTS} ==="
if [ "$FAULTS" -gt 0 ] || [ "$ECCN" -gt 0 ]; then echo "--- FAULT LINES ($ALERTS) ---"; cat "$ALERTS"; else echo "  CLEAN: 0 ECC errors, 0 GPU/RAS/MCE/AER faults."; fi
echo "  CSV=$CSV  ALERTS=$ALERTS"
