#!/usr/bin/env bash
# Short RAMP-UP load test for the V620 via the running llama-server (:8080),
# BEFORE committing to the 24h burn-in. Gradually increases concurrency/length,
# samples host GPU telemetry (temp/power/clocks/busy) each step, and checks
# dmesg for amdgpu faults. Server has proper cooling -> we watch it climb + hold.
set -u
URL="http://localhost:8080/completion"
D=/sys/class/drm/card1/device            # V620 (03:00.0); card0 is the BMC VGA
HW=$(echo $D/hwmon/hwmon*)
g(){ cat "$1" 2>/dev/null || echo 0; }
sample(){ printf "%s  busy=%s%%  pwr=%sW  edge=%sC  junc=%sC  mem=%sC  sclk=%s\n" \
  "$(date +%T)" "$(g $D/gpu_busy_percent)" "$(( $(g $HW/power1_average)/1000000 ))" \
  "$(( $(g $HW/temp1_input)/1000 ))" "$(( $(g $HW/temp2_input)/1000 ))" "$(( $(g $HW/temp3_input)/1000 ))" \
  "$(grep '\*' $D/pp_dpm_sclk | grep -oE '[0-9]+Mhz' | head -1)"; }
req(){ curl -s "$URL" -H 'Content-Type: application/json' \
  -d "{\"prompt\":\"Write a long detailed technical essay about datacenter GPU computing, memory bandwidth, and thermal design:\",\"n_predict\":$1}" -o /dev/null; }
phase(){ local label="$1" conc="$2" np="$3" dur="$4" end; echo "=== $label: ${conc}x concurrent, n_predict=$np, ${dur}s ==="
  end=$(( $(date +%s)+dur )); while [ "$(date +%s)" -lt "$end" ]; do for c in $(seq 1 "$conc"); do req "$np" & done; wait; sample; done; }

echo ">>> RAMP TEST start $(date)"; sample
phase "Phase 1 warm-up"   1 64  30
phase "Phase 2 light"     2 256 45
phase "Phase 3 sustained" 2 512 60
phase "Phase 4 heavy"     4 512 60
echo ">>> peak:"; sample
echo ">>> amdgpu faults during test?"; dmesg | grep -i amdgpu | grep -iE "error|reset|FWSM|removed|throttl" | tail -6 || echo "none"
echo ">>> RAMP TEST done $(date)"
