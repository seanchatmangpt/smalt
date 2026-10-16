#!/usr/bin/env python3
"""DoD-14 SDK coverage matrix compiler (mechanical representation).

Surface inventory derives mechanically from the implementation:
  (a) lib/smalt/data_plane/*.ex module names,
  (b) route families in lib/smalt/egress_router.ex,
  (c) ARM surface: Smalt.Registry admitted types + arm_gateway routes.

Each surface row records: TS probe cell, Python probe cell, per-language
receipt verdicts (PASS/FAIL/DIVERGENCE counts), and for every non-pass cell
the registered divergence ids (KNOWN_DIVERGENCES.md KD-*) or
UNREGISTERED-GAP.

Exit 0 = every cell pass-or-registered. Exit 1 = findings (MISSING cells or
UNREGISTERED-GAP) exist. Findings are surfaced, not hidden.

Also CRCs the Service Bus census: counts probe() registrations in
test/sdk-smoke/census.test.cjs against the claim in
receipts/08-servicebus-census.md.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESULTS = ROOT / "docs/jira/v26.10.14/sdk-results"
KD_PATH = ROOT / "docs/jira/v26.10.14/KNOWN_DIVERGENCES.md"
MATRIX_MD = ROOT / "docs/jira/v26.10.14/SDK_MATRIX.md"
CENSUS = ROOT / "test/sdk-smoke/census.test.cjs"
CENSUS_RCPT = ROOT / "docs/jira/v26.10.14/receipts/08-servicebus-census.md"
# Supplementary probe files (lane-written, outside census.test.cjs). Their
# registrations are counted into registered_total so an unregistered
# supplementary file cannot silently escape the census CRC.
EXTRA_PROBES = [
    ("test/sdk-smoke/sb-extra.probe.cjs", r'record\("([\w-]+)"'),
]

# ---------------------------------------------------------------------------
# Surface inventory. Each surface is grounded in >=1 mechanical source:
# ground: {lib-relative file: [keywords]} verified against the live file;
# ts / py: probe-filename substrings under test/sdk-full, test/sdk-python;
# receipts: receipt filenames under docs/jira/v26.10.14/sdk-results.
# ---------------------------------------------------------------------------
SURFACES = [
    dict(id="arm", ground={"arm_gateway/router.ex": ["resourceGroups"],
                           "registry.ex": ["Microsoft.Resources/resourceGroups"]},
         ts=["arm-resources"], py=["arm_resources"],
         receipts=["ts-arm-resources.md", "py-arm-resources.md"]),
    dict(id="blob", ground={"data_plane/blob_service.ex": ["defmodule Smalt.DataPlane.BlobService"],
                            "data_plane/blob_storage.ex": ["defmodule Smalt.DataPlane.BlobStorage"]},
         ts=["blob"], py=["storage_blob"],
         receipts=["ts-storage-blob.md", "py-storage-blob.md"]),
]
SURFACES += [
    dict(id="cosmos", ground={"data_plane/cosmos.ex": ["defmodule Smalt.DataPlane.Cosmos"]},
         ts=["cosmos"], py=["cosmos"], receipts=["py-cosmos.md", "ts-cosmos.md"]),
         # cosmos/ts divergences registered as KD-36/KD-36b in KNOWN_DIVERGENCES.md
    dict(id="keyvault", ground={"data_plane/key_vault_actions.ex": ["defmodule"],
                                "data_plane/skr.ex": ["defmodule Smalt.DataPlane.SKR"]},
         ts=["keyvault", "auth"], py=["auth_keyvault"],
         receipts=["ts-keyvault.md", "py-auth-keyvault.md"]),
    dict(id="skr", ground={"data_plane/skr.ex": ["defmodule Smalt.DataPlane.SKR"]},
         ts=["keyvault"], py=["auth_keyvault"],
         receipts=["ts-keyvault.md", "py-auth-keyvault.md"]),
    dict(id="eventgrid", ground={"egress_router.ex": ["/topics/:topic/events"],
                                 "registry.ex": ["Microsoft.EventGrid/topics"]},
         ts=[], py=["eventhub_grid"], receipts=["py-eventhub-eventgrid.md"],
         missing_kd={"ts": ["KD-39"]}),
    dict(id="eventhubs", ground={"registry.ex": ["Microsoft.EventHub/namespaces/eventhubs"]},
         ts=["eventhubs"], py=["eventhub_grid"],
         receipts=["ts-event-hubs.md", "py-eventhub-eventgrid.md"]),
    dict(id="sentinel", ground={"data_plane/sentinel.ex": ["defmodule Smalt.DataPlane.Sentinel"],
                                "data_plane/kql.ex": ["defmodule"]},
         py=["resourcegraph_monitor"], receipts=["py-resourcegraph-monitor.md"],
         missing_kd={"ts": ["KD-37"]}),
    dict(id="resource-graph", ground={"data_plane/resource_graph.ex": ["defmodule Smalt.DataPlane.ResourceGraph"]},
         py=["resourcegraph_monitor"], receipts=["py-resourcegraph-monitor.md"],
         missing_kd={"ts": ["KD-38"]}),
    dict(id="purview-atlas", ground={"data_plane/purview_atlas.ex": ["defmodule"]},
         ts=[], py=[], receipts=[],
         missing_kd={"ts": ["KD-40"], "py": ["KD-41"]}),
    dict(id="ledger", ground={"egress_router.ex": ["/app/transactions"],
                              "registry.ex": ["Microsoft.ConfidentialLedger/ledgers"]},
         ts=[], py=[], receipts=[],
         missing_kd={"ts": ["KD-42"], "py": ["KD-43"]}),
]

# surfaces whose census/AMQP cell is represented by the Service Bus census
CENSUS_SURFACE = "servicebus"

def read(p):
    return p.read_text(errors="replace") if p.exists() else ""

def grounding_ok(s):
    for rel, kws in s["ground"].items():
        text = read(ROOT / "lib/smalt" / rel)
        if not any(k in text for k in kws):
            return False
    return True

def find_probe(kind, patterns):
    base = ROOT / ("test/sdk-full" if kind == "ts" else "test/sdk-python")
    pats = patterns if patterns else []
    for f in sorted(base.glob("*.probe.mjs" if kind == "ts" else "py_*.py")):
        for pat in pats:
            if pat in f.name:
                return f.name
    return None

def parse_receipt(path):
    """Return dict: pass, fail, div (internal divergence mentions), blocked,
    skip, all_pass."""
    text = read(path)
    if not text:
        return None
    d = dict(pass_=0, fail=0, div=0, blocked=0, skip=0, all_pass=False)
    d["pass"] = len(re.findall(r"\bPASS\b", text))
    d["fail"] = len(re.findall(r"\bFAIL\b", text))
    d["div"] = len(re.findall(r"DIVERGENCE|\bdivergence", text))
    d["blocked"] = len(re.findall(r"\bBLOCKED\b", text))
    d["skip"] = len(re.findall(r"\bSKIP\b", text))
    fail_rows = re.findall(r"^\|.*\*\*?(FAIL|DIVERGENCE)", text, re.M)
    d["all_pass"] = (
        not fail_rows and d["fail"] == 0 and "UNREGISTERED" not in text
        and not re.search(r"^## [Dd]ivergences", text, re.M)
    )
    return d

def split_row(line):
    parts, cur, esc = [], "", False
    for ch in line.strip().strip("|"):
        if esc:
            cur += ch; esc = False
        elif ch == "\\":
            esc = True
        elif ch == "|":
            parts.append(cur.strip()); cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    return parts

def load_kd():
    """KD id -> {surface, evidence receipts, status} (handles escaped pipes)."""
    kds = {}
    for line in read(KD_PATH).splitlines():
        if re.match(r"^\s*\|\s*KD-\d+\s*\|", line):
            parts = split_row(line)
            if len(parts) >= 4:
                status = re.match(r"[A-Za-z-]+", parts[5].strip()).group(0) if len(parts) >= 6 else "OPEN"
                kds[parts[0]] = {"surface": parts[1], "evidence": parts[3],
                                 "status": status}
    return kds

def kd_for_receipt(kds, receipt_name):
    hits = [kid for kid, v in kds.items() if receipt_name in v["evidence"]]
    return sorted(hits)

def census_crc():
    """Cross-check census probe registrations vs receipt claim."""
    text = read(CENSUS)
    base_names = re.findall(r'probe\("([\w-]+)"', text)
    extra = []  # (file, [probe names]) for supplementary probe files
    names = list(base_names)
    for rel, pat in EXTRA_PROBES:
        etext = read(ROOT / rel)
        # record(...) appears once per success arm and once per failure arm of
        # each probe; registration = distinct probe names, order-preserving.
        seen = []
        for n in re.findall(pat, etext):
            if n not in seen:
                seen.append(n)
        extra.append((rel, seen))
        names += seen
    registered_total = len(names)
    extra_n = sum(len(n) for _, n in extra)
    claim_m = re.search(r"registers (\d+) probes", read(CENSUS_RCPT))
    claimed = int(claim_m.group(1)) if claim_m else None
    header_m = re.search(r"census[^\n]*— (\d+) probes", text)
    header = int(header_m.group(1)) if header_m else None
    ok = claimed is not None and len(base_names) == claimed
    if header is not None and header != len(base_names):
        ok = False
    # supplementary files must exist and register >=1 probe to stay covered
    if any(not en for _, en in extra):
        ok = False
    return {
        "registered": registered_total - extra_n,
        "registered_total": registered_total,
        "extra": extra,
        "names": names,
        "receipt_claim": claimed,
        "header_claim": header,
        "ok": ok,
    }

def main():
    kds = load_kd()
    rows = []
    findings = []
    for s in SURFACES:
        row = {"id": s["id"], "grounded": grounding_ok(s)}
        for lang in ("ts", "py"):
            probe = find_probe(lang, s.get(lang, []))
            rcpt_name = next(
                (r for r in s.get("receipts", []) if r.startswith(lang)), None
            )
            rpath = RESULTS / rcpt_name if rcpt_name else None
            verdict = parse_receipt(rpath) if rcpt_name else None
            kd_ids = kd_for_receipt(kds, rcpt_name) if rcpt_name else []
            missing_kd = s.get("missing_kd", {}).get(lang)
            if probe is None and missing_kd:
                status = "MISSING-REGISTERED"
                kd_ids = missing_kd
            elif verdict is None and missing_kd:
                status = "MISSING-REGISTERED"
                kd_ids = missing_kd
            elif probe is None:
                status = "MISSING"
                findings.append(f"{s['id']}/{lang}: MISSING probe cell")
            elif verdict is None:
                status = "MISSING"
                findings.append(f"{s['id']}/{lang}: MISSING receipt {rcpt_name}")
            elif verdict["all_pass"]:
                status = "PASS"
            elif kd_ids and all(
                    kds[k]["status"] == "CLOSED-SIMULATED" for k in kd_ids):
                # every covered KD row was flipped CLOSED-SIMULATED by
                # scripts/kd_flip.py (shim + post-shim witness receipt):
                # simulated, not native — distinct from PASS, counts covered.
                status = "SIM-PASS"
            elif kd_ids:
                status = "REGISTERED-DIVERGENCE"
            else:
                status = "UNREGISTERED-GAP"
                findings.append(
                    f"{s['id']}/{lang}: UNREGISTERED-GAP "
                    f"(receipt {rcpt_name} records failures, no KD row cites it)"
                )
            row[lang] = {
                "probe": probe,
                "receipt": rcpt_name,
                "verdict": verdict,
                "kd": kd_ids,
                "status": status,
            }
        rows.append(row)

    # servicebus census row (both-language cells = census CRC + py lane receipt)
    crc = census_crc()
    sb_rcpt = "08-servicebus-census.md"
    sb_status = "PASS" if crc["ok"] else "UNREGISTERED-GAP"
    if not crc["ok"]:
        findings.append(
            f"servicebus/census: CRC FAIL registered={crc['registered']}"
            f" registered_total={crc['registered_total']}"
            f" claimed={crc['receipt_claim']}"
            + "".join(f" extra[{rel}]={len(en)}" for rel, en in crc["extra"])
        )

    # ---- machine summary ----
    lines = []
    print("SDK COVERAGE MATRIX — machine summary")
    print(f"divergence register: {len(kds)} KD rows loaded")
    for r in rows:
        t, p = r["ts"], r["py"]
        def cell(c):
            if c is None:
                return "-"
            kd = c["kd"] if c["status"] != "PASS" else []
            return f"{c['status']}" + (f"[{','.join(kd)}]" if kd else "")
        print(f"{r['id']:16} ground={'ok' if r['grounded'] else 'FAIL'}"
              f"  TS={cell(t)}  PY={cell(p)}")
    print(f"{CENSUS_SURFACE:16} census CRC: registered={crc['registered']}"
          f" registered_total={crc['registered_total']}"
          + "".join(f" +{len(en)} ({rel})" for rel, en in crc["extra"])
          + f" receipt_claim={crc['receipt_claim']} header={crc['header_claim']}"
          f" -> {'OK' if crc['ok'] else 'FAIL'}")
    print(f"cells PASS: {sum(1 for r in rows for c in (r['ts'], r['py']) if c and c['status']=='PASS')}")
    n_missing = sum(1 for r in rows for c in (r["ts"], r["py"]) if c and c["status"] == "MISSING")
    n_gap = sum(1 for r in rows for c in (r["ts"], r["py"]) if c and c["status"] == "UNREGISTERED-GAP")
    n_reg = sum(1 for r in rows for c in (r["ts"], r["py"]) if c and c["status"] == "REGISTERED-DIVERGENCE")
    n_sim = sum(1 for r in rows for c in (r["ts"], r["py"]) if c and c["status"] == "SIM-PASS")
    print(f"MISSING={n_missing} UNREGISTERED-GAP={n_gap} "
          f"REGISTERED-DIVERGENCE={n_reg} SIM-PASS={n_sim} "
          f"(SIM-PASS counts as covered)")
    for f in findings:
        print(f"FINDING: {f}")

    # ---- SDK_MATRIX.md ----
    md = ["# SDK Coverage Matrix (DoD-14)", "",
          "GENERATED by `scripts/sdk_coverage.py` — do not hand-edit.",
          f"Divergence register: KNOWN_DIVERGENCES.md ({len(kds)} KD rows).", "",
          "| surface | grounded | TS probe | TS receipt | TS status | PY probe | PY receipt | PY status |",
          "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        def c2(c, key):
            if c is None:
                return "-"
            v = c["verdict"] or {}
            base = c[key] or "-"
            st = c["status"] + (f" ({','.join(c['kd'])})" if c["kd"] else "")
            extra = f'<br>pass={v["pass"]} fail={v["fail"]} div={v["div"]} blk={v["blocked"]}' if v else ""
            return f"{base}{extra}<br>**{st}**"
        md.append(
            f"| {r['id']} | {'ok' if r['grounded'] else 'FAIL'} "
            f"| {c2(r['ts'], 'probe')} | {(r['ts']['receipt'] or '-') if r['ts'] else '-'} | {c2(r['ts'], 'status')} "
            f"| {c2(r['py'], 'probe')} | {(r['py']['receipt'] or '-') if r['py'] else '-'} | {c2(r['py'], 'status')} |"
        )
    md += ["", f"## Service Bus census CRC",
           "",
           f"registered={crc['registered']}"
           f" registered_total={crc['registered_total']}"
           + " ".join(f"(+{len(en)} from {rel})" for rel, en in crc["extra"])
           + f" receipt_claim={crc['receipt_claim']}"
           f" header={crc['header_claim']} -> {'OK' if crc['ok'] else 'FAIL'}",
           "", "## Findings", ""]
    md += [f"- {f}" for f in findings] if findings else ["- none"]
    MATRIX_MD.write_text("\n".join(md) + "\n")

    sys.exit(1 if findings else 0)

if __name__ == "__main__":
    main()
