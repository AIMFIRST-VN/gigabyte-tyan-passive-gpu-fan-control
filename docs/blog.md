---
title: "Why Is My Gigabyte Server So Damn Loud With Only One Enterprise GPU In It?"
slug: why-is-my-gigabyte-server-so-loud-one-gpu
excerpt: "One enterprise GPU turns a Gigabyte R282 / R182 (MZ92-FS0 board) into a jet engine, or cooks the card in silence. The fix: proper Gigabyte MZ92-FS0 BMC fan control for a passive GPU (Radeon Pro V620, Instinct MI210, NVIDIA Tesla)."
focus_keyword: "gigabyte mz92-fs0 fan control"
tags: [Gigabyte MZ92-FS0, Gigabyte R282, R282-Z93, R282-Z92, R282-Z90, R182-Z92, R182-Z90, gigabyte server loud, BMC fan control, MegaRAC fan profile, passive GPU cooling, Radeon Pro V620, Instinct MI210, NVIDIA Tesla A100, Intel Data Center GPU Flex, server fan noise, AST2500]
---

# Why Is My Gigabyte Server So Damn Loud With Only One Enterprise GPU In It?

You drop one enterprise GPU into a Gigabyte **R282-Z93** and suddenly it's either
a jet engine or it's quietly cooking the card. Either way the fans are wrong.
Here's why — and how to fix **Gigabyte R282 fan control** for good.

## The BMC doesn't understand your GPU

A passive AMD **Radeon Pro V620** has no onboard fan — it needs chassis air, and
so does every passive enterprise GPU: AMD **Radeon Pro V620 / V520**, **Instinct
MI210 / MI250**, NVIDIA **Tesla A100 / A40 / A16 / T4 / L4**, Intel **Data Center
GPU Flex**. The AMI **MegaRAC** BMC only ramps its fans for cards on the vendor's
supported list. Yours probably isn't on it, so the firmware treats the GPU as if
it doesn't exist: it cools the CPUs it can see and lets the card climb past 80 °C.

So you do the only thing the web UI lets you — crank the fans up by hand. Now the
whole 2U howls at a fixed high speed, all fans, all the time, idle or flat out.
That's the "so damn loud" you're hearing: a dumb, static fan speed compensating
for a BMC that can't see your card.

## It's the motherboard, not just your model

This isn't one odd server — it's the **board**. Gigabyte's **MZ92-FS0** (dual AMD
EPYC, AMI MegaRAC BMC on an AST2500) sits under a whole family: the 2U
**R282-Z90 / Z91 / Z92 / Z93 / Z94 / Z96** and the 1U **R182-Z90 / Z91 / Z92 /
Z93**, plus other Gigabyte EPYC servers with the same BMC. Same fan controller,
same supported-GPU list, same silence about your card — and Gigabyte never
open-sourced any of it, which is why the search that sent you here turned up
nothing.

## The fix: make the BMC ramp *with* the GPU

The goal is simple — quiet at idle, only as loud as the GPU actually needs. The
**BMC itself** has to ramp the fans in proportion to load instead of sitting at a
flat 100 %.

The catch: the standard Redfish API reads the fan profile but refuses to write it
(`405` / `400`). The web UI changes profiles fine, though — over a proprietary
`/api/` interface. Log in for a CSRF token and session cookie, and you can POST a
custom fan profile straight to the BMC.

## A profile that stays quiet until the GPU works

The BMC drives each fan at the highest duty any policy demands, so you layer
signals: drive the fans nearest the card on **GPU current** (a direct proxy for
GPU watts, since the BMC can't read the die temperature), plus **CPU temperature**
and **total system power**. Keep the far fans silent for a single GPU — they only
spin up if you add a second or third card — and force everything to full only if a
CPU hits 91 °C.

Now the server is near-silent at idle, ramps smoothly as the GPU draws current,
and never runs louder than it has to — autonomously, on the BMC, surviving
reboots, no host daemon. We tuned these curves for **quiet**; in a data center
you'd point the same knobs at **power** — fans are a real slice of a node's
wattage.

## Takeaway

Your Gigabyte server is loud because the BMC is guessing around a GPU it won't
acknowledge. Stop fighting it with a flat 100 %: under the Redfish veneer is the
real control plane the web UI uses, and once you speak its language you get
proper, quiet, proportional **Gigabyte R282 fan control** for an unsupported GPU.
The tooling is open source.

*Connection details are placeholders; nothing real is published.*
