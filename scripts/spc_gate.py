#!/usr/bin/env python3
"""SPC rolling control bands over Chatman-invariant metrics (lane 430).

Reads config/bands.yaml plus the receipt/jsonl history, computes z-scores
against the rolling mean/stdev of the last `window` observations, and emits a
tiered verdict:

    z < 1 sigma          PASS    (silent, exit 0)
    1 <= z < 2 sigma     EVENT   {:spc_drift, metric, sigma, value} (exit 0)
    2 <= z < 3 sigma     DISPATCH row, typed remediation: bench-runner profile
    z >= 3 sigma         FAIL-CLOSED: nonzero exit + orphaned-key dump

NFR-4 residue class: center 0 by definition -- any nonzero residue_tables
count is tier 3 immediately, a stronger law than stdev allows.

Missing history is never a faked z-score: below `min_points` observations a
metric runs in SEED mode (bands established from the current baseline,
verdict SEEDED, exit 0).

Receipt: docs/jira/v26.10.16/sdk-results/spc-bands.md
Exit codes: 0 pass/seeded/event/dispatch, 1 fail-closed 3-sigma.
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BANDS = ROOT / "config" / "bands.yaml"
HISTORY = ROOT / "tmp" / "spc-history.jsonl"
RECEIPT = ROOT / "docs" / "jira" / "v26.10.16" / "sdk-results" / "spc-bands.md"
# Test seam: SMALT_SPC_SOURCES (colon-separated, relative to ROOT) overrides
# the observation/history sources; SMALT_SPC_HISTORY overrides the rolling
# history file. Used by the injected-breach non-vacuity run (temp history,
# real gate code path).
SOURCES = [Path(p) for p in (
    __import__("os").environ.get("SMALT_SPC_SOURCES") or ""
).split(":") if p] or None
HISTORY = Path(__import__("os").environ.get("SMALT_SPC_HISTORY") or HISTORY)

STAGES = ["parse", "apply", "plan", "synthesize", "destroy", "residue"]
STAGE_KEYS = {
    "parse": "parse_ms",
    "apply": "apply_ms",
    "plan": "plan_ms",
    "synthesize": "synthesize_ms",
    "destroy": "destroy_ms",
    "residue": "residue_ms",
}

WINDOW = 30
MIN_POINTS = 8


def load_bands():
    # SHIM-COURT covered seam: malformed/missing bands.yaml is a CONFIG-ERROR
    # (exit 2), distinct from the 3-sigma fail-closed exit 1.
    import yaml
    try:
        with BANDS.open() as f:
            return yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"[spc] CONFIG-ERROR: bands.yaml malformed: {e}")
        sys.exit(2)
    except OSError as e:
        print(f"[spc] CONFIG-ERROR: bands.yaml unreadable: {e}")
        sys.exit(2)


def read_history_files(paths):
    """Seed observations from canonical receipt history (read-only).

    Supported shapes: JSON code fences in .md receipts (delta_kb,
    residue_tables keys) and bench_emit-shaped .jsonl rows (machine.*_ms,
    residue_tables).
    """
    obs = {"nfr3_delta_rss_kb": [], "nfr4_residue_tables": [], "native_stage_ms": {}}
    for raw in paths or []:
        p = ROOT / raw
        if not p.exists():
            continue
        text = p.read_text()
        if p.suffix == ".md":
            # Extract JSON code blocks; keep objects carrying known metric keys.
            import re
            for block in re.findall(r"```json\s*(\{.*?\})\s*```", text, re.S):
                try:
                    d = json.loads(block)
                except json.JSONDecodeError:
                    continue
                if "delta_kb" in d:
                    obs["nfr3_delta_rss_kb"].append(float(d["delta_kb"]))
                if "residue_tables" in d:
                    obs["nfr4_residue_tables"].append(float(d["residue_tables"]))
        else:
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "residue_tables" in d:
                    obs["nfr4_residue_tables"].append(float(d["residue_tables"]))
                machine = d.get("machine") or {}
                for st in STAGES:
                    v = machine.get(STAGE_KEYS[st])
                    if isinstance(v, (int, float)):
                        obs["native_stage_ms"].setdefault(st, []).append(float(v))
    return obs


def read_rolling_history():
    """Read the appended rolling window (tmp/spc-history.jsonl)."""
    rows = []
    if HISTORY.exists():
        for line in HISTORY.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def append_history(entry):
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    with HISTORY.open("a") as f:
        f.write(json.dumps(entry) + "\n")


def rolling(series):
    n = len(series)
    mean = sum(series) / n
    if n < 2:
        sigma = max(1.0, abs(mean) * 0.1)
    else:
        var = sum((x - mean) ** 2 for x in series) / (n - 1)
        sigma = math.sqrt(var)
        if sigma == 0:
            sigma = max(1.0, abs(mean) * 0.1)
    return mean, sigma


def z_of(value, mean, sigma):
    if sigma <= 0:
        return float("inf") if value != mean else 0.0
    return abs(value - mean) / sigma


def classify(metric, value, series):
    """Return (tier, z, mean, sigma, remediation). tier in 0..3, or None=seed."""
    if metric == "nfr4_residue_tables":
        # Zero-center law: any residue is a 3-sigma breach by definition.
        # This is an invariant, not a stdev band — it needs no history and
        # fires even in seed mode (seed mode covers only stdev metrics).
        if value != 0:
            return 3, float("inf"), 0.0, 1.0, \
                "orphaned-key dump required (NFR-4 residue class: " \
                f"{value:g} residue tables, center 0)"
        if len(series) < MIN_POINTS:
            return None, None, 0.0, None, None
        mean, sigma = 0.0, 1.0
        z = 0.0 if value == 0 else float("inf")
        tier = 0 if value == 0 else 3
        rem = "bench-runner profile" if tier < 3 else \
            "orphaned-key dump required (NFR-4 residue class)"
        return tier, z, mean, sigma, rem
    if len(series) < MIN_POINTS:
        return None, None, None, None, None
    window = series[-WINDOW:]
    mean, sigma = rolling(window)
    z = z_of(value, mean, sigma)
    if z >= 3:
        tier = 3
    elif z >= 2:
        tier = 2
    elif z >= 1:
        tier = 1
    else:
        tier = 0
    rem = None
    if tier == 2:
        rem = "dispatch: bench-runner profile (2-sigma drift)"
    elif tier == 3:
        rem = "fail-closed: orphaned-key dump + bench-runner profile (3-sigma)"
    return tier, z, mean, sigma, rem


def current_observation(sources=None):
    """Observation for THIS run, parsed from the live canonical receipts."""
    obs = read_history_files(sources or [
        "docs/jira/v26.10.16/sdk-results/nfr3-rss.md",
        "tmp/enclave-native.jsonl",
    ])
    now = {}
    now["nfr3_delta_rss_kb"] = obs["nfr3_delta_rss_kb"][-1] if obs["nfr3_delta_rss_kb"] else None
    now["nfr4_residue_tables"] = obs["nfr4_residue_tables"][-1] if obs["nfr4_residue_tables"] else 0
    stages_now = {st: (obs["native_stage_ms"].get(st) or [None])[-1] for st in STAGES}
    now["native_stage_ms"] = {k: v for k, v in stages_now.items() if v is not None}
    return now


def main():
    bands = load_bands()
    seeded_from = read_history_files([m.get("history") for m in
                                      bands["metrics"].values() if m.get("history")][0]
                                     if False else
                                     bands["metrics"]["nfr3_delta_rss_kb"]["history"] +
                                     bands["metrics"]["nfr4_residue_tables"]["history"] +
                                     bands["metrics"]["native_stage_ms"]["history"])
    rolling_rows = read_rolling_history()
    # Prior series: seeded receipts + rolling history rows, per metric.
    prior = {
        "nfr3_delta_rss_kb": list(seeded_from["nfr3_delta_rss_kb"]),
        "nfr4_residue_tables": list(seeded_from["nfr4_residue_tables"]),
        "native_stage_ms": {st: list(seeded_from["native_stage_ms"].get(st, []))
                            for st in STAGES},
    }
    for row in rolling_rows:
        if row.get("nfr3_delta_rss_kb") is not None:
            prior["nfr3_delta_rss_kb"].append(float(row["nfr3_delta_rss_kb"]))
        if row.get("nfr4_residue_tables") is not None:
            prior["nfr4_residue_tables"].append(float(row["nfr4_residue_tables"]))
        for st, v in (row.get("native_stage_ms") or {}).items():
            if st in STAGES and isinstance(v, (int, float)):
                prior["native_stage_ms"].setdefault(st, []).append(float(v))

    now = current_observation(SOURCES)

    metrics_out = []
    worst = 0
    events = []
    for metric, value in sorted(now.items()):
        if value is None:
            continue  # metric not present in this run's receipts: not graded
        if metric == "native_stage_ms":
            for st, sv in sorted(value.items()):
                series = prior["native_stage_ms"].get(st, [])
                name = f"native_stage_ms.{st}"
                tier, z, mean, sigma, rem = classify(name, sv, series)
                if tier is None:
                    metrics_out.append({
                        "metric": name, "value": sv, "n": len(series),
                        "verdict": "SEEDED",
                        "center": round(sum(series) / len(series), 1) if series else sv,
                        "note": "seed mode: bands established from baseline",
                    })
                    continue
                entry = {"metric": name, "value": sv, "n": len(series),
                         "center": round(mean if mean is not None else 0.0, 2),
                         "sigma": round(sigma if sigma is not None else 0.0, 2),
                         "z": round(z, 2) if z != float("inf") else "inf",
                         "tier": tier}
                if tier >= 1:
                    entry["event"] = {"spc_drift": [name, tier, sv]}
                if rem:
                    entry["remediation"] = rem
                metrics_out.append(entry)
                worst = max(worst, tier)
                if tier == 1:
                    events.append({"spc_drift": [name, tier, sv]})
        else:
            series = prior[metric]
            tier, z, mean, sigma, rem = classify(metric, value, series)
            if tier is None:
                metrics_out.append({
                    "metric": metric, "value": value, "n": len(series),
                    "verdict": "SEEDED",
                    "center": round(sum(series) / len(series), 1) if series else value,
                    "note": "seed mode: bands established from baseline",
                })
                worst = max(worst, 0)
                continue
            entry = {"metric": metric, "value": value, "n": len(series),
                     "center": round(mean if mean is not None else 0.0, 2),
                     "sigma": round(sigma if sigma is not None else 0.0, 2),
                     "z": round(z, 2) if z != float("inf") else "inf",
                     "tier": tier}
            if tier >= 1:
                entry["event"] = {"spc_drift": [metric, tier, value]}
            if rem:
                entry["remediation"] = rem
            metrics_out.append(entry)
            worst = max(worst, tier)
            if tier == 1:
                events.append({"spc_drift": [metric, tier, value]})

    # Append THIS observation to the rolling history (after classification,
    # so the observation is not graded against itself).
    entry = {"at": receipt_ts(), **{k: v for k, v in now.items()}}
    append_history(entry)

    verdict = {0: "PASS", 1: "EVENT", 2: "DISPATCH", 3: "FAIL"}[worst]
    receipt = {
        "gate": "spc-bands",
        "verdict": verdict,
        "tier": worst,
        "window": WINDOW,
        "min_points": MIN_POINTS,
        "seeded": any(m.get("verdict") == "SEEDED" for m in metrics_out),
        "events": events,
        "metrics": metrics_out,
    }

    orphaned = []
    if worst == 3:
        for m in metrics_out:
            if m.get("tier") == 3:
                orphaned.append({"metric": m["metric"], "value": m["value"],
                                 "z": m.get("z")})
        receipt["orphaned_keys"] = orphaned

    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    md = ("# SPC rolling control bands receipt (scripts/spc_gate.py)\n\n"
          "```json\n" + json.dumps(receipt, indent=2) + "\n```\n")
    RECEIPT.write_text(md)

    print(json.dumps(receipt, indent=2))
    if worst == 3:
        print("[spc] FAIL-CLOSED 3-sigma: " +
              ", ".join(f"{o['metric']}={o['value']} (z={o.get('z')})" for o in orphaned))
        return 1
    if receipt["seeded"]:
        print("[spc] SEEDED: bands established from baseline history")
    return 0


def receipt_ts():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


if __name__ == "__main__":
    sys.exit(main())
