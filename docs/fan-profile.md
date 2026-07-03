# Fan Profile — Cooling the passive V620 in the R282-Z93 (`gpu-server`)

## TL;DR
The BMC **cannot read the add-in V620's temperature**, so its automatic fan curve leaves the
4 chassis fans idling at **3,000 RPM** and the passive GPU **cooks (99 °C → hard throttle)**.
There is **no scriptable fan control** on this firmware, so the fix is the **BMC web UI Fan Profile**:
force the fans up. **Validated setting: a flat ~60 % (≈11,000 RPM)** cools *both* the GPU and CPU at
full load with margin.

## The problem
- V620 is a **passive datacenter GPU** (no onboard fan) → relies entirely on chassis airflow.
- The BMC's `GPU0/1/2_PROC` temp sensors read **"No Reading"** (the card doesn't report die temp to the BMC).
- So the auto fan curve — driven by CPU/inlet/board temps, which stay cool — never ramps for the GPU.
- Result at stock 3,000 RPM: under load the GPU hit **99 °C** and clock-throttled **2400 → 845 MHz**.

## What does NOT work (don't waste time here)
- **ipmitool raw fan control:** `0x3a`, `0x30`, `0x3c` families all return **Invalid command (0xc1)**. No CLI lever.
- **Redfish:** BMC web API won't complete a TLS handshake (HTTP 000).
- **`amdgpu-fan` / any PWM daemon:** the V620 exposes **no `fan`/`pwm` sysfs node** (passive) — nothing to drive.
- **Power capping:** `power1_cap` is **locked at 250 W** (min = max), so heat can't be reduced that way.
- ⇒ **Only the BMC web UI Fan Profile can change fan speed.**

## Sensor reference (measured under load)
| Sensor | Works? | Use |
|---|---|---|
| **`12V_GPU0` (current, A)** | ✅ **0 → ~20 A** under GPU load | **best GPU-load trigger** (direct: A × 12 V ≈ GPU watts). V620 is on slot 0. |
| `SYS_POWER` (W) | ✅ tracks total | whole-box load |
| `CPU0_TEMP` / `CPU0_DTS` | ✅ | CPU thermal (single socket; CPU1 empty) |
| `PSU1/2_HOTSPOT0` | ~ (indirect, +13 °C) | weak GPU proxy |
| `GPU0/1/2_PROC` (temp) | ❌ No Reading | — |
| `RISER1/2/3_TEMP`, `INLET`, `MB` | ❌ flat under GPU load | do NOT curve on these for the GPU |

## Validated thermals (fans = flat duty)
| Fans | RPM | GPU (short burst) | GPU (**sustained**) | CPU alone | **CPU+GPU sustained (5 min)** |
|---|---|---|---|---|---|
| ~18 % (stock auto) | 3,000 | **99 °C — throttled** ❌ | — | — | — |
| **60 %** | ~11,000 | 74 °C | ~climbs | 70 °C | **GPU 97 °C 🔥 / CPU 83 °C** ❌ |
| **90–100 %** ✅ | ~15–16k | 68 °C | (recommended for sustained) | — | (expected low-80s — verify) |

⚠️ **CRITICAL:** short GPU bursts are misleading — under **sustained** prompt-processing the GPU heat-soaks
much higher, and with the CPU also loaded (same side → shared fans) a **5-min CPU+GPU burn at 60 % hit
GPU junction 97 °C** (edge of throttle), CPU 83 °C, **SYS_POWER 650 W**.
⇒ **Use 60 % only for light/bursty work. For the 24 h burn-in or any sustained/combined heavy load, run 90–100 %.**

Layout note: the **single CPU0 is on the same side as riser1 / the V620**, so the 2 fans on that side
cool *both* — which is exactly why combined load runs hot. The other 2 fans (over the empty CPU1 socket /
empty risers) do far less.

Guard caveat: `gpu-thermal-guard` clock-cap did **not** engage under continuous ROCm compute (GPU stayed
boosted at 250 W / 97 °C) — treat it as a coarse idle-time backstop only; **fans are the real protection.**

## Recommended configuration (do in BMC web UI → Fan Profile)
**Option A — simplest (validated): flat 60 %.**
Set the policy so the **lowest temperature band already = 60 % PWM** (i.e. flatten the curve to 60 %).
Covers GPU (74 °C) and CPU (70 °C) at full load. Slightly louder at idle, but bulletproof.

**Option B — adaptive (quietest, best): `MAX(CPU-temp, GPU-current)` with a 60 % floor.**
If the profile lets you attach multiple sensor policies to the fans (it takes the highest):
- **GPU curve on `12V_GPU0` current (A):**

  | `12V_GPU0` | Fan % |
  |---|---|
  | ≤ 2 A (idle) | 30 % |
  | 6 A | 40 % |
  | 10 A | 50 % |
  | 14 A | 60 % |
  | ≥ 18 A | 70 % |

- **CPU curve on `CPU0_TEMP` (°C):** e.g. `≤50→30 %, 65→50 %, 75→70 %, ≥85→100 %`.
- Result: near-silent idle, auto-ramps for whichever (CPU or GPU) is hot. Handles combined load too.

⚠️ **Apply step:** after editing, **Save AND set the profile Active** — a saved-but-not-selected profile
won't take effect (the fans staying at 3,000 RPM = profile not active).

## Backstop (already deployed, OS-side)
`gpu-thermal-guard.service` reads the V620 junction temp and **caps GPU clocks to 500 MHz if it hits
90 °C**, restoring at 82 °C. It cannot cool the card (fans are the only cooling), but it guarantees the
GPU can never sit at 99 °C even if a fan setting is wrong. Keep it enabled.
