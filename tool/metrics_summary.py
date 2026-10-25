"""Summarizes a metrics session folder written by tool/metrics_session.ps1.

  python tool/metrics_summary.py metrics/20261024-160000

Reads system.csv, turns.jsonl and batterystats.txt; writes summary.md next to them.
Standard library only.
"""

import csv
import json
import os
import re
import statistics
import sys


def pct(values, p):
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    k = (len(v) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def fmt(x, unit="ms"):
    return "–" if x is None else f"{x:,.0f} {unit}"


def main(folder):
    turns = []
    tp = os.path.join(folder, "turns.jsonl")
    if os.path.exists(tp):
        for line in open(tp, encoding="utf-8"):
            line = line.strip()
            if line:
                turns.append(json.loads(line))

    rows = []
    sp = os.path.join(folder, "system.csv")
    if os.path.exists(sp):
        rows = list(csv.DictReader(open(sp, encoding="utf-8-sig")))

    def num(r, k):
        try:
            return float(r[k])
        except (KeyError, TypeError, ValueError):
            return None

    out = [f"# Metrics summary: {os.path.basename(os.path.normpath(folder))}", ""]

    # ---- latency per turn ----
    out += ["## Per-turn latency", "", "| Metric | n | p50 | p90 | max |", "|---|---|---|---|---|"]
    metrics = [
        ("Speech-to-text (Zipformer)", "stt_ms"),
        ("Router (Laya, 5 questions)", "laya_ms"),
        ("Gemma load (cold)", "llm_load_ms"),
        ("Gemma time to first token", "ttft_ms"),
        ("Gemma decode", "decode_ms"),
        ("Time to first audio (TTS)", "tts_first_audio_ms"),
        ("Total turn", "total_ms"),
    ]
    for name, k in metrics:
        vals = [t.get(k) for t in turns if t.get(k) is not None]
        out.append(f"| {name} | {len(vals)} | {fmt(pct(vals, 50))} | {fmt(pct(vals, 90))} | {fmt(max(vals) if vals else None)} |")

    # decode speed
    speeds = [t["chars"] / (t["decode_ms"] / 1000) for t in turns if t.get("chars") and t.get("decode_ms")]
    if speeds:
        out += ["", f"Gemma decode speed: ~{statistics.median(speeds):.0f} chars/s (≈ {statistics.median(speeds) / 4:.0f} tokens/s)."]

    # ---- routing ----
    routes = {}
    for t in turns:
        routes[t.get("route", "?")] = routes.get(t.get("route", "?"), 0) + 1
    if turns:
        quick = sum(v for k, v in routes.items() if k in ("template", "guide"))
        out += ["", "## Routing", "", f"{len(turns)} turns: " + ", ".join(f"{k} {v}" for k, v in sorted(routes.items())),
                f"Quick path (no LLM): {quick / len(turns):.0%}"]
        by_route = {}
        for t in turns:
            by_route.setdefault(t.get("route"), []).append(t.get("total_ms"))
        out += ["", "| Route | median total |", "|---|---|"]
        for k, v in sorted(by_route.items(), key=lambda kv: str(kv[0])):
            out.append(f"| {k} | {fmt(pct(v, 50))} |")

    # ---- battery & resources ----
    out += ["", "## Battery and resources", ""]
    if rows:
        dur_s = num(rows[-1], "elapsed_s") or 0
        b0, b1 = num(rows[0], "battery_pct"), num(rows[-1], "battery_pct")
        cur = [abs(num(r, "current_ma")) for r in rows if num(r, "current_ma") is not None]
        pss = [num(r, "app_pss_mb") for r in rows if num(r, "app_pss_mb") is not None]
        cpu = [num(r, "app_cpu_pct") for r in rows if num(r, "app_cpu_pct") is not None]
        temps = [num(r, "temp_c") for r in rows if num(r, "temp_c") is not None]
        plugged = {r.get("plugged") for r in rows} - {"no", None}
        out.append(f"- Session: {dur_s / 60:.1f} min, {len(rows)} samples")
        if b0 is not None and b1 is not None:
            out.append(f"- Battery: {b0:.0f}% → {b1:.0f}% ({b0 - b1:.0f} points)")
        if cur:
            avg = statistics.mean(cur)
            out.append(f"- Average current: {avg:.0f} mA (≈ {avg * 10 / 60:.0f} mAh per 10 min)")
        if pss:
            out.append(f"- App memory (PSS): median {statistics.median(pss):.0f} MB, peak {max(pss):.0f} MB")
        if cpu:
            out.append(f"- App CPU: median {statistics.median(cpu):.0f}%, peak {max(cpu):.0f}% (100% = one core)")
        if temps:
            out.append(f"- Battery temperature: {min(temps):.1f} → {max(temps):.1f} °C")
        if plugged:
            out.append(f"- ⚠ Phone was powered via {', '.join(sorted(plugged))}: drain numbers are not meaningful.")
    bs = os.path.join(folder, "batterystats.txt")
    if os.path.exists(bs):
        text = open(bs, encoding="utf-8", errors="ignore").read()
        m = re.search(r"Uid u0a\d+:\s+([\d.]+)", text)
        if m:
            out.append(f"- Android's estimate for the app: {m.group(1)} mAh this session")

    open(os.path.join(folder, "summary.md"), "w", encoding="utf-8").write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
