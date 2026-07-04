# Results

## Baseline — consumer desktop (adaptive `thermal_bench.py`)
The desktop run was thermally throttled (boost/cooldown gates) to survive limited cooling.
Raw llama-bench numbers are in the original setup transcript; representative baseline to be
copied here for comparison.

## gpu-server (R282-Z93) — 24h full-throttle burn-in
Populated by the burn-in run:
- `telemetry-<stamp>.csv` — rocm-smi samples (temp/power/clocks/use) every 5 s.
- `bench-<stamp>.log` — per-iteration llama-bench throughput.
- Summary (fill in after the run): peak junction temp, steady-state temp, sustained SCLK,
  tok/s mean ± drift over 24 h, any throttle/reset events (should be none = PASS).
