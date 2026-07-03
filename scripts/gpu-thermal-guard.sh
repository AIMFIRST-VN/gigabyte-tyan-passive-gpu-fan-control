#!/usr/bin/env bash
# OS-side thermal guard for the FANLESS Radeon Pro V620.
# The card has no onboard fan (so amdgpu-fan/pwm control is impossible) and its
# power cap is locked (250W min=max). The only OS lever is clock state. This guard
# watches junction temp and, if it crosses HOT despite the chassis fans, forces the
# GPU to its low clock state until it cools back below COOL, then restores AUTO.
#
# This is a SAFETY BACKSTOP. The real cooling fix is raising the chassis fans in the
# BMC (the BMC can't read this add-in GPU, so it won't auto-ramp for it).
set -u
D=/sys/class/drm/card1/device                 # V620 (03:00.0); card0 is the BMC VGA
HW=$(echo "$D"/hwmon/hwmon*)
HOT=${HOT:-90}        # cap clocks at/above this junction temp (C)
COOL=${COOL:-82}      # restore full clocks at/below this (hysteresis)
INTERVAL=${INTERVAL:-3}
state=auto
junc(){ echo $(( $(cat "$HW"/temp2_input)/1000 )); }
set_auto(){   echo auto   > "$D"/power_dpm_force_performance_level; state=auto; }
set_capped(){ echo manual > "$D"/power_dpm_force_performance_level; echo 1 > "$D"/pp_dpm_sclk; state=capped; }  # -> 500 MHz

trap 'set_auto; exit 0' TERM INT
set_auto
logger -t gpu-thermal-guard "started (HOT=${HOT}C COOL=${COOL}C interval=${INTERVAL}s)"
while :; do
  t=$(junc)
  if [ "$state" = auto ]   && [ "$t" -ge "$HOT" ];  then set_capped; logger -t gpu-thermal-guard "junction ${t}C >= ${HOT} -> CAP to 500MHz"; fi
  if [ "$state" = capped ] && [ "$t" -le "$COOL" ]; then set_auto;   logger -t gpu-thermal-guard "junction ${t}C <= ${COOL} -> restore AUTO"; fi
  sleep "$INTERVAL"
done
