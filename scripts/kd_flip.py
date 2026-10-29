#!/usr/bin/env python3
"""KD flip tool — contract-keyed shim registry drives KNOWN_DIVERGENCES closure.

Mechanism (lane S-7, v26.10.14):

1. Shims mark the KD ids they cover at the edit site as a comment token:

     # KD-COVERS: KD-21,KD-49      (Elixir)
     // KD-COVERS: KD-15           (TS/JS)

   This tool scans lib/ and workspace/lib (overridable via --scan-root,
   repeatable) and builds a covers-map: KD id -> [(file, mtime)].

2. For each KD row with status OPEN whose id appears in the covers-map, the
   witness is the KD row's evidence path(s) (column 4 of the register). If an
   evidence receipt (or a newer file under the receipts dir mentioning the id)
   has mtime AFTER the newest shim mtime and shows a PASS verdict, the row is
   FLIP-ELIGIBLE. Otherwise (probe cannot run / no post-shim witness yet) it
   is FLIP-PENDING-WITNESS.

3. --apply updates KNOWN_DIVERGENCES.md status OPEN -> CLOSED-SIMULATED
   (meaning: shim landed, witness receipt at <path>) ONLY for FLIP-ELIGIBLE
   rows. Rows are never flipped on the tool's own judgement of code — only on
   a witnessed post-shim receipt.

4. Exit 1 listing any KD-COVERS token whose KD id is missing from the
   register (forces register sync). Unknown ids are NEVER flipped.

Read-only by default; mutates only with --apply.
"""

import argparse
import os
import re
import sys
import time
from pathlib import Path

# KD_FLIP_ROOT lets courts/self-tests point the tool at a fixture tree
# without copying the script (2026-10-22, KD-FLIPFIX lane).
ROOT = Path(os.environ.get("KD_FLIP_ROOT",
                           Path(__file__).resolve().parent.parent))
JIRA = ROOT / "docs/jira/v26.10.14"
KD_PATH = JIRA / "KNOWN_DIVERGENCES.md"
DEFAULT_SCAN_ROOTS = [ROOT / "lib", ROOT / "workspace/lib"]
RESULTS_DIR = JIRA / "sdk-results"


def receipt_dirs():
    """All milestone receipt windows + this register's sdk-results dir.

    The register may be closed (e.g. v26.10.14) while witness receipts land
    under the active window (docs/jira newest dir, e.g. v26.10.16); the
    mtime gate is what makes cross-window witnesses lawful, not the path.
    """
    return sorted((ROOT / "docs/jira").glob("v*/receipts")) + [RESULTS_DIR]

COVERS_RE = re.compile(r"(?:#|//).*?KD-COVERS:[ \t]*([A-Za-z0-9_,\- \t]+)")
KD_ROW_RE = re.compile(r"^\s*\|\s*(KD-\d+)\s*\|(.*)$")


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


def load_register():
    """KD id -> {line_no, parts, status, evidence}."""
    rows = {}
    for i, line in enumerate(KD_PATH.read_text(errors="replace").splitlines(), 1):
        m = KD_ROW_RE.match(line)
        if not m:
            continue
        parts = split_row(line)
        if len(parts) < 6:
            continue
        # trailing prose may follow; empty cell -> empty status (not a KD row crash)
        sm = re.match(r"[A-Za-z-]+", parts[5].strip())
        status = sm.group(0) if sm else ""
        rows[m.group(1)] = {
            "line_no": i,
            "parts": parts,
            "status": status,
            "evidence": parts[3],
        }
    return rows


def scan_covers(scan_roots):
    """covers-map: KD id -> {file: newest mtime}."""
    covers = {}
    for root in scan_roots:
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if p.suffix not in (".ex", ".exs", ".js", ".mjs", ".cjs", ".ts", ".py"):
                continue
            try:
                text = p.read_text(errors="replace")
            except OSError:
                continue
            for m in COVERS_RE.finditer(text):
                for tok in re.split(r"[,\s]+", m.group(1)):
                    tok = tok.strip()
                    if not tok:
                        continue
                    entry = covers.setdefault(tok, {})
                    mt = p.stat().st_mtime
                    if p not in entry or mt > entry[p]:
                        entry[p] = mt
    return covers


def evidence_paths(evidence_field):
    """Extract repo-relative doc paths from the evidence column."""
    paths = []
    for m in re.finditer(r"([\w./-]+\.(?:md|log|json))", evidence_field):
        rel = m.group(1)
        for base in (JIRA, ROOT):
            p = base / rel if not rel.startswith("docs/") else ROOT / rel
            if p.exists():
                paths.append(p)
                break
    return paths


def shows_pass(path, kid):
    text = path.read_text(errors="replace")
    # Repo standing vocabulary: a receipt's own standing line is its verdict.
    # ALIVE/PASS both qualify; SUSPECT/FAIL do not (2026-10-21: KD-51's lawful
    # witness read "CREATE OK / RUNTIME OK / ..." with Standing: ALIVE and was
    # invisible to the narrower PASS-only grep).
    has_pass = bool(re.search(r"\bPASS\b", text)) or bool(re.search(
        r"(?:\*\*)?[Ss]tanding(?:\*\*)?:\s*\**\s*ALIVE\b", text))
    # a FAIL/DIVERGENCE verdict row naming this id negates
    negated = bool(re.search(
        rf"^\s*\|.*{re.escape(kid)}\b.*\*\*?(FAIL|DIVERGENCE)", text, re.M))
    return has_pass and not negated


CLOSE_EVIDENCE_RE = re.compile(r"KD-COVERS|Disposition|CLOSED-|Standing:")
WITNESS_WINDOW = 5  # lines either side of the id mention


def strip_fences(text):
    """Drop fenced code blocks (embedded command output). A receipt that only
    names the id inside a scan-output block is a mention-only witness."""
    out, fenced = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            out.append(line)
        else:
            out.append("")
    return "\n".join(out)


def close_evidence(text, kid):
    """True when a prose line (fenced command output stripped) naming `kid`
    has close evidence within WITNESS_WINDOW lines: a KD-COVERS reference, a
    Disposition/CLOSED- marker, or a Standing: line. Mention-only receipts —
    surveys, mint notes, receipts whose only id mention is inside an embedded
    scan-output fence — do not qualify (KD-144 mis-flip class, BK-55)."""
    text = strip_fences(text)
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if kid not in line:
            continue
        window = "\n".join(lines[max(0, i - WITNESS_WINDOW):i + WITNESS_WINDOW + 1])
        if CLOSE_EVIDENCE_RE.search(window):
            return True
    return False


def witness(kid, evidence_field, shim_mtime, explicit=None):
    import sys
    row_line = next((l for l in open(JIRA / "KNOWN_DIVERGENCES.md", errors="replace") if l.startswith(f"| {kid} |")), "")
    if "DO-NOT-FLIP" in row_line:
        return ("DO-NOT-FLIP", "registrar hold — cross-id evidence matches are refused")
    """Return (verdict, witness_path_or_reason).

    FLIP-ELIGIBLE: an explicit --witness path, or exactly ONE inferred
    receipt that (a) is newer than the newest shim mtime, (b) shows a pass,
    AND (c) carries row-specific close evidence (KD-COVERS / Disposition /
    CLOSED- within WITNESS_WINDOW lines of the id). Zero → FLIP-PENDING-
    WITNESS; more than one → AMBIGUOUS (refused, never auto-picked — the
    bk52 mint-receipt mis-flip class, BK-55).
    """
    if explicit is not None:
        p = Path(explicit)
        if not p.is_file():
            return ("REFUSED",
                    f"--witness path not found: {p}")
        text = p.read_text(errors="replace")
        mt = p.stat().st_mtime
        if mt <= shim_mtime:
            return ("FLIP-PENDING-WITNESS",
                    f"--witness receipt predates shim mtime "
                    f"({time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(shim_mtime))})")
        if not close_evidence(text, kid):
            return ("FLIP-PENDING-WITNESS",
                    f"--witness receipt lacks close evidence for {kid} "
                    f"(no KD-COVERS/Disposition/CLOSED- within {WITNESS_WINDOW} lines of the id)")
        if not shows_pass(p, kid):
            return ("FLIP-PENDING-WITNESS", f"--witness receipt shows no pass for {kid}")
        try:
            rel = str(p.resolve().relative_to(ROOT))
        except ValueError:
            rel = str(p.resolve())
        return "FLIP-ELIGIBLE", rel

    candidates = evidence_paths(evidence_field)
    for base in receipt_dirs():
        if not base.exists():
            continue
        for p in base.iterdir():
            if p.is_file() and kid in p.read_text(errors="replace"):
                candidates.append(p)
    qualifying, mention_only = [], []
    for p in sorted(set(candidates)):
        mt = p.stat().st_mtime
        text = p.read_text(errors="replace")
        if mt <= shim_mtime:
            continue
        if not close_evidence(text, kid):
            mention_only.append(p)
            continue
        if shows_pass(p, kid):
            qualifying.append(p)
    if len(qualifying) == 1:
        try:
            rel = str(qualifying[0].relative_to(ROOT))
        except ValueError:
            rel = str(qualifying[0])
        return "FLIP-ELIGIBLE", rel
    if len(qualifying) > 1:
        listing = "; ".join(str(p) for p in qualifying)
        return ("AMBIGUOUS",
                f"{len(qualifying)} post-shim receipts carry close evidence "
                f"for {kid} — pass --witness {kid}=<path> to disambiguate: {listing}")
    if mention_only:
        return ("FLIP-PENDING-WITNESS", (
            f"{len(mention_only)} post-shim receipt(s) mention {kid} but carry "
            f"no close evidence (mention-only class refused): "
            + ", ".join(str(p) for p in mention_only[:3])))
    if candidates:
        return "FLIP-PENDING-WITNESS", (
            "no post-shim receipt newer than shim mtime "
            f"({time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(shim_mtime))})")
    return "FLIP-PENDING-WITNESS", "no witness artifact found (probe cannot run / no env)"


def flip_line(line, witness_path):
    """OPEN -> CLOSED-SIMULATED in one table row, preserving the rest."""
    parts = split_row(line)
    parts[5] = (
        f"CLOSED-SIMULATED (shim landed, witness receipt at {witness_path})"
    )
    return "| " + " | ".join(parts) + " |"



def mirror_status_cell(line):
    """Status is the LAST cell of a mirror row."""
    parts = split_row(line)
    return parts[-1] if parts else ""


def canonical_status_token(status_cell):
    """Leading status word of a canonical status cell (e.g. CLOSED-SIMULATED)."""
    m = re.match(r"[A-Za-z-]+", status_cell.strip())
    return m.group(0) if m else ""


def sync_mirror(mirror_path, register, apply=False):
    """Mirror sync (2026-10-21, KD-MIRROR lane): the v26.10.20 mirror's rows
    drift from the canonical v26.10.14 register when kd_flip flips only the
    canonical. --sync-mirror updates each shared row's STATUS CELL ONLY to the
    canonical status token + " (see canonical)" — never the row text. Rows
    whose canonical status token cannot be located are REFUSED loudly (typed
    MIRROR-STATUS-UNLOCATABLE), never silently skipped. Idempotent: a cell
    already carrying the canonical token (+ optional note) is left untouched.
    """
    lines = mirror_path.read_text(errors="replace").splitlines()
    updated, refused, unchanged = [], [], []
    out = list(lines)
    for i, line in enumerate(lines):
        m = KD_ROW_RE.match(line)
        if not m:
            continue
        kid = m.group(1)
        if kid not in register:
            continue
        canon = canonical_status_token(register[kid]["status"])
        if not canon:
            refused.append(
                (kid, "MIRROR-STATUS-UNLOCATABLE: canonical row has no "
                      "status token (empty/blank status cell in "
                      f"{KD_PATH.relative_to(ROOT)})"))
            continue
        cur = mirror_status_cell(line)
        cur_tok = canonical_status_token(cur)
        if cur_tok == canon:
            unchanged.append(kid)
            continue
        parts = split_row(line)
        parts[-1] = f"{canon} (see canonical)"
        out[i] = "| " + " | ".join(parts) + " |"
        updated.append((kid, cur or "<empty>", f"{canon} (see canonical)"))
    print(f"mirror sync: {mirror_path}")
    print(f"  updated: {len(updated)}")
    for kid, before, after in updated:
        print(f"    {kid}: '{before}' -> '{after}'")
    print(f"  unchanged (already mirroring canonical): {len(unchanged)} "
          f"-> {', '.join(unchanged) if unchanged else '-'}")
    if refused:
        for kid, why in refused:
            print(f"    REFUSED {kid}: {why}", file=sys.stderr)
        print(f"  REFUSED: {len(refused)} row(s) with unlocatable canonical "
              "status; those rows were NOT touched")
    if apply and updated:
        mirror_path.write_text("\n".join(out) + "\n")
        print(f"  WROTE {len(updated)} status cell(s) to {mirror_path}")
    elif apply:
        print("  nothing to write; mirror unchanged")
    return 1 if refused else 0


def self_test():
    """Non-vacuity court for witness identity pinning (BK-55).

    Builds a temp fixture: an OPEN KD-999 register row, a shim file, and two
    candidate receipts — one mention-only, one with close evidence. Asserts
    the picker refuses the mention-only receipt, demands disambiguation on
    two qualifying receipts, honors explicit --witness, and enforces the
    mtime gate. Exit 0 = pass; exit 1 = VACUOUS.
    """
    import shutil
    import tempfile
    global ROOT, JIRA, KD_PATH, RESULTS_DIR
    tmp = Path(tempfile.mkdtemp(prefix="kdflip-selftest-"))
    old = (ROOT, JIRA, KD_PATH, RESULTS_DIR)
    try:
        ROOT = tmp; JIRA = tmp / "docs/jira"; KD_PATH = JIRA / "KNOWN_DIVERGENCES.md"
        RESULTS_DIR = JIRA / "sdk-results"
        JIRA.mkdir(parents=True); RESULTS_DIR.mkdir()
        KD_PATH.write_text(
            "| KD-999 | d | e.md | OPEN | open | note |\n")
        shim = tmp / "shim.ex"; shim.write_text("# KD-COVERS: KD-999\n")
        past = time.time() - 3600
        import os
        os.utime(shim, (past, past))
        receipt_dir = JIRA / "v1" / "receipts"; receipt_dir.mkdir(parents=True)
        mention = receipt_dir / "mint.md"
        mention.write_text(
            "Status sweep referencing KD-999 among many ids.\nNo close marker here.\n")
        close = receipt_dir / "fix.md"
        close.write_text(
            "KD-999 fixed on the real route.\nDisposition: CLOSED-WITH-EVIDENCE\n"
            "```\nKD-999 probe PASS\n```\nStanding: ALIVE\n")
        # order the mtimes so both postdate the shim
        for f in (mention, close):
            os.utime(f, (past + 60, past + 60))

        def W(kid, explicit=None):
            return witness(kid, "e.md", shim.stat().st_mtime, explicit=explicit)

        fails = []
        # 1b. close keyword ONLY inside a command-output fence -> refused
        # (the BK-52 mint-receipt class: scan output mentioning the id)
        fenceonly = receipt_dir / "fenceonly.md"
        fenceonly.write_text(
            "Some mint receipt.\n```\n$ python3 scripts/kd_flip.py\n"
            "FLIP-PENDING-WITNESS: 1  # KD-999 ... name a KD-COVERS shim\n```\n")
        os.utime(fenceonly, (past + 90, past + 90))
        v, why = W("KD-999", explicit=str(fenceonly))
        if v != "FLIP-PENDING-WITNESS":
            fails.append(f"fence-only: got {v}: {why}")
        else:
            print("  PASS fence-only close keyword refused (mention-only class)")
        # 1. mention-only alone -> refused (PENDING), never eligible
        os.utime(close, (0, 0))  # hide the qualifying receipt via mtime gate
        os.utime(close, (past - 10, past - 10))
        v, why = W("KD-999")
        if v != "FLIP-PENDING-WITNESS" or "mention-only" not in why:
            fails.append(f"mention-only: got {v}: {why}")
        else:
            print("  PASS mention-only receipt refused (no close evidence)")
        # 2. exactly one qualifying receipt -> eligible, names the fix receipt
        os.utime(close, (past + 60, past + 60))
        v, why = W("KD-999")
        if v != "FLIP-ELIGIBLE" or "fix.md" not in why:
            fails.append(f"single qualifying: got {v}: {why}")
        else:
            print("  PASS close-evidence receipt selected")
        # 3. two qualifying -> AMBIGUOUS, never auto-picked
        dup = receipt_dir / "fix2.md"
        dup.write_text(close.read_text())
        os.utime(dup, (past + 120, past + 120))
        v, why = W("KD-999")
        if v != "AMBIGUOUS" or "fix.md" not in why or "fix2.md" not in why:
            fails.append(f"ambiguous: got {v}: {why}")
        else:
            print("  PASS two qualifying receipts -> AMBIGUOUS (refused)")
        # 4. explicit --witness on the close receipt -> eligible
        v, why = W("KD-999", explicit=str(close))
        if v != "FLIP-ELIGIBLE":
            fails.append(f"explicit witness: got {v}: {why}")
        else:
            print("  PASS explicit --witness honored")
        # 5. explicit --witness on the mention-only receipt -> refused
        v, why = W("KD-999", explicit=str(mention))
        if v != "FLIP-PENDING-WITNESS":
            fails.append(f"explicit mention-only: got {v}: {why}")
        else:
            print("  PASS explicit --witness on mention-only refused")
        # 6. mtime gate: witness older than shim -> pending even with evidence
        os.utime(close, (past - 10, past - 10))
        v, why = W("KD-999", explicit=str(close))
        if v != "FLIP-PENDING-WITNESS":
            fails.append(f"mtime gate: got {v}: {why}")
        else:
            print("  PASS mtime gate enforced for explicit witness")
        # 7/8/9. bold-markdown standing variants (KD-FLIPFIX, 2026-10-22):
        # the old regex `[Ss]tanding:\s*ALIVE\b` rejected `Standing: **ALIVE**`
        # and `**Standing:** ALIVE` on formatting alone.
        bold1 = receipt_dir / "bold1.md"
        bold1.write_text("KD-999 fix landed.\nDisposition: CLOSED-WITH-EVIDENCE\n"
                         "Standing: **ALIVE**\n")
        bold2 = receipt_dir / "bold2.md"
        bold2.write_text("KD-999 fix landed.\nDisposition: CLOSED-WITH-EVIDENCE\n"
                         "**Standing:** ALIVE\n")
        for name, p in (("inline-bold", bold1), ("label-bold", bold2)):
            if not shows_pass(p, "KD-999"):
                fails.append(f"bold standing {name}: shows_pass=False "
                             "(old-regex regression)")
            else:
                print(f"  PASS bold standing accepted ({name}: "
                      "no plain 'PASS' token, standing-only)")
        plain_neg = receipt_dir / "neg.md"
        plain_neg.write_text("KD-999 attempted.\nStanding: **SUSPECT**\n")
        if shows_pass(plain_neg, "KD-999"):
            fails.append("bold standing: SUSPECT accepted as pass")
        else:
            print("  PASS bold non-ALIVE standing still refused")
        if fails:
            for f in fails:
                print(f"  FAIL {f}", file=sys.stderr)
            print("KD-FLIP SELF-TEST: VACUOUS", file=sys.stderr)
            sys.exit(1)
        print("KD-FLIP self-test: witness pinning + bold-standing non-vacuous "
              "(10 assertions)")
    finally:
        ROOT, JIRA, KD_PATH, RESULTS_DIR = old
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if "--self-test" in sys.argv[1:]:
        self_test()
        sys.exit(0)
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="flip FLIP-ELIGIBLE OPEN rows to CLOSED-SIMULATED")
    ap.add_argument("--only", default=None, metavar="KD-nn[,KD-nn...]",
                    help="with --apply: flip ONLY the named rows (they must "
                         "all be FLIP-ELIGIBLE, else refused). Without "
                         "--only, a bare --apply auto-applies only when "
                         "exactly ONE row is eligible; with >1 eligible it "
                         "prints the would-flip list and exits 2 requiring "
                         "explicit selection (KD-FLIPFIX, 2026-10-22)")
    ap.add_argument("--witness", action="append", default=[], metavar="KD-ID=PATH",
                    help="explicit witness receipt for a row (repeatable); "
                         "explicit beats inferred. The path must postdate the "
                         "shim mtime and carry close evidence for the id")
    ap.add_argument("--scan-root", action="append", default=None,
                    help="extra scan root (repeatable); default lib/ + workspace/lib")
    ap.add_argument("--sync-mirror", metavar="PATH", default=None,
                    help="sync a mirror register (e.g. docs/jira/v26.10.20/"
                         "KNOWN_DIVERGENCES.md) status cells to the canonical "
                         "register; combinable with --apply (flip first, then sync)")
    args = ap.parse_args()

    explicit_witnesses = {}
    for spec in (args.witness or []):
        if "=" not in spec:
            print(f"REFUSED: --witness expects KD-ID=PATH, got: {spec}", file=sys.stderr)
            sys.exit(1)
        kid, _, path = spec.partition("=")
        explicit_witnesses[kid.strip()] = path.strip()

    scan_roots = list(DEFAULT_SCAN_ROOTS)
    for r in (args.scan_root or []):
        scan_roots.append(Path(r).resolve())

    register = load_register()
    covers = scan_covers(scan_roots)

    unknown = sorted(k for k in covers if k not in register)
    eligible, pending, ambiguous = [], [], []
    for kid in sorted(covers):
        if kid in unknown:
            continue
        row = register[kid]
        if row["status"] != "OPEN":
            continue
        shim_mtime = max(covers[kid].values())
        verdict, why = witness(kid, row["evidence"], shim_mtime,
                               explicit=explicit_witnesses.get(kid))
        if verdict == "FLIP-ELIGIBLE":
            eligible.append((kid, why))
        elif verdict == "AMBIGUOUS":
            ambiguous.append((kid, why))
        else:
            pending.append((kid, why))

    print(f"KD-COVERS covers-map: {len(covers)} KD ids "
          f"from {sum(len(v) for v in covers.values())} files")
    def display(p):
        try:
            return str(p.relative_to(ROOT))
        except ValueError:
            return str(p)

    for kid in sorted(covers):
        files = ", ".join(display(p) for p in covers[kid])
        status = register[kid]["status"] if kid in register else "MISSING-FROM-REGISTER"
        print(f"  {kid}: [{status}] {files}")

    print(f"\nFLIP-ELIGIBLE: {len(eligible)}")
    for kid, why in eligible:
        print(f"  {kid}: witness {why}")
    print(f"FLIP-PENDING-WITNESS: {len(pending)}")
    for kid, why in pending:
        print(f"  {kid}: {why}")
    if ambiguous:
        print(f"WITNESS-AMBIGUOUS: {len(ambiguous)} — flip refused, disambiguate "
              "with --witness KD-ID=PATH:")
        for kid, why in ambiguous:
            print(f"  {kid}: {why}")

    if unknown:
        print(f"\nUNKNOWN KD IDS in KD-COVERS tokens (register sync required): "
              f"{', '.join(unknown)}")

    # Composition order (fix 2026-10-21, vacuous-gate defect): --apply runs
    # FIRST, then --sync-mirror. The previous structure exited inside the
    # --sync-mirror branch before the --apply block, so `--apply --sync-mirror`
    # silently skipped the flip (a gate that accepted the invocation while
    # doing only half the work). Flags compose in this documented order or the
    # run refuses loudly -- never a silent skip of either action.
    if args.apply:
        if unknown:
            print("\n--apply REFUSED: unknown KD ids present; sync the register first.")
            sys.exit(1)
        eligible_ids = {k for k, _ in eligible}
        if args.only is not None:
            only_ids = {t.strip() for t in args.only.split(",") if t.strip()}
            missing = only_ids - eligible_ids
            if missing:
                print(f"\n--only REFUSED: requested row(s) not FLIP-ELIGIBLE: "
                      f"{', '.join(sorted(missing))}")
                sys.exit(1)
            target_ids = only_ids & eligible_ids
        else:
            if len(eligible_ids) > 1:
                print(f"\n--apply REFUSED (exit 2): {len(eligible_ids)} rows are "
                      "FLIP-ELIGIBLE; name them explicitly to avoid side-effect "
                      "flips:\n  would-flip: "
                      + ", ".join(sorted(eligible_ids))
                      + "\n  re-run with --only KD-nn[,KD-nn...]")
                sys.exit(2)
            target_ids = eligible_ids
        # KD-173C scope fix (2026-10-22): the witness-ambiguity refusal is
        # scoped to the rows being flipped (--only targets, or all eligible
        # rows under a bare --apply). An UNRELATED row's ambiguity (e.g. a
        # concurrent lane's in-flight witness) must not veto a named-row flip
        # that carries its own explicit --witness. Auto-picking is still
        # refused everywhere (BK-55 preserved: an ambiguous TARGET row is
        # still refused unless its own --witness disambiguates it).
        ambiguous_targets = [a for a in ambiguous if a[0] in target_ids]
        if ambiguous_targets:
            print("\n--apply REFUSED: witness identity ambiguous for "
                  f"{len(ambiguous_targets)} target row(s); pass --witness "
                  "KD-ID=PATH. Never auto-picking (BK-55).")
            sys.exit(1)
        if not target_ids:
            print("\n--apply: nothing FLIP-ELIGIBLE; register unchanged.")
        else:
            lines = KD_PATH.read_text(errors="replace").splitlines()
            flipped = 0
            for kid in sorted(target_ids):
                ln = register[kid]["line_no"] - 1
                _, why = next(e for e in eligible if e[0] == kid)
                lines[ln] = flip_line(lines[ln], why)
                flipped += 1
            KD_PATH.write_text("\n".join(lines) + "\n")
            print(f"\n--apply: flipped {flipped} row(s) OPEN -> CLOSED-SIMULATED: "
                  f"{', '.join(sorted(target_ids))}")
            # refresh the register snapshot so sync-mirror sees the flips
            register = load_register()

    if args.sync_mirror:
        rc = sync_mirror(Path(args.sync_mirror).resolve(), register,
                         apply=args.apply)
        sys.exit(rc if rc else (1 if unknown else 0))

    sys.exit(1 if unknown else 0)


if __name__ == "__main__":
    main()
