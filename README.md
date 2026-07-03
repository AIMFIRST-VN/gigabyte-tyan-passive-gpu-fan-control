# Gigabyte R282 BMC Fan Control for a Passive GPU

**Open-source fan control for Gigabyte MZ92-FS0 servers (R282 / R182) whose BMC
won't cool a passive datacenter GPU.**

Drop one passive enterprise GPU — an AMD **Radeon Pro V620**, **Instinct MI210**,
an NVIDIA **Tesla A100 / A40 / T4**, an Intel **Data Center GPU Flex** — into a
Gigabyte **R282-Z93** (or any **MZ92-FS0** board) and the chassis fans either sit
idle while the card cooks, or you crank them to a deafening flat 100 %. The AMI
**MegaRAC** BMC only ramps its fans for GPUs on the vendor's supported list, and
your card isn't on it.

This repo shows how to make the **BMC itself** cool the GPU properly — near-silent
at idle, ramping in proportion to GPU load — by reverse-engineering the BMC's own
fan-control API.

📖 **Full write-up:** [Why is my Gigabyte server so damn loud with only one
enterprise GPU in it?](https://aimfirstvn.com/blog/why-is-my-gigabyte-server-so-loud-one-gpu/)

## Which hardware

The **MZ92-FS0** board (dual AMD EPYC, AMI MegaRAC BMC on an AST2500) sits under a
whole family — all with the same BMC and the same fan-control gap:

- **2U:** Gigabyte R282-Z90 / Z91 / Z92 / Z93 / Z94 / Z96
- **1U:** Gigabyte R182-Z90 / Z91 / Z92 / Z93
- plus other Gigabyte EPYC servers with the same MegaRAC BMC.

## How it works

The standard Redfish API *reads* the fan profile but refuses to *write* it (`405`
/ `400`). The BMC web UI changes profiles over a proprietary `/api/` interface:
log in for a CSRF token + session cookie, then `POST` the fan profile back.

The profile layers policies — the BMC drives each fan at the **max** any policy
demands:

- **GPU current** (`12V_GPU0` amps — a leading proxy for GPU watts, since the BMC
  can't read the die temperature)
- **CPU temperature** and **total system power**
- a staged second fan pair that stays silent for one GPU and ramps only when total
  power reveals a second / third card
- a hard **91 °C** all-fan safety, and a near-silent idle.

## What's here

- **`docs/fan-profile.md`** — the reverse-engineered sensor reference, working fan
  curves, and validated thermals.
- **`docs/blog.md`** — the write-up.
- **`results/`** — real BMC fan-profile JSON snapshots (including the final
  layered profile). Keep them to restore the stock profile.
- **`scripts/`** — GPU burn-in, thermal-guard, telemetry, and ramp-test tooling
  used to validate the curves.

## Safety

Keep independent hardware backstops regardless of the profile: a GPU clock-cap
guard and the card's own ~99 °C throttle. Test on an idle GPU first; the snapshots
in `results/` let you restore the stock profile.

---

*All connection details in the docs and scripts are placeholders — set your own
BMC host and credentials via the environment at runtime. Nothing real is
committed.*
