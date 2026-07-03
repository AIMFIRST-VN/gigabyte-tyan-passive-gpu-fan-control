#!/usr/bin/env python3
"""Adaptive thermally-aware bench loop with 1Hz sampler.

Background thread samples junction temp at 1Hz into a deque.
Main thread runs llama-bench then waits for cooldown based on
running average + slope over the sample window.
"""
import subprocess, time, re, sys, os, threading
from collections import deque

DURATION_S       = 900
STABILITY_TEMP   = 75   # boost if recent avg ≤ this AND slope ≤ 0 (loose — bursts are tiny)
COOLDOWN_TRIGGER = 85   # cool down only if avg ≥ this (HOT zone)
TARGET_LOW       = 80   # cooldown exits when avg ≤ this
HARD_CEIL        = 90   # never start an iter above this
WINDOW           = 5
SAMPLE_HZ        = 1.0
BASELINE_N       = 256  # baseline iter size (~22s at 500 MHz)
BOOST_N_MIN      = 32   # min boost burst tokens
BOOST_N_MAX      = 256  # full burst — 1:1 alternation with mid for ~15 t/s avg
PERF_PATH        = "/sys/class/drm/card0/device/power_dpm_force_performance_level"
SCLK_PATH        = "/sys/class/drm/card0/device/pp_dpm_sclk"
MCLK_PATH        = "/sys/class/drm/card0/device/pp_dpm_mclk"

samples = deque(maxlen=WINDOW)
lock = threading.Lock()
stop_flag = threading.Event()

def _find_idx_for_mhz(path, want_mhz):
    """Parse pp_dpm_sclk/mclk listing, return the index whose freq matches want_mhz.
    Handles both 'N: NNNNMhz' and 'S: 0Mhz' formats."""
    with open(path) as f:
        for line in f:
            line = line.strip().replace("*", "")
            # forms: "0: 500Mhz", "S: 0Mhz", "1: 2570Mhz"
            m = re.match(r"(\S+):\s*(\d+)\s*Mhz", line)
            if m:
                idx, mhz = m.group(1), int(m.group(2))
                if mhz == want_mhz:
                    return idx
    return None

def set_mode(mode):
    """mode = 'mid' (sclk=500 baseline), 'boost' (sclk=2570 short burst),
              'idle' (auto, true downclock for cooldown)."""
    try:
        if mode == "idle":
            with open(PERF_PATH, "w") as f: f.write("auto")
            return
        with open(PERF_PATH, "w") as f: f.write("manual")
        want_sclk = 500 if mode == "mid" else 2570
        sclk_idx = _find_idx_for_mhz(SCLK_PATH, want_sclk)
        mclk_idx = _find_idx_for_mhz(MCLK_PATH, 1000)
        if sclk_idx is None or mclk_idx is None:
            print(f"   ! set_mode({mode}): could not find DPM indices "
                  f"(sclk={sclk_idx} mclk={mclk_idx})", flush=True)
            return
        with open(SCLK_PATH, "w") as f: f.write(sclk_idx)
        with open(MCLK_PATH, "w") as f: f.write(mclk_idx)
    except Exception as e:
        print(f"   ! set_mode({mode}) failed: {e}", flush=True)

def junction_c():
    try:
        out = subprocess.check_output(["sensors"], text=True, timeout=3)
        m = re.search(r"^junction:\s+\+?(\d+\.?\d*).*C", out, re.M)
        return float(m.group(1)) if m else None
    except Exception:
        return None

def edge_c():
    """Edge temp = heatsink-side reading; lags junction but reflects soak."""
    try:
        out = subprocess.check_output(["sensors"], text=True, timeout=3)
        m = re.search(r"^edge:\s+\+?(\d+\.?\d*).*C", out, re.M)
        return float(m.group(1)) if m else None
    except Exception:
        return None

def sampler():
    while not stop_flag.is_set():
        j = junction_c()
        if j is not None:
            with lock:
                samples.append(j)
        time.sleep(1.0 / SAMPLE_HZ)

def stats():
    with lock:
        snap = list(samples)
    if not snap:
        return None, None, None
    avg = sum(snap) / len(snap)
    slope = (snap[-1] - snap[0]) / max(1, len(snap) - 1) if len(snap) >= 2 else 0.0
    return snap[-1], avg, slope

def cooldown():
    waited = 0
    while waited < 120:
        last, avg, slope = stats()
        if avg is not None and avg <= TARGET_LOW and slope <= 0:
            return waited, last, avg, slope
        time.sleep(1)
        waited += 1
    return waited, last, avg, slope

def main():
    t = threading.Thread(target=sampler, daemon=True)
    t.start()
    end = time.time() + DURATION_S
    n = 0
    BOOST_S = 45   # boost window length
    MID_S   = 30   # mid window length
    try:
        env = os.environ.copy()
        env["GGML_VK_VISIBLE_DEVICES"] = "1"
        next_mode = "boost"
        while time.time() < end:
            mode = next_mode
            # gate: never start a boost window when card is already hot
            if mode == "boost":
                last_chk, avg_chk, _ = stats()
                edge_now = edge_c() or 0
                # Two gates: junction hot OR heatsink saturated.
                #   junction (instantaneous chip hotspot) → >= 80
                #   edge (heatsink temp, slower-moving) → >= 70 means saturated
                hottest = max(last_chk or 0, avg_chk or 0)
                if hottest >= 80 or edge_now >= 70:
                    print(f"=== gate {time.strftime('%H:%M:%S')} junction={hottest}C edge={edge_now}C — force mid ===", flush=True)
                    mode = "mid"
            next_mode = "mid" if mode == "boost" else "boost"
            set_mode(mode)
            this_window = BOOST_S if mode == "boost" else MID_S
            window_end = time.time() + this_window
            print(f"=== window {time.strftime('%H:%M:%S')} mode={mode} for {this_window}s ===", flush=True)
            safety_tripped = False
            while time.time() < window_end and time.time() < end:
                # SAFETY: emergency override if junction >= 95C → bail to mid
                last_chk, _, _ = stats()
                if mode == "boost" and last_chk is not None and last_chk >= 95:
                    print(f"   ! SAFETY ABORT: junction {last_chk}C >= 95 — drop to mid + extend mid window", flush=True)
                    set_mode("mid")
                    mode = "mid"
                    safety_tripped = True
                    # restart this window as mid; force next window to be mid too
                    window_end = time.time() + MID_S
                    next_mode = "mid"
                n += 1
                tok_n = 256
                t0 = time.time()
                r = subprocess.run(
                    ["/opt/llama.cpp/build/bin/llama-bench",
                     "-m", "/opt/models/gemma-4-31b-qat.gguf",
                     "-ngl", "99", "-p", str(tok_n), "-n", str(tok_n), "-r", "1"],
                    env=env, capture_output=True, text=True, timeout=300)
                dur = time.time() - t0
                last, avg, slope = stats()
                tg_line = ""
                for line in r.stdout.splitlines():
                    if "tg" in line and "Q4" in line:
                        tg_line = line.strip()
                print(f"   iter {n} mode={mode} dur={dur:.1f}s j={last}C avg={avg:.1f}C  {tg_line}", flush=True)
    finally:
        stop_flag.set()
        set_mode("idle")
    print(f"=== ENDED {time.strftime('%H:%M:%S')} after {n} iters ===", flush=True)

if __name__ == "__main__":
    main()
