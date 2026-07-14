#!/usr/bin/env bash
# gpu-fan-control.sh -- temperature-driven chassis fan control for Tyan boards exposing the
# Tyan OEM IPMI fan interface (netfn 0x2e, IANA fd 19 00). Fully IN-BAND (/dev/ipmi0); NO BMC
# network needed. Built for a passive Radeon Pro V620 the BMC can't see, but AUTO-DETECTS AND
# COVERS ALL: AMD GPUs (core + VRAM), CPU sockets, NVMe SSDs, and system memory (BMC UMC/DIMM).
#
# Fan duty = max over every device's per-type curve, PLUS a profile-independent SAFETY VALVE
# (cascade) that forces fans toward 100% as ANY device nears its limit -- mirrors the R282
# fankit "CPU>=91C -> all fans 100%" critical tier, generalized. Pairs with gpu-thermal-guard.
# The hardware thermal throttle / THERMTRIP shutdown remains the ultimate backstop.
#
# Chassis fans SYS_FAN_1..6 -> PWM IDs 2,3,4,5,6,0 (PWM 1,7 = empty CPU_FAN headers).
set -u
CONF=/etc/gpu-fan-control.conf; [ -f "$CONF" ] && . "$CONF"
PROFILE=${PROFILE:-max-quiet}; INTERVAL=${INTERVAL:-4}
PWMS="2 3 4 5 6 0"; IANA="0xfd 0x19 0x00"
# Left/right split (chassis, seen from the FRONT): SYS_FAN_1..3 = PWM 2,3,4 (LEFT, over the GPU) do the cooling;
# SYS_FAN_4..6 = PWM 5,6,0 (RIGHT) run minimal for noise. The SAFETY VALVE overrides BOTH toward 100%.
LEFT_PWMS="${LEFT_PWMS:-2 3 4}"; RIGHT_PWMS="${RIGHT_PWMS:-5 6 0}"
RIGHT_BOOST=${RIGHT_BOOST:-10}      # right bank runs this many % ABOVE the left. With the chassis half-taped the
                                    # right-side air travels further to reach the GPU, so it pushes harder for the
                                    # same cooling. Right can exceed MAX_DUTY by this margin (up to 100%).
# Day/night noise CAP on the (left) cooling fans -- host clock is Asia/Ho_Chi_Minh. Quieter at night; the GPU
# temp-gate on the app side paces work so a capped fan doesn't overheat (the valve is the hard safety net).
DAY_START=${DAY_START:-7}; DAY_END=${DAY_END:-19}; DAY_CAP=${DAY_CAP:-50}; NIGHT_CAP=${NIGHT_CAP:-25}
# HARD ceiling on EVERY bank, including the safety valve — a noise budget. GPU thermal is instead managed by
# the Laravel request temp-gate (paces calls) + gpu-thermal-guard (SIGSTOPs the GPU proc at CRIT); we accept
# ~100°C rather than let fans scream. Set MAX_DUTY=100 to restore valve-to-full behaviour.
MAX_DUTY=${MAX_DUTY:-50}
MEM_EVERY=${MEM_EVERY:-6}          # re-read BMC memory temps every N loops (ipmitool SDR is slow)

# ---- discover every AMD GPU / CPU socket / NVMe ----
GPUS=""; for c in /sys/class/drm/card[0-9]*; do
  [ "$(basename "$(readlink "$c/device/driver" 2>/dev/null)" 2>/dev/null)" = amdgpu ] && GPUS="$GPUS $c/device"; done
CHWS=""; NVMES=""
for h in /sys/class/hwmon/hwmon*; do case "$(cat "$h/name" 2>/dev/null)" in
  k10temp) CHWS="$CHWS $h" ;; nvme) NVMES="$NVMES $h" ;; esac; done

# ---- temp readers: MAX across every device (Celsius) ----
_max(){ local m=0 v f; for f in $1; do v=$(cat "$f" 2>/dev/null); v=$(( ${v:-0}/1000 )); [ "$v" -gt "$m" ] && m=$v; done; echo "$m"; }
gpu_edge(){ local a=""; for d in $GPUS; do a="$a $d/hwmon/hwmon*/temp1_input"; done; _max "$a"; }  # edge -> curve
gpu_junc(){ local a=""; for d in $GPUS; do a="$a $d/hwmon/hwmon*/temp2_input"; done; _max "$a"; }  # junction -> valve
gpu_vram(){ local a=""; for d in $GPUS; do a="$a $d/hwmon/hwmon*/temp3_input"; done; _max "$a"; }  # VRAM -> valve
cpu_temp(){ local a=""; for h in $CHWS; do a="$a $h/temp1_input"; done; _max "$a"; }
nvme_temp(){ local a=""; for h in $NVMES; do a="$a $h/temp1_input"; done; _max "$a"; }
mem_read(){ timeout 6 ipmitool sdr type Temperature 2>/dev/null | grep -iE "UMC_CH|DIMM_MOSFET" | grep -oE "[0-9]+ degrees" | grep -oE "^[0-9]+" | sort -rn | head -1; }

# ---- profile curves: ascending "tempC:duty%" ----
gpu_curve(){ case "$PROFILE" in
  max-performance) echo "40:45 55:72 68:100" ;; performance) echo "42:32 60:58 72:85 80:100" ;;
  balanced) echo "44:22 68:45 80:75 88:100" ;; max-quiet) echo "44:15 82:22 92:55 97:100" ;;
  *) echo "44:22 68:45 80:75 88:100" ;; esac; }
cpu_curve(){ case "$PROFILE" in
  max-performance) echo "45:45 65:75 80:100" ;; max-quiet) echo "55:15 80:40 90:100" ;;
  *) echo "50:22 72:55 85:100" ;; esac; }
nvme_curve(){ case "$PROFILE" in
  max-performance) echo "45:40 60:70 70:100" ;; max-quiet) echo "55:15 68:35 74:70 78:100" ;;
  *) echo "50:20 65:50 72:80 78:100" ;; esac; }
mem_curve(){ case "$PROFILE" in
  max-performance) echo "45:35 65:70 78:100" ;; max-quiet) echo "55:12 72:30 82:70 86:100" ;;
  *) echo "50:18 68:45 78:80 84:100" ;; esac; }

interp(){ local t=$1 pT=0 pD=0 T Dd; for p in $2; do T=${p%:*}; Dd=${p#*:}
  if [ "$t" -le "$T" ]; then [ "$pT" -eq 0 ] && { echo "$Dd"; return; }; echo $(( pD + (Dd-pD)*(t-pT)/(T-pT) )); return; fi
  pT=$T; pD=$Dd; done; echo "$pD"; }

# ---- SAFETY VALVE (profile-independent cascade) ----
CPU_CRIT_LO=${CPU_CRIT_LO:-82};   CPU_CRIT_HI=${CPU_CRIT_HI:-91}    # R282 fankit used 91C CPU -> 100%
GPU_CRIT_LO=${GPU_CRIT_LO:-92};   GPU_CRIT_HI=${GPU_CRIT_HI:-100}   # GPU junction (Tjmax 110)
VRAM_CRIT_LO=${VRAM_CRIT_LO:-94}; VRAM_CRIT_HI=${VRAM_CRIT_HI:-100} # GDDR6 (~105C max)
NVME_CRIT_LO=${NVME_CRIT_LO:-74}; NVME_CRIT_HI=${NVME_CRIT_HI:-82}
MEM_CRIT_LO=${MEM_CRIT_LO:-80};   MEM_CRIT_HI=${MEM_CRIT_HI:-88}
ramp(){ [ "$1" -lt "$2" ] && { echo 0; return; }; local d=$(( 30 + 70*($1-$2)/($3-$2) )); [ "$d" -gt 100 ] && d=100; echo "$d"; }
valve(){ local m=0 x   # args: cpu gpu_junc vram nvme mem
  for x in "$(ramp "$1" $CPU_CRIT_LO $CPU_CRIT_HI)" "$(ramp "$2" $GPU_CRIT_LO $GPU_CRIT_HI)" "$(ramp "$3" $VRAM_CRIT_LO $VRAM_CRIT_HI)" "$(ramp "$4" $NVME_CRIT_LO $NVME_CRIT_HI)" "$(ramp "$5" $MEM_CRIT_LO $MEM_CRIT_HI)"; do
    [ "$x" -gt "$m" ] && m=$x; done; echo "$m"; }

# Time-of-day cap on the cooling fans (host TZ = ICT). Day [DAY_START,DAY_END) => DAY_CAP, else NIGHT_CAP.
day_cap(){ local h; h=$(date +%H); h=${h#0}; h=${h:-0}
  if [ "$h" -ge "$DAY_START" ] && [ "$h" -lt "$DAY_END" ]; then echo "$DAY_CAP"; else echo "$NIGHT_CAP"; fi; }

setfan(){ timeout 5 ipmitool raw 0x2e 0x05 $IANA "$1" "$2" >/dev/null 2>&1; }
restore(){ for p in $PWMS; do timeout 5 ipmitool raw 0x2e 0x05 $IANA "$p" 0xff >/dev/null 2>&1; done; }
trap 'restore; exit 0' TERM INT

logger -t gpu-fan-control "started profile=$PROFILE int=${INTERVAL}s gpus=$(echo $GPUS|wc -w) cpu_sockets=$(echo $CHWS|wc -w) nvme=$(echo $NVMES|wc -w)"
SDN=$(command -v systemd-notify 2>/dev/null); [ -n "$SDN" ] && "$SDN" --ready 2>/dev/null   # Type=notify readiness
lastL=-1; lastR=-1; i=0; mt=0
while :; do
  [ -n "$SDN" ] && "$SDN" WATCHDOG=1 2>/dev/null                                            # heartbeat (WatchdogSec)
  [ $(( i % MEM_EVERY )) -eq 0 ] && mt=$(mem_read); mt=${mt:-0}; i=$((i+1))
  ge=$(gpu_edge); gj=$(gpu_junc); gv=$(gpu_vram); ct=$(cpu_temp); nt=$(nvme_temp)
  dg=$(interp "$ge" "$(gpu_curve)"); dc=$(interp "$ct" "$(cpu_curve)"); dn=$(interp "$nt" "$(nvme_curve)"); dm=$(interp "$mt" "$(mem_curve)"); dv=$(valve "$ct" "$gj" "$gv" "$nt" "$mt")
  # cooling duty from the curves (NO valve yet — the valve is allowed to EXCEED the noise cap)
  dcool=$dg; for x in $dc $dn $dm; do [ "$x" -gt "$dcool" ] && dcool=$x; done
  cap=$(day_cap); [ "$dcool" -gt "$cap" ] && dcool=$cap          # day/night noise cap on the cooling bank
  # LEFT bank cools (capped); RIGHT bank stays minimal for noise; the safety VALVE overrides BOTH.
  dl=$dcool; [ "$dv" -gt "$dl" ] && dl=$dv
  # HARD ceiling (noise budget) on the LEFT bank.
  [ "$dl" -gt "$MAX_DUTY" ] && dl=$MAX_DUTY; [ "$dl" -lt 0 ] && dl=0
  # RIGHT bank runs RIGHT_BOOST points ABOVE the left (its air travels further to the GPU under the tape).
  dr=$(( dl + RIGHT_BOOST )); [ "$dr" -gt 100 ] && dr=100; [ "$dr" -lt 0 ] && dr=0
  if [ "$dl" -ne "$lastL" ] || [ "$dr" -ne "$lastR" ]; then
    hl=$(printf '0x%02x' "$dl"); hr=$(printf '0x%02x' "$dr")
    for p in $LEFT_PWMS; do setfan "$p" "$hl"; done
    for p in $RIGHT_PWMS; do setfan "$p" "$hr"; done
    logger -t gpu-fan-control "gpu=${ge}/${gj}/vram${gv} cpu=${ct} nvme=${nt} mem=${mt} -> L=${dl}% R=${dr}% (cap${cap} g$dg c$dc n$dn m$dm valve$dv)"
    lastL=$dl; lastR=$dr
  fi
  sleep "$INTERVAL"
done
