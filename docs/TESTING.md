# Testing & Verification

How to prove the layered BMC fan profile actually works on a Gigabyte **MZ92-FS0**
(R282-Z9x / R182-Z9x): that it's **quiet at idle**, **ramps with GPU load**,
**respects CPU temperature**, and **holds a passive GPU cool through a long soak** —
without ever thermal-throttling or dropping power.

Four tests, cheapest first:

1. **Idle** — fans sit at the floor, room stays quiet.
2. **GPU ramp** — fans track `12V_GPU0` current up, then fall back to idle.
3. **CPU behaviour** — CPU load ramps the shared fans on its own.
4. **12 h load / soak** — dual-PSU stability at full GPU power.

> Set your BMC connection in the environment first — nothing here contains real
> hosts or credentials:
> ```bash
> export BMC_HOST=bmc.example.lan BMC_USER=admin BMC_PASS='your-bmc-password'
> ```
> The `ipmitool` examples below run **in-band on the host** (no IP needed). To
> query the BMC remotely instead, add `-I lanplus -H "$BMC_HOST" -U "$BMC_USER"`.

## 0. Before you start

- Confirm your profile is active: `python3 scripts/apply-fan-profile.py status`.
- Keep the stock backup handy (`restore stock-profile.json`) in case you need to
  revert mid-test.
- Have three things visible at once — **fan RPM**, **the trigger sensors**, and
  **GPU junction temp**:
  ```bash
  watch -n5 'ipmitool sdr type Fan; \
             ipmitool sensor | grep -E "12V_GPU0|SYS_POWER|CPU0_TEMP"'
  ```
- **Remember the fans can't stop and RPM isn't linear with PWM.** All four
  hard-floor at **~3,300 RPM**, and measured **RPM ≈ 2,900 + 131 × duty%** — so
  "idle" means the floor, not silence, and small duty changes move RPM less than
  you'd expect.

## 1. Idle verification (fans at the floor)

With the GPU idle and CPU idle:

- **GPU-side FAN1/2** should sit at their tuned idle floor (**~4,500 RPM / 12 %**
  in the reference profile — the quiet-but-safe compromise, since flooring them let
  CPU0 drift up ~10 °C).
- **FAN3/4** (empty CPU1 side) should sit at the **~3,300 RPM** hardware floor.
- `12V_GPU0` current should read near 0 A and `SYS_POWER` should be low.

```bash
ipmitool sdr type Fan                     # FAN1/2 ~4500, FAN3/4 ~3300
ipmitool sensor | grep -E "12V_GPU0|SYS_POWER"
```

**Pass:** fans at the expected floors, room is quiet, no policy is holding fans
high at room temperature. If FAN1/2 are pinned high at idle, the old
over-aggressive inlet-air floor is probably still in the profile (it ramped to
30 % at a 28 °C room) — raise that policy's start temperature.

## 2. GPU load ramp test

The core proof: fans that **follow the GPU** even though the BMC can't read its die
temperature. `scripts/ramp-test.sh` drives the running `llama-server` (port 8080)
through four increasing phases and samples host GPU telemetry each step.

In one terminal, watch the trigger and the fans:

```bash
watch -n5 'ipmitool sdr type Fan; ipmitool sensor | grep 12V_GPU0'
```

In another, run the ramp:

```bash
scripts/ramp-test.sh
```

**What to watch:**

- As the workload climbs, **`12V_GPU0` current rises (0 → ~20 A)** and
  **FAN1/2 ramp up with it** — that's the GPU-current curve doing its job.
- **FAN3/4 stay near their floor** for a single GPU (they're staged on `SYS_POWER`
  and only wake for a 2nd/3rd card).
- **GPU junction temp** (host side) stays in a comfortable band, well under
  throttle.
- **No `amdgpu` faults** — `ramp-test.sh` greps `dmesg` for
  `error|reset|FWSM|removed|throttl` at the end; it should print `none`.

**Then verify recovery:** stop the load and confirm `12V_GPU0` falls back toward
0 A and **FAN1/2 return to the idle floor** within the profile's hysteresis. A
profile that ramps but never comes back down is as wrong as one that never ramps.

**Pass:** FAN1/2 track GPU current up and back down; FAN3/4 stay quiet; junction
temp stays in spec; zero amdgpu faults.

## 3. CPU-temperature behaviour

The CPU-temp curve is the safety layer that runs *underneath* the quiet layer —
verify it ramps the shared fans on CPU heat alone, with the GPU idle:

```bash
stress-ng --cpu "$(nproc)" --timeout 300s        # GPU idle during this
watch -n5 'ipmitool sdr type Fan; ipmitool sensor | grep CPU0_TEMP'
```

**What to watch:**

- **CPU0 heats, FAN1/2 ramp** from the CPU-temp policy even though `12V_GPU0` is
  ~0 A — confirming the layers are independent and the BMC takes the **max** of
  them. (CPU0 shares its side of the chassis with the GPU, which is exactly why its
  idle floor is 12 %, not the bare 3,300 RPM floor.)
- **91 °C safety** (optional, careful): if you can legitimately push a CPU to
  91 °C, **all** fans should jump to 100 %. This override can only raise fan speed,
  never lower it — that's the whole point of the layering.

**Pass:** CPU load alone ramps FAN1/2; the 91 °C critical (if exercised) forces all
fans to 100 %.

## 4. 12-hour load / soak test (dual-PSU stability)

The big one: sustain the GPU at full clocks for **12 h** and prove the box is
stable on **cooling *and* power**. Run **PSU1 and PSU2 from separate wall sockets**
so the test also validates power delivery across two circuits (this is how you
catch a marginal socket/PSU that only fails under sustained load).

### Set it up

`scripts/gpu-stress-full-throttle.sh` installs two persistent systemd services so
the run survives a reboot mid-test:

- `llama-gpu-stress.service` — loops `llama-bench` at full clocks (`-ngl 99`), no
  throttling, `Restart=always`.
- `gpu-telemetry.service` — logs junction/edge/mem temps, power, SCLK/MCLK, GPU
  busy %, VRAM, and a fan sample to `/var/log/gpu-stress/telemetry.csv` every ~5 s.

```bash
scripts/gpu-stress-full-throttle.sh          # deploys + enables both services
```

Optionally also run the high-rate rail logger to catch any power event with detail
(`scripts/powerlog.sh` → `/data/powerlog/rails.csv`; logs 12 V rails, `12V_GPU0`,
`SYS_POWER`, GPU junction, and **uptime** so a reboot shows up as a counter reset).

### What to watch over the 12 h

| Watch | How | Want to see |
|---|---|---|
| **Continuous uptime / zero reboots** | `uptime`; `powerlog` uptime column; BMC SEL | monotonically rising uptime, **no** spontaneous power-off / reset |
| **ECC memory errors** | `dmesg \| grep -i edac`; `ipmitool sel elist` | **0 corrected / 0 uncorrected** |
| **No thermal throttle** | `bench-*.log` tok/s; `telemetry.csv` SCLK | **flat throughput** across the run = no clock droop |
| **GPU junction temp** | `telemetry.csv` `junction_C` | steady, comfortably below throttle |
| **Both PSUs healthy** | `ipmitool sdr type "Power Supply"` | both present, no PSU faults, redundant |
| **No GPU faults** | `dmesg \| grep -i amdgpu` | no ring resets / `FWSM` / "removed" |

Live monitoring:

```bash
journalctl -u llama-gpu-stress -f
tail -f /var/log/gpu-stress/telemetry.csv
dmesg -w | grep -i amdgpu
watch -n10 'ipmitool sdr type Fan; ipmitool sdr type "Power Supply"; ipmitool sel elist | tail -5'
```

The key tell is **flat throughput**: if prompt-processing tok/s stays flat for
10+ hours, the card never throttled — clock droop would show up immediately as a
throughput dip. A rising junction temp with falling tok/s is the failure you're
hunting for.

### Tear down

```bash
systemctl disable --now llama-gpu-stress gpu-telemetry
```

## Our result (reference)

A clean 12 h soak at **~650 W** system power, PSU1/PSU2 on **separate wall sockets**:

- **Zero power events** — continuous uptime, no reboots, no spontaneous power-off.
- **ECC 0/0** — no corrected or uncorrected memory errors.
- **No thermal throttle** — prompt-processing throughput **flat across 10+ hours**
  (≈1,519 tok/s), i.e. no clock droop.
- **GPU junction 57–80 °C** for the whole run.
- **Both PSUs healthy** throughout; BMC SEL clean.

That's the bar: quiet at idle, proportional under load, and rock-stable across a
long dual-PSU soak — all driven by the BMC itself, so it holds even if the host
software or the OS falls over mid-run.
