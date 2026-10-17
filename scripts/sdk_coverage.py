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
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
CENSUS = ROOT / "test/sdk-smoke/census.test.cjs"
JIRA = ROOT / "docs/jira"

def window_paths(win):
    """Per-window paths (multi-window: each docs/jira/vX renders its own
    SDK_MATRIX.md from its own sdk-results/ + KNOWN_DIVERGENCES.md)."""
    base = JIRA / win
    return {
        "results": base / "sdk-results",
        "kd": base / "KNOWN_DIVERGENCES.md",
        "matrix": base / "SDK_MATRIX.md",
        "census_rcpt": base / "receipts/08-servicebus-census.md",
    }
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
SURFACES: list[dict[str, Any]] = [
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
         ts=["eventgrid"], py=["eventhub_grid"],
         receipts=["py-eventhub-eventgrid.md",
                   "docs/jira/v26.10.16/sdk-results/ts-eventgrid.md"]),
    dict(id="eventhubs", ground={"registry.ex": ["Microsoft.EventHub/namespaces/eventhubs"]},
         ts=["eventhubs"], py=["eventhub_grid"],
         receipts=["ts-event-hubs.md", "py-eventhub-eventgrid.md"]),
    dict(id="sentinel", ground={"data_plane/sentinel.ex": ["defmodule Smalt.DataPlane.Sentinel"],
                                "data_plane/kql.ex": ["defmodule"]},
         ts=["sentinel"], py=["resourcegraph_monitor"],
         receipts=["py-resourcegraph-monitor.md",
                   "docs/jira/v26.10.16/sdk-results/ts-sentinel.md"]),
         # sentinel/ts divergence candidates (workspace-id==DCR-name coupling;
         # TimeGenerated not materialized on ingest) are recorded in the KD-37
         # row — witnessed, NOT minted as separate rows.
    dict(id="resource-graph", ground={"data_plane/resource_graph.ex": ["defmodule Smalt.DataPlane.ResourceGraph"]},
         ts=["resourcegraph"], py=["resourcegraph_monitor"],
         receipts=["py-resourcegraph-monitor.md",
                   "docs/jira/v26.10.16/sdk-results/ts-resourcegraph.md"]),
    dict(id="purview-atlas", ground={"data_plane/purview_atlas.ex": ["defmodule"]},
         ts=["atlas"], py=["atlas"],
         receipts=["docs/jira/v26.10.16/sdk-results/ts-atlas.md",
                   "docs/jira/v26.10.16/sdk-results/py-atlas.md"]),
    dict(id="ledger", ground={"egress_router.ex": ["/app/transactions"],
                              "registry.ex": ["Microsoft.ConfidentialLedger/ledgers"]},
         ts=["ledger"], py=["ledger"],
         receipts=["docs/jira/v26.10.16/sdk-results/ts-ledger.md",
                   "docs/jira/v26.10.16/sdk-results/py-ledger.md"]),
    dict(id="appconfig", ground={"egress_router.ex": ['get "/kv"']},
         ts=["appconfig"], py=["appconfig"],
         receipts=["docs/jira/v26.10.16/sdk-results/ts-appconfig.md",
                   "docs/jira/v26.10.16/sdk-results/py-appconfig.md"]),
]

# surfaces whose census/AMQP cell is represented by the Service Bus census
CENSUS_SURFACE = "servicebus"

# ---------------------------------------------------------------------------
# Capability cells (v26.10.16 wave): surfaces whose wire fence is witnessed by
# a capability receipt in docs/jira/v*/receipts/ rather than an sdk-results
# probe. Ground: {lib-relative file: [keywords]} (mechanical, like SURFACES).
# Status: PASS = grounded + receipt on disk + receipt carries a standing line
# and zero FAIL tokens (the wire fence exists and is receipted); FAIL-token in
# receipt = REGISTERED-DIVERGENCE if a KD row cites the receipt else
# UNREGISTERED-GAP; no receipt on disk = MISSING (finding, gate exits 1).
# ---------------------------------------------------------------------------
CAP_CELLS: list[dict[str, Any]] = [
    dict(id="appconfig-kv",
         ground={"egress_router.ex": [":smalt_appconfig"]},
         receipts=["docs/jira/v26.10.16/receipts/cap-appconfig-kv.md"]),
    dict(id="monitor-metrics",
         ground={"arm_gateway/router.ex": ["handle_metrics"],
                 "metrics.ex": ["defmodule Smalt.Metrics"]},
         receipts=["docs/jira/v26.10.16/receipts/cap-monitor-metrics.md"]),
    dict(id="eh-consumergroups",
         ground={"registry.ex": ["Microsoft.EventHub/namespaces/eventhubs/consumergroups"],
                 "arm_gateway/router.ex": ["consumergroups"]},
         receipts=["docs/jira/v26.10.16/receipts/cap-eh-consumergroups.md"]),
    dict(id="eventgrid-topics-arm",
         ground={"registry.ex": ["Microsoft.EventGrid/topics"],
                 "arm_gateway/router.ex": ["Microsoft.EventGrid/topics/:name"]},
         receipts=["docs/jira/v26.10.16/receipts/cap-eventgrid-topics.md"]),
    dict(id="blob-snapshot-metadata",
         ground={"data_plane/blob_storage.ex": ["snapshot_blob"],
                 "egress_router.ex": ["x-ms-snapshot"]},
         receipts=["docs/jira/v26.10.16/receipts/cap-blob-snapshot-metadata.md"]),
    dict(id="cosmos-throughput",
         ground={"data_plane/cosmos.ex": ["throughput"]},
         receipts=["docs/jira/v26.10.16/receipts/r118-cosmos-put-replace.md"]),
    dict(id="sb-eh-2024-children",
         ground={"registry.ex": ['"Microsoft.ServiceBus/namespaces" => "2024-01-01"',
                                 '"Microsoft.EventHub/namespaces" => "2024-01-01"']},
         receipts=["docs/jira/v26.10.16/receipts/cap-sb-eh-apiversion-2024.md"]),
]

STANDING_RE = re.compile(r"\bStanding\b.*?:\s*\**\s*([A-Z_]+)", re.I)

def compile_cap_cells(kds, findings):
    cells = []
    for s in CAP_CELLS:
        grounded = grounding_ok(s)
        rcpt = next((r for r in s["receipts"] if (ROOT / r).exists()), None)
        text = read(ROOT / rcpt) if rcpt else ""
        standing = None
        m = STANDING_RE.search(text)
        standing = m.group(1) if m else None
        if not grounded:
            status = "MISSING"
            findings.append(f"{s['id']}/cap: ground keywords absent from lib/ "
                            "(surface not implemented)")
        elif rcpt is None:
            status = "MISSING"
            findings.append(f"{s['id']}/cap: MISSING capability receipt "
                            f"(searched: {s['receipts']})")
        elif "FAIL" in text or standing in (None, "FAIL"):
            # failing receipt: covered only if a KD row cites it
            kd_ids = sorted(kid for kid, v in kds.items()
                            if rcpt in v["evidence"]
                            or rcpt.rsplit("/", 1)[-1] in v["evidence"]
                            or rcpt in v.get("status_full", "")
                            or rcpt.rsplit("/", 1)[-1] in v.get("status_full", ""))
            if kd_ids:
                status = "REGISTERED-DIVERGENCE"
            else:
                status = "UNREGISTERED-GAP"
                findings.append(f"{s['id']}/cap: receipt {rcpt} records FAIL "
                                "with no KD row citing it")
        elif standing == "PARTIAL_ALIVE":
            # receipt on disk, zero FAIL tokens, standing PARTIAL_ALIVE:
            # wire fence exists but is partial — covered, counted separately
            # from PASS, never a finding.
            status = "PASS-PARTIAL"
        else:
            status = "PASS"
        cells.append({"id": s["id"], "grounded": grounded, "receipt": rcpt,
                      "standing": standing, "status": status})
    return cells

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

def load_kd(kd_path):
    """KD id -> {surface, evidence receipts, status} (handles escaped pipes)."""
    kds = {}
    for line in read(kd_path).splitlines():
        if re.match(r"^\s*\|\s*KD-\d+\s*\|", line):
            parts = split_row(line)
            if len(parts) >= 4:
                status_full = parts[5].strip() if len(parts) >= 6 else ""
                m = re.match(r"[A-Za-z-]+", status_full)
                status = m.group(0) if m else "OPEN"
                kds[parts[0]] = {"surface": parts[1], "evidence": parts[3],
                                 "status": status, "status_full": status_full}
    return kds

# Receipt paths a KD row may cite: ANY path under a receipts/ or audit
# sections dir — not just sdk-results filenames.
RECEIPT_PATH_RE = re.compile(
    r"(docs/(?:jira/v[^/\s`|)]+/receipts|audit/sections)/[^\s`|)]+)")

def kd_receipt_paths(row):
    """Receipt paths cited anywhere in a KD row (evidence or status cell)."""
    return list(dict.fromkeys(RECEIPT_PATH_RE.findall(
        row.get("evidence", "") + " " + row.get("status_full", ""))))

# KD-annotation cells: (surface, lang, [KD ids]). These cover divergences
# whose witness receipts live outside sdk-results/ (shim-court closures +
# witnessed open rows), so kd_for_receipt alone cannot see them.
KD_CELLS = [
    ("servicebus", "ts", ["KD-45"]),
    ("eventhubs", "ts", ["KD-53", "KD-76"]),
    ("eventhubs", "py", ["KD-70", "KD-71"]),
    ("servicebus", "py", ["KD-77"]),
    ("arm", "ts", ["KD-91"]),
    ("blob", "ts", ["KD-92"]),
    ("cosmos", "ts", ["KD-93"]),
]

def kd_for_receipt(kds, receipt_name):
    """KD ids citing this receipt in evidence OR status cell. A closed row's
    closure receipt lives in its status cell, so basename matching covers both
    plain sdk-results filenames and window-qualified docs/jira/... paths."""
    base = receipt_name.rsplit("/", 1)[-1]
    hits = [kid for kid, v in kds.items()
            if receipt_name in v["evidence"] or base in v["evidence"]
            or receipt_name in v.get("status_full", "")
            or base in v.get("status_full", "")]
    return sorted(hits)

def census_crc(census_rcpt):
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
    claim_m = re.search(r"registers (\d+) probes", read(census_rcpt))
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

def discover_windows():
    """Windows = docs/jira/v* dirs carrying a KNOWN_DIVERGENCES.md (i.e. a
    milestone window with a divergence register). Sorted ascending; each
    renders docs/jira/v<win>/SDK_MATRIX.md from its own sdk-results/."""
    return sorted(
        p.parent.name for p in JIRA.glob("v*/KNOWN_DIVERGENCES.md")
    )

def compile_window(win):
    wp = window_paths(win)
    results, kd_path, matrix_md, census_rcpt = (
        wp["results"], wp["kd"], wp["matrix"], wp["census_rcpt"])
    print(f"=== window {win} ===")
    # KD ids are globally unique across windows; merge every window's register
    # (own window wins) so a cell in this window can cite a KD row whose row
    # text lives in another window's register.
    kds = {}
    for other_win in discover_windows():
        kds.update(load_kd(window_paths(other_win)["kd"]))
    kds.update(load_kd(kd_path))
    rows = []
    findings = []
    for s in SURFACES:
        row = {"id": s["id"], "grounded": grounding_ok(s)}
        for lang in ("ts", "py"):
            probe = find_probe(lang, s.get(lang, []))
            rcpt_name = next(
                (r for r in s.get("receipts", [])
                 if r.rsplit("/", 1)[-1].startswith(lang)), None
            )
            rpath = None
            if rcpt_name:
                # docs/-prefixed receipt names are window-qualified
                # cross-window witnesses (e.g. a closed v14 KD row whose
                # closure receipt landed in the active window's sdk-results).
                rpath = (ROOT / rcpt_name if rcpt_name.startswith("docs/")
                         else results / rcpt_name)
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
            elif kd_ids and all(
                    kds[k]["status"].startswith("CLOSED") for k in kd_ids):
                # probe-authored closure: KD rows closed with a witness
                # receipt (e.g. CLOSED-WITH-RECEIPT citing a sdk-results
                # probe receipt) — counts covered, distinct from SIM-PASS.
                status = "CLOSED-RECEIPT"
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
    crc = census_crc(census_rcpt)
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
    n_closed = sum(1 for r in rows for c in (r["ts"], r["py"]) if c and c["status"] == "CLOSED-RECEIPT")
    print(f"MISSING={n_missing} UNREGISTERED-GAP={n_gap} "
          f"REGISTERED-DIVERGENCE={n_reg} SIM-PASS={n_sim} "
          f"CLOSED-RECEIPT={n_closed} "
          f"(SIM-PASS and CLOSED-RECEIPT count as covered)")
    for f in findings:
        print(f"FINDING: {f}")

    # ---- KD-annotation cells (SHIM-COURT-derived coverage, KD-COVERS law) ----
    # Cells may cite ANY receipt path on disk (docs/jira/*/receipts/*.md,
    # docs/audit/sections/*.md), not just sdk-results/ filenames: a KD row
    # that is CLOSED-SIMULATED with its witness receipt present -> SIM-PASS;
    # a KD row that is OPEN with a witness receipt on disk ->
    # REGISTERED-DIVERGENCE (loudly visible, registered); otherwise the cell
    # is MISSING and is a finding (gate exits 1).
    kd_cells = []
    for surface, lang, cell_kds in KD_CELLS:
        resolved, missing = [], []
        for kid in cell_kds:
            row = kds.get(kid)
            if row is None:
                missing.append(f"{kid}: no KD row in {win} register")
                continue
            paths = kd_receipt_paths(row)
            on_disk = [p for p in paths if (ROOT / p).exists()]
            resolved.append((kid, row["status"], row["status_full"], on_disk))
        if missing or any(not r[3] for r in resolved):
            status = "MISSING"
            for m in missing:
                findings.append(f"{surface}/{lang} kd-cell: MISSING KD row {m}")
            for kid, st, _sf, disk in resolved:
                if not disk:
                    findings.append(
                        f"{surface}/{lang} kd-cell: {kid} status={st} "
                        f"but no cited receipt exists on disk "
                        f"(searched: {kd_receipt_paths(kds.get(kid, {'evidence': '', 'status_full': ''})) or ['<none>']})")
        elif any(st == "OPEN" and disk for _kid, st, _sf, disk in resolved):
            status = "REGISTERED-DIVERGENCE"
        elif all(st == "CLOSED-SIMULATED" and disk for _kid, st, _sf, disk in resolved):
            # shim landed + witness receipt postdates it (kd_flip.py law):
            # simulated, not native — counts as covered.
            status = "SIM-PASS"
        else:
            status = "MISSING"
            findings.append(
                f"{surface}/{lang} kd-cell: unhandled KD statuses "
                f"{[st for _kid, st, _sf, _d in resolved]}")
        kd_cells.append({
            "surface": surface, "lang": lang, "kds": cell_kds,
            "resolved": resolved, "status": status,
        })
    n_kd_sim = sum(1 for c in kd_cells if c["status"] == "SIM-PASS")
    n_kd_reg = sum(1 for c in kd_cells if c["status"] == "REGISTERED-DIVERGENCE")
    n_kd_missing = sum(1 for c in kd_cells if c["status"] == "MISSING")
    print(f"kd-annotation cells: SIM-PASS={n_kd_sim} "
          f"REGISTERED-DIVERGENCE={n_kd_reg} MISSING={n_kd_missing}")
    for c in kd_cells:
        print(f"  kd-cell {c['surface']}/{c['lang']}: {c['status']}"
              + "".join(
                  f"\n    {kid} [{st}]"
                  + (f" receipts: {'; '.join(d)}" if d else " receipts: NONE ON DISK")
                  for kid, st, _sf, d in c["resolved"]))

    # ---- capability cells (v26.10.16 wave surfaces) ----
    cap_cells = compile_cap_cells(kds, findings)
    n_cap_pass = sum(1 for c in cap_cells if c["status"] == "PASS")
    n_cap_partial = sum(1 for c in cap_cells if c["status"] == "PASS-PARTIAL")
    n_cap_reg = sum(1 for c in cap_cells if c["status"] == "REGISTERED-DIVERGENCE")
    n_cap_gap = sum(1 for c in cap_cells if c["status"] == "UNREGISTERED-GAP")
    n_cap_missing = sum(1 for c in cap_cells if c["status"] == "MISSING")
    print(f"capability cells: PASS={n_cap_pass} PASS-PARTIAL={n_cap_partial} "
          f"REGISTERED-DIVERGENCE={n_cap_reg} UNREGISTERED-GAP={n_cap_gap} "
          f"MISSING={n_cap_missing}")
    for c in cap_cells:
        print(f"  cap-cell {c['id']:24} ground={'ok' if c['grounded'] else 'FAIL'}"
              f" receipt={'-' if not c['receipt'] else c['receipt']}"
              f" standing={c['standing']} -> {c['status']}")

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
    md += ["", "## KD-annotation cells", "",
           "Cells resolved from KD-register evidence/status receipts "
           "(any `docs/jira/*/receipts/*.md` or `docs/audit/sections/*.md` "
           "path), not just sdk-results filenames.", "",
           "| surface | lang | KDs | witness receipts on disk | status |",
           "|---|---|---|---|---|"]
    for c in kd_cells:
        rcpts = "; ".join(
            p for _kid, _st, _sf, disk in c["resolved"] for p in disk) or "-"
        md.append(f"| {c['surface']} | {c['lang']} | {', '.join(c['kds'])} "
                  f"| {rcpts} | **{c['status']}** |")
    md += ["", "## Capability cells (receipt-witnessed wire fences)", "",
           "Surfaces whose wire fence is witnessed by a capability receipt "
           "(standing line, zero FAIL) rather than an sdk-results probe.",
           "",
           "| surface | grounded | receipt | standing | status |",
           "|---|---|---|---|---|"]
    for c in cap_cells:
        md.append(f"| {c['id']} | {'ok' if c['grounded'] else 'FAIL'} "
                  f"| {c['receipt'] or '-'} | {c['standing'] or '-'} "
                  f"| **{c['status']}** |")
    md += ["", "## Service Bus census CRC",
           "",
           f"registered={crc['registered']}"
           f" registered_total={crc['registered_total']}"
           + " ".join(f"(+{len(en)} from {rel})" for rel, en in crc["extra"])
           + f" receipt_claim={crc['receipt_claim']}"
             f" header={crc['header_claim']} -> {'OK' if crc['ok'] else 'FAIL'}",
           "", "## Findings", ""]
    md += [f"- {f}" for f in findings] if findings else ["- none"]
    matrix_md.write_text("\n".join(md) + "\n")
    return findings

def main():
    all_findings = []
    for win in discover_windows():
        has_results = window_paths(win)["results"].is_dir()
        kds = load_kd(window_paths(win)["kd"])
        gating = has_results or bool(kds)
        if not gating:
            print(f"[non-gating] window {win}: no sdk-results/ and empty "
                  f"divergence register — rendered, excluded from exit")
        fnd = compile_window(win)
        if not gating:
            fnd = []
        all_findings += fnd
    if all_findings:
        print(f"GATE: FAIL ({len(all_findings)} findings)")
    else:
        print("GATE: OK — every cell pass / registered / sim-pass / missing-registered")
    sys.exit(1 if all_findings else 0)

if __name__ == "__main__":
    main()
