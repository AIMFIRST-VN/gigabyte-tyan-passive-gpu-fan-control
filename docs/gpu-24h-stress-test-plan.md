# V620 24 h Full-Throttle Stress-Test Plan (gpu-server / R282-Z93)

**For review.** Goal: prove the R282-Z93 can sustain the Radeon Pro V620 at **full clocks for 24 h**
under a realistic llama.cpp workload — i.e. verify **cooling + power + stability** on server-grade hardware.

## Why this differs from the desktop bench
The original `scripts/thermal_bench.py` was written for a **consumer desktop** with weak
cooling: it *adaptively throttled* — bursting the GPU, then forcing low clocks (`pp_dpm_sclk`) with
cooldown gates (boost ≤75 °C, cooldown ≥85 °C, hard ceiling 90 °C) just to survive.

The R282-Z93 is a **2U server with high-static-pressure blowers**, so the plan is the **opposite**:
- **No adaptive throttling / no clock capping** — let the card run at its full boost clock.
- Drive it **continuously** so it stays pinned at ~100 % for the full 24 h.
- **Monitor** junction/edge temp, power, SCLK/MCLK, and utilization to confirm it **never throttles**
  and stays within spec. If temps/clocks hold steady → the server passes.

## Workload
- Model: `ornith-1.0-35b-Q4_K_M.gguf` (20 GB), fully offloaded (`-ngl 99`) — fits the 32 GB VRAM.
- Loop `llama-bench` back-to-back (large `pp` + `tg` so both compute- and bandwidth-bound phases run),
  via the official ROCm container. See `scripts/gpu-stress-full-throttle.sh`.

## Persistence (non-ephemeral)
- Runs as a **systemd service** (`llama-gpu-stress.service`, `Restart=always`, enabled on boot).
- Container is **not** `--rm`-ephemeral; Docker + the `server-rocm` image persist across reboots.
- All output + telemetry logged under `/var/log/gpu-stress/` so a reboot mid-run resumes cleanly.

## Telemetry (sampled ~5 s, logged to CSV)
- `rocm-smi` / `amd-smi`: junction (`edge`, `junction`, `mem`) temps, GPU power (W), SCLK/MCLK (MHz),
  GPU % busy, VRAM used, fan/PWM, and **any throttle status**.
- llama-bench tok/s per iteration (perf stability over time).

## Pass / fail criteria
| Metric | Pass |
|---|---|
| Junction temp | stays < ~95 °C, steady-state well below; no thermal shutdown |
| Clocks | SCLK holds high (no sustained throttle drops) |
| Throughput | tok/s stable across 24 h (no perf decay) |
| Stability | no `amdgpu` ring resets / `FWSM` / "Adapter removed" in `dmesg`; no container crash |
| Power | within card TBP; PSUs OK (BMC SEL clean) |

## Monitoring during the run
- `journalctl -u llama-gpu-stress -f` and `tail -f /var/log/gpu-stress/telemetry.csv`
- `docker logs -f llama-gpu-stress`
- BMC (`https://bmc.example.lan`) sensors + SEL for chassis-level temps/fans/power.

## Baseline
Desktop numbers are in the setup transcript; gpu-server results land in `../results/`.
Expectation: gpu-server should sustain **higher, flatter** clocks/tok/s than the throttled desktop run.
