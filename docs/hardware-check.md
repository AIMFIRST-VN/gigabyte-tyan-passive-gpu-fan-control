# Used-Server Hardware Acceptance Check — Gigabyte R282-Z93 (`gpu-server`)

Short burn-in / acceptance plan for a **second-hand** server before trusting it in production.
Run top-to-bottom; anything not "clean" gets investigated before sign-off.

## 0. BMC first — look for a history of prior faults
- iKVM/web: `https://192.168.1.11` (`admin`). Review the **System Event Log** for past thermal/power/ECC events:
  `ipmitool sel elist | tail -40` — anything beyond normal presence/boot/clock lines is suspect.
- Sensors: `ipmitool sdr type Temperature`, `... Fan`, `... Voltage`, `... "Power Supply"` (both PSUs present + healthy → redundancy).
- Clear the SEL after review so new faults stand out during burn-in: `ipmitool sel clear`.

## 1. CPU + memory
- Inventory: `lscpu`; `dmidecode -t memory | grep -E "Size|Speed|Locator"` — all DIMMs seen at rated speed.
- ECC (must be 0): `dmesg | grep -i edac`; watch for corrected/uncorrected counts.
- Stability + thermal stress (~1–2 h): `stress-ng --cpu $(nproc) --matrix 0 --timeout 3600s --metrics`
- Deeper RAM test (best for used gear): boot **memtest86+** for ≥1 full pass.

## 2. Storage
- SMART health per disk: `for d in /dev/nvme? /dev/sd?; do smartctl -H -A "$d"; done`
  - NVMe: check `Percentage Used`, `Media and Data Integrity Errors`, `Available Spare` (≥ threshold).
- Optional perf/soak on **spare** space only: `fio --name=rw --rw=randrw --size=10G --runtime=600 --filename=/data/fio.test && rm /data/fio.test`

## 3. NICs
- Error counters (should be 0): `for i in nic0 nic1 nic2 nic3; do echo "$i"; ethtool -S "$i" | grep -iE "err|drop|crc"; done`
- Link/speed: `for i in nic0 nic1 nic2 nic3; do echo "$i"; ethtool "$i" | grep -E "Speed|Link detected"; done`
- 10 GbE X540 built-in self-test: `ethtool -t nic2 offline` (Register/EEPROM/Interrupt/**Loopback** = pass; the "Link" subtest only fails when no cable is attached — expected).
- Throughput: `iperf3` against another host.

## 4. GPU (AMD Radeon Pro V620)
- Enumerates + no faults: `lspci -nnk -s 03:00.0`; `dmesg | grep -i amdgpu | grep -iE "error|FWSM|removed"` → none.
- Compute path OK (in container): `rocminfo` shows `gfx1030`.
- **24 h full-throttle burn-in** → see `gpu-24h-stress-test-plan.md`: clocks/temps/power must hold, no throttle or `amdgpu` reset.

## 5. Thermals / fans / power under load
- During the CPU + GPU stress, watch fans ramp and temps stay in spec:
  `watch -n5 'ipmitool sdr type Temperature; ipmitool sdr type Fan'`
- After burn-in, re-check the SEL: **no** new thermal/power events should have accumulated.

## Pass criteria
| Area | Pass |
|---|---|
| BMC SEL | no new critical / thermal / power / ECC events during burn-in |
| Memory | memtest clean pass; 0 ECC errors |
| Disks | SMART PASSED; no reallocated/media errors; NVMe spare healthy |
| NICs | all error counters 0; links negotiate expected speed; X540 self-test pass |
| GPU | 24 h burn-in stable (clocks/temps/power); no amdgpu resets |
| Thermals/PSU | fans + temps in spec at full load; both PSUs healthy/redundant |
