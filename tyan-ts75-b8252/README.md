# Tyan TS75-B8252 — passive-GPU chassis fan control (in-band IPMI)

Host-side, **fully in-band** thermal control (no BMC network needed) for a **passive AMD Radeon
Pro V620** — or any AMD GPU — in a **Tyan TS75-B8252 / motherboard S8252**. The BMC can't read an
add-in GPU's temperature, so its stock fan curve never ramps for it and the passive card overheats
(~100 °C junction at the ~9–10 k RPM auto floor). This drives the 6 chassis fans directly via
Tyan's OEM IPMI fan commands, keyed to the **hottest of every device** in the box.

## The discovery (why in-band)
The Tyan BMC (AMI MegaRAC / AST2500) exposes **no** user fan control via the web UI (174 `/api/`
endpoints, none for fans) or Redfish (auth-gated, stock AMI, no fan-profile OEM). Fan control lives
**only** in Tyan's **OEM IPMI command set**, reachable **in-band via `/dev/ipmi0`**:

```
netfn 0x2e, Tyan IANA = 0xfd 0x19 0x00  (6653)
set duty:   ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 <PWM> <0x00..0x64>   # 0..100 %
read duty:  ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 <PWM> 0xfe
restore:    ipmitool raw 0x2e 0x05 0xfd 0x19 0x00 <PWM> 0xff           # -> BMC auto
disable smart algo (all): ipmitool raw 0x2e 0x06 0xfd 0x19 0x00 0x00
```

**PWM → fan map (S8252):** `PWM 2,3,4,5,6,0 = SYS_FAN_1..6`; `PWM 1,7` = the empty CPU0/CPU1_FAN
headers (return "Invalid data field").

## What it covers
`gpu-fan-control.sh` auto-detects and drives the fans on the **max** of every device's curve:

| Device | Sensor | Source |
|---|---|---|
| All AMD GPUs | edge (curve) + junction + VRAM (valve) | sysfs `amdgpu` hwmon |
| All CPU sockets | Tctl | `k10temp` |
| All NVMe SSDs | composite | `nvme` hwmon |
| System memory | UMC / DIMM VRM | BMC SDR (ipmitool) |

Plus a **profile-independent cascading safety valve** that forces fans toward 100 % as *any* device
nears its limit (CPU→100 % by 91 °C — mirrors the Gigabyte R282 fankit "critical CPU" tier).

## Profiles  — `/etc/gpu-fan-control.conf` → `PROFILE=`
`max-performance` · `performance` · `balanced` · `max-quiet` (default; quiet, leans on the GPU
thermal guard under heavy load). Switch: edit the file, `systemctl restart gpu-fan-control`.

## Components
- **`gpu-fan-control.sh`** — the fan daemon
- **`gpu-thermal-guard.sh`** — GPU junction backstop: duty-cycles (SIGSTOP/CONT the `/dev/kfd`
  process) or clock-caps the GPU if junction ≥ HOT (default 100 °C), pure GPU-side
- **`tyan-thermal-soak.sh`** — fault/ECC-aware soak: `[gpu|cpu|nvme|both|all] [minutes] [profile]`;
  logs GPU/CPU/fan/ECC/faults to CSV, aborts on GPU 100 °C / CPU 95 °C, scans RAS/ECC/MCE/AER
- **`systemd/`** — the units + fail-safe restore service

## Safety / robustness
- **Fails safe to BMC auto** — `ExecStopPost` + `OnFailure=gpu-fan-restore.service` set all fans to `0xff`
- **Watchdog** (`Type=notify` + `WatchdogSec=25`) restarts on hang; `Restart=always` on crash; every
  `ipmitool` call is `timeout`-wrapped so it can't hang
- **High priority** — `Nice=-10`, `OOMScoreAdjust=-900`
- **Hardware throttle / THERMTRIP shutdown is the ultimate backstop** under all of the above

## Install
```sh
cp gpu-fan-control.sh gpu-thermal-guard.sh tyan-thermal-soak.sh /root/
cp gpu-fan-control.conf /etc/
cp systemd/*.service /etc/systemd/system/
printf 'ipmi_devintf\nipmi_si\n' > /etc/modules-load.d/ipmi.conf
systemctl daemon-reload
systemctl enable --now gpu-fan-control gpu-thermal-guard
```

## Validated (all ECC/fault-clean, 0 RAS/MCE/AER)
| Test | Result |
|---|---|
| max-performance GPU soak, 10 min | junction ≤ 90 °C flat, full 2385 MHz, pp4096 ~1350 t/s |
| CPU+GPU combined, 10 min | GPU ≤ 92 °C, CPU Tctl 63 °C |
| CPU-only (max-quiet) | CPU curve ramps fans, CPU 75 °C |
| NVMe high random-IO | 58 °C, nvme curve ramps fans |
| SIGKILL the daemon | auto-restart in ~2 s |

## Relation to the Gigabyte R282 fankit
Same *strategies* (max-of-policies, cascading safety valve, zoned fans) — different **backend**:
the R282 uses the Gigabyte Redfish fan-profile API; the Tyan uses this **in-band OEM IPMI**. See the
repository root for the R282/Gigabyte implementation.
