#!/usr/bin/env bash
# Two-layer OS-side thermal guard for the FANLESS Radeon Pro V620.
# The card has no onboard fan, its power cap is locked (250W min=max), and the BMC
# can't see it to ramp chassis fans. So the OS protects it thermally.
#
# LAYER 1 (preferred) - thermal duty-cycling: when junction >= HOT, SIGSTOP the
#   process(es) holding /dev/kfd (the ROCm/GPU compute workload) so the GPU idles
#   and cools at FULL clock capability; SIGCONT them at <= COOL. Preserves peak clocks.
# LAYER 2 (fallback/backstop) - clock cap: if no GPU process is found to pause, cap
#   clocks (manual + sclk state 1 = ~500MHz) until cool. Process-agnostic safety.
# CRIT escalation: if paused but temp still climbs to CRIT, ALSO clock-cap.
set -u
D=/sys/class/drm/card1/device                 # V620 (03:00.0); card0 is the ASPEED VGA
HW=$(echo "$D"/hwmon/hwmon*)
HOT=${HOT:-90}        # engage cooling at/above this junction temp (C)
COOL=${COOL:-82}      # release at/below this (hysteresis)
CRIT=${CRIT:-96}      # if still climbing while paused, also clock-cap
INTERVAL=${INTERVAL:-3}

state=normal          # normal | paused | capped
paused_pids=""; capped=0

junc(){ echo $(( $(cat "$HW"/temp2_input)/1000 )); }
# PIDs holding the ROCm compute node /dev/kfd (works for host or containerized procs).
# Uses fuser (~50ms); a hand-rolled /proc scan takes ~3s and reacts far too slowly,
# letting the hotspot run away before the pause fires.
gpu_pids(){
  # fuser/lsof MISS container procs (they match by device inode, which differs for a
  # bind-mounted --device node). find matches the fd symlink TARGET (/dev/kfd), which
  # works for host+container, and runs in ~30ms (a hand /proc+readlink scan took ~3s).
  find /proc/[0-9]*/fd -lname '*/kfd' 2>/dev/null | sed -n 's#/proc/\([0-9]*\)/fd/.*#\1#p' | sort -u | tr '\n' ' '
}
do_cap(){ echo manual > "$D"/power_dpm_force_performance_level 2>/dev/null; echo 1 > "$D"/pp_dpm_sclk 2>/dev/null; capped=1; }
un_cap(){ echo auto   > "$D"/power_dpm_force_performance_level 2>/dev/null; capped=0; }
resume(){ [ -n "$paused_pids" ] && kill -CONT $paused_pids 2>/dev/null; paused_pids=""; }
release(){ resume; un_cap; state=normal; }
cleanup(){ release; exit 0; }
trap cleanup TERM INT

# Startup: undo anything a previous (crashed) instance may have left behind.
un_cap
p=$(gpu_pids); [ -n "${p// /}" ] && kill -CONT $p 2>/dev/null
logger -t gpu-thermal-guard "started 2-layer (HOT=${HOT} COOL=${COOL} CRIT=${CRIT} int=${INTERVAL}s; L1=pause /dev/kfd, L2=clock-cap)"

while :; do
  t=$(junc)
  if [ "$state" = normal ] && [ "$t" -ge "$HOT" ]; then
    pids=$(gpu_pids)
    if [ -n "${pids// /}" ]; then
      kill -STOP $pids 2>/dev/null; paused_pids="$pids"; state=paused
      logger -t gpu-thermal-guard "junction ${t}C>=${HOT} -> PAUSE gpu pids:${pids}"
    else
      do_cap; state=capped
      logger -t gpu-thermal-guard "junction ${t}C>=${HOT}, no gpu proc -> CLOCK-CAP ~500MHz"
    fi
  elif [ "$state" != normal ] && [ "$t" -le "$COOL" ]; then
    logger -t gpu-thermal-guard "junction ${t}C<=${COOL} -> RELEASE (resume + auto clocks)"
    release
  elif [ "$state" = paused ] && [ "$capped" = 0 ] && [ "$t" -ge "$CRIT" ]; then
    do_cap
    logger -t gpu-thermal-guard "junction ${t}C>=${CRIT} while paused -> ALSO clock-cap (belt+suspenders)"
  fi
  sleep "$INTERVAL"
done
