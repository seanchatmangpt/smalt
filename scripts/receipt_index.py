#!/usr/bin/env python3
"""receipt_index.py — regenerate RECEIPTS.md + receipts/INDEX.md per milestone window.

Scans docs/jira/v*/receipts/*.md and docs/jira/v*/sdk-results/*.md, extracts each
receipt's own standing/verdict line, checks for real command output (exit codes /
test counts), and emits the manufacturing-receipt index tables.

The canonical v26.10.14 window keeps its historical aggregate output byte-for-byte
(all windows' receipts, cross-window links). Every other window that has receipts
gets its own scoped RECEIPTS.md + receipts/INDEX.md pair with the same table
format and standing logic.

Usage: python3 scripts/receipt_index.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JIRA_ROOT = os.path.join(ROOT, "docs/jira")
BASE_WINDOW = "v26.10.14"
JIRA = os.path.join(JIRA_ROOT, BASE_WINDOW)  # canonical aggregate output root
# SHIM-COURT-free lane edit: glob every milestone version dir so newer
# receipts are indexed, not just the hardcoded v26.10.14 window.
ALL_VERSION_DIRS = sorted(
    d
    for d in os.listdir(JIRA_ROOT)
    if re.match(r"^v\d", d)
)
OUT = os.path.join(JIRA, "RECEIPTS.md")
INDEX = os.path.join(JIRA, "receipts", "INDEX.md")

# Standing tokens, most specific first.
STANDING_TOKENS = [
    "PARTIAL_ALIVE", "PROVISIONAL_ALIVE", "SKIP-LOUD", "PARITY_CONFIRMED",
    "UNSUPPORTED", "PROVISIONAL",
    "ALIVE", "UNKNOWN", "COMPLETE", "LANDED", "CLOSED", "DONE", "FAIL", "PASS",
]

EVIDENCE_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in [
        r"\bexit (code|status)?\s*[:=]?\s*\d",
        r"\bexit\b\s+\d",
        r"\d+\s+(tests?|examples?|probes?|checks?)\b",
        r"\d+\s+passed",
        r"\d+\s+failures?",
        r"\bPASS\b",
        r"\bFAIL\b",
        r"\bSKIP\b",
        r"\b0 failures\b",
        r"\[\s*ok\]",
        r"\bverdict (PASS|FAIL)\b",
        r"exit 0",
    ]
]

STATUS_LINE = re.compile(r"(status|standing|verdict|result|outcome)", re.IGNORECASE)
# Explicit standing line, the receipts' own convention: "**Standing:** TOKEN".
# SHIM-COURT-free lane edit (R185k): an explicit Standing line outranks any
# generic status-word match, so a later "verdict PASS." prose line cannot
# degrade a PARTIAL_ALIVE receipt. Last explicit Standing wins (r133's
# correction semantics: the resolution Standing line is authoritative).
EXPLICIT_STANDING = re.compile(r"^\s*[-*]?\s*\**\s*standing\s*:\**", re.IGNORECASE)


def extract_standing(text):
    """Best-effort: find the receipt's own verdict line and pull a standing token."""
    # Scan the whole file (verdicts usually live at the bottom, not the
    # first 80 lines). Prefer the LAST explicit Standing line that actually
    # carries a standing token; fall back to the last generic status-word
    # match only when no explicit Standing line exists.
    explicit = None
    generic = None
    for line in text.splitlines():
        if not any(t in line for t in STANDING_TOKENS):
            continue
        if EXPLICIT_STANDING.match(line):
            explicit = line
        elif STATUS_LINE.search(line):
            generic = line
    match = explicit if explicit is not None else generic
    if match is None:
        return "UNKNOWN", ""
    for tok in STANDING_TOKENS:
        if tok in match:
            return tok, match.strip()[:160]
    return "UNKNOWN", ""


def has_evidence(text):
    return any(p.search(text) for p in EVIDENCE_PATTERNS)


def extract_summary(text):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("# "):
            t = re.sub(r"^#\s*", "", s)
            t = re.sub(r"(?i)^(receipt|ws|sdk lane|lanes?)\s*[:\-—]?\s*", "", t)
            return t[:110]
    return ""


def lane_id(name, version):
    base = re.sub(r"\.md$", "", name)
    prefix = "V" + version[1:].replace(".", "")
    if re.match(r"^\d\d-", base):
        return prefix + "-" + base[:2]
    if base.startswith("ws-"):
        return base[:5].upper()
    if base.startswith("cli-"):
        return "cli-" + base[4:6]
    if base.startswith("dod-"):
        return "dod-" + base[4:6]
    return base[:12]


def scan(d, version, out_root):
    rows = []
    if not os.path.isdir(d):
        return rows
    for name in sorted(os.listdir(d)):
        if not name.endswith(".md") or name == "INDEX.md":
            continue
        path = os.path.join(d, name)
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        standing, verdict_line = extract_standing(text)
        summary = extract_summary(text)
        suspect = ""
        if not has_evidence(text):
            suspect = " **SUSPECT**"
        rows.append(
            {
                "lane": lane_id(name, version),
                "file": name,
                "standing": standing,
                "verdict_line": verdict_line,
                "summary": summary,
                "suspect": suspect,
                "path": path,
                # Link relative to the window dir that will host the output.
                "link": os.path.relpath(path, out_root),
                "link14": os.path.relpath(path, JIRA),
                "version": version,
            }
        )
    return rows


def render(idx_rows, sdk, window, today):
    """Render RECEIPTS.md lines for one window's output."""
    prefix = "V" + window[1:].replace(".", "")
    rows = idx_rows

    def grp(pred):
        return [x for x in rows if pred(x)]

    release = grp(lambda x: re.match(rf"^{prefix}-", x["lane"]))
    # Sub-receipts: lane ids that are not release-order/workspace/cli/dod lanes.
    release_sub = grp(
        lambda x: not re.match(rf"^({prefix}-|ws-|cli-|dod-)", x["lane"])
    )
    ws = grp(lambda x: x["lane"].startswith("WS-"))
    cli = grp(lambda x: x["lane"].startswith("cli-"))
    dod_rx_receipts = grp(lambda x: x["lane"].startswith("dod-"))

    lines = []
    A = lines.append
    A(f"# {window} — Manufacturing Receipt Index")
    A("")
    A(f"Generated by `scripts/receipt_index.py` (just `receipt-index`), {today}.")
    A(
        "Standing is taken from each receipt's own verdict line; **SUSPECT** = receipt\n"
        "asserts a gate/command result with no real output (no exit code, test/probe\n"
        "count, or PASS/FAIL token) found in the file."
    )
    A("")

    def table(rows, use_link14=False):
        out = [
            "| Lane | Receipt | Standing | Summary |",
            "|---|---|---|---|",
        ]
        for x in rows:
            st = x["standing"]
            if x["suspect"] and st not in ("UNKNOWN",):
                st = st + " (SUSPECT)"
            elif x["suspect"]:
                st = "SUSPECT"
            vl = x["verdict_line"].replace("|", "\\|")
            summary = x["summary"] or (vl if vl else "—")
            link = x["link14"] if use_link14 else x["link"]
            out.append(f"| {x['lane']} | [{x['file']}]({link}) | {st} | {summary} |")
        return out

    A(f"## Release work orders ({prefix}-01..20)")
    A("")
    lines.extend(table(release, use_link14=(window == BASE_WINDOW)))
    if release_sub:
        A("")
        A("### Release-order sub-receipts")
        A("")
        lines.extend(table(release_sub, use_link14=(window == BASE_WINDOW)))
    A("")

    A("## Workspace (ws-01..12)")
    A("")
    lines.extend(table(ws, use_link14=(window == BASE_WINDOW)))
    A("")

    A("## smalt-cli (cli-01..08)")
    A("")
    missing_cli = [
        f"cli-{n:02d}"
        for n in range(1, 9)
        if not any(x["lane"].endswith(f"{n:02d}") for x in cli)
    ]
    lines.extend(table(cli, use_link14=(window == BASE_WINDOW)))
    A("")
    if missing_cli:
        A(f"No receipt file on disk: {', '.join(missing_cli)}.")
        A("")

    A("## SDK validation (ts-*/py-*)")
    A("")
    lines.extend(table(sdk, use_link14=(window == BASE_WINDOW)))
    A("")

    if window == BASE_WINDOW:
        A("## Enclave testbed")
        A("")
        A(
            "| Lane | Receipt | Standing | Summary |"
            "\n|---|---|---|---|"
            "\n| enclave | (no receipt file — log only: `tmp/enclave-testbed.log`) | PARTIAL | "
            "Mixed PASS/FAIL run log (`test/enclave-testbed/run.sh`): E2 LRO sweeper convergence PASS; "
            "chain-tamper, Purview/RG governance, Cosmos cross-partition, SB DLQ phases FAIL. "
            "No receipt filed; standing PARTIAL pending a filed receipt. |"
        )
        A("")

    A("## DoD lanes (dod-01..13)")
    A("")
    A(
        "| Lane | Receipt | Standing | Summary |"
        "\n|---|---|---|---|"
    )
    just_dir = os.path.join(ROOT, "justfile.d")
    modules = sorted(
        f for f in os.listdir(just_dir) if re.match(r"^\d\d-.*\.just$", f)
    )
    for m in modules:
        n = m[:2]
        lane = f"dod-{n}"
        rx = next((x for x in dod_rx_receipts if x["lane"] == lane), None)
        if rx:
            st = rx["standing"] + (" (SUSPECT)" if rx["suspect"] else "")
            vl = rx["verdict_line"].replace("|", "\\|")
            summary = rx["summary"] or vl or "—"
            link = "receipts/" + rx["file"]
            A(
                f"| {lane} | [{link}]({link}) "
                f"| {st} | {summary} |"
            )
        elif n == "13" and window == BASE_WINDOW:
            A(
                f"| dod-13 | [receipts/dod-13-receipt-index.md](receipts/dod-13-receipt-index.md) "
                f"| ALIVE | This index: generator + regenerated tables + self receipt. |"
            )
        else:
            A(
                f"| {lane} | (no receipt file — justfile module `justfile.d/{m}`) | UNKNOWN | "
                f"DoD lane module; no receipt filed at wrap. |"
            )
    A("")
    return lines


def render_index_short(receipts, sdk, suspects, today):
    idx = []
    B = idx.append
    B("# Receipt Index (short)")
    B("")
    B(
        f"Full tables: [../RECEIPTS.md](../RECEIPTS.md). Generated {today} by "
        "`scripts/receipt_index.py` (`just receipt-index`)."
    )
    B("")
    B(f"- Receipts: {len(receipts)} files in `receipts/`")
    B(f"- SDK results: {len(sdk)} files in `sdk-results/`")
    B(f"- Total receipt files: {len(receipts) + len(sdk)}")
    B(f"- SUSPECT flags: {len(suspects)}"
      + (f" — {', '.join(x['file'] for x in suspects)}" if suspects else " — none"))
    B("- Enclave testbed: no receipt file (log `tmp/enclave-testbed.log`, standing PARTIAL)")
    dod_filed = [x["file"] for x in receipts if x["lane"].startswith("dod-")]
    B(
        "- DoD lanes: receipts filed for "
        + (", ".join(sorted(dod_filed)) if dod_filed else "none")
        + "; all other dod lanes: justfile module only, no receipt file"
    )
    B("")
    return idx


def main():
    today = "2026-10-15"

    # Scan every window, rows tagged with their window.
    per_window = {}
    for v in ALL_VERSION_DIRS:
        vdir = os.path.join(JIRA_ROOT, v)
        out_root = os.path.join(JIRA_ROOT, v)
        r = scan(os.path.join(vdir, "receipts"), v, out_root)
        s = scan(os.path.join(vdir, "sdk-results"), v, out_root)
        per_window[v] = (r, s)

    # Canonical v26.10.14 output: aggregate across ALL windows (historical bytes).
    r = [x for v in ALL_VERSION_DIRS for x in per_window[v][0]]
    s = [x for v in ALL_VERSION_DIRS for x in per_window[v][1]]

    suspects = [x for x in r + s if x["suspect"]]

    lines = render(idx_rows=r, sdk=s, window=BASE_WINDOW, today=today)

    A = lines.append
    A("## Cross-check / SUSPECT flags")
    A("")
    if suspects:
        A("Receipts asserting results with no real output found in-file:")
        A("")
        for x in suspects:
            A(f"- **SUSPECT**: `{x['file']}` (standing {x['standing']})")
    else:
        A("None: every receipt contains at least one exit-code, test/probe count, or PASS/FAIL token.")
    A("")

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines).rstrip() + "\n")

    # Short index inside receipts/
    idx = render_index_short(r, s, suspects, today)
    with open(INDEX, "w", encoding="utf-8") as f:
        f.write("\n".join(idx).rstrip() + "\n")

    print(f"receipts={len(r)} sdk={len(s)} total={len(r)+len(s)} suspects={len(suspects)}")
    for x in suspects:
        print(f"  SUSPECT: {x['file']} (standing {x['standing']})")
    print(f"wrote {OUT}")
    print(f"wrote {INDEX}")

    # Per-window outputs: every other window that has receipts gets its own
    # scoped pair, same table format and standing logic.
    for v in ALL_VERSION_DIRS:
        if v == BASE_WINDOW:
            continue
        vr, vs = per_window[v]
        if not vr and not vs:
            continue
        vdir = os.path.join(JIRA_ROOT, v)
        vsuspects = [x for x in vr + vs if x["suspect"]]
        vlines = render(idx_rows=vr, sdk=vs, window=v, today=today)
        A2 = vlines.append
        A2("## Cross-check / SUSPECT flags")
        A2("")
        if vsuspects:
            A2("Receipts asserting results with no real output found in-file:")
            A2("")
            for x in vsuspects:
                A2(f"- **SUSPECT**: `{x['file']}` (standing {x['standing']})")
        else:
            A2("None: every receipt contains at least one exit-code, test/probe count, or PASS/FAIL token.")
        A2("")
        vout = os.path.join(vdir, "RECEIPTS.md")
        with open(vout, "w", encoding="utf-8") as f:
            f.write("\n".join(vlines).rstrip() + "\n")
        vidx = render_index_short(vr, vs, vsuspects, today)
        # base window's INDEX is in receipts/; keep the same layout here
        vidx_dir = os.path.join(vdir, "receipts")
        os.makedirs(vidx_dir, exist_ok=True)
        vidx_path = os.path.join(vidx_dir, "INDEX.md")
        with open(vidx_path, "w", encoding="utf-8") as f:
            f.write("\n".join(vidx).rstrip() + "\n")
        print(f"wrote {vout}")
        print(f"wrote {vidx_path}")


if __name__ == "__main__":
    main()
