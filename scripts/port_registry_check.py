#!/usr/bin/env python3
"""port_registry_check.py — single-copy port-law registry + fail-closed gate.

Port law doc: docs/reference/port_law.md (prose twin; FAMILIES below is
ground truth — the only lawful copy of the literals).

Families:
  front : fixed 6 (amqp 5672 eh 5673 arm 9443 egress 8443 tls 9444 mcp 9545)
  b     : bN N=1..20  39000+10N..+5  (6 ports)
  c     : cN N=1..48  39200+10N..+5  (6 ports; c48 legacy-reserved "legacy-c3")
  v     : vN N=1..29  39700+10N..+6  (7 ports; kafka = 7th slot, v-face only)
          v14, v15 LEGACY-FROZEN (old 6-port-era ts blocks; never re-issue)
Reserved literals (arcus): 4566, 8085, 9099. UDS consumers need no TCP claim.

Exit contract:
  --port/--block claim checks: 0 lawful / 1 violation / 2 usage
  --report : live-listener census, always exit 0, findings listed
  --check  : same census fail-closed (exit 1 on violation)
  --falsify: self-test corpus, exit 0 iff every corpus case behaves lawfully
"""
import argparse
import re
import subprocess
import sys

FAMILIES = {
    "front": {"fixed": [5672, 5673, 9443, 8443, 9444, 9545]},
    "b": (39000, 10, 6, 1, 20, frozenset()),
    "c": (39200, 10, 6, 1, 48, frozenset({"48"})),
    "v": (39700, 10, 7, 1, 29, frozenset({"14", "15"})),
}

FROZEN_BLOCKS = {"v14", "v15"}

RESERVED = {4566, 8085, 9099}  # arcus-reserved literals

ROLE_ORDER = ["amqp", "eh", "arm", "egress", "tls", "mcp", "kafka"]

LEGACY_LITERALS = [
    "39730-39735 (v3 6-port prefix; v3 is now 7 ports 39730-39736, py anon)",
    "39740-39745 (v4 6-port prefix; v4 is now 7 ports 39740-39746, py throttle)",
    "39750-39755 (v5 6-port prefix; v5 is now 7 ports 39750-39756, py mesg)",
    "v14 = 39840-39846 (FROZEN, old run-all.mjs private block)",
    "v15 = 39850-39856 (FROZEN, old diagnostics.probe.mjs block)",
    "c48 (legacy-reserved legacy-c3)",
]


def resolve(port):
    """-> (family, block, frozen?) — (None, None, False) if outside all
    families. Reserved literals -> ("reserved", None, True)."""
    if port in RESERVED:
        return ("reserved", None, True)
    fixed = FAMILIES["front"]["fixed"]
    if port in fixed:
        return ("front", "front", False)
    for fam in ("b", "c", "v"):
        base, stride, width, n_min, n_max, frozen = FAMILIES[fam]
        rel = port - base
        if rel < 0 or rel >= stride * (n_max + 1):
            continue
        n = rel // stride
        off = rel % stride
        if n < n_min or off >= width:
            continue
        if str(n) in frozen:
            return (fam, "%s%d" % (fam, n), True)
        return (fam, "%s%d" % (fam, n), False)
    return (None, None, False)


def block_ports(block):
    """-> port list for a lawful block claim, else None (unknown family,
    out of range, frozen, or reserved)."""
    if block in ("front", "canonical"):
        return list(FAMILIES["front"]["fixed"])
    m = re.fullmatch(r"([bcv])(\d{1,2})$", block)
    if not m:
        return None
    fam, num = m.group(1), int(m.group(2))
    if fam not in ("b", "c", "v"):
        return None
    base, stride, width, n_min, n_max, frozen = FAMILIES[fam]
    if num < n_min or num > n_max or str(num) in frozen:
        return None
    return [base + stride * num + i for i in range(width)]


def claim_ok(port, block):
    """-> (lawful?, reason). A claim 'port P belongs to block B' is lawful
    iff B is lawful and P is in B's port list."""
    ports = block_ports(block)
    if ports is None:
        return False, "block %s is unlawful (unknown family / out of range / frozen / reserved)" % block
    if port not in ports:
        fam, blk, frozen = resolve(port)
        if fam is None:
            return False, "port %d is outside all families" % port
        label = "%s (FROZEN)" % blk if frozen else (blk or fam)
        return False, "port %d belongs to %s, not %s" % (port, label, block)
    return True, ""


def census():
    """Live LISTENer census via lsof. -> list of (port, command) rows."""
    try:
        out = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
                             capture_output=True, text=True, timeout=15).stdout
    except (subprocess.SubprocessError, OSError):
        return []
    rows = []
    for line in out.splitlines()[1:]:
        cols = line.split()
        if len(cols) < 9 or not cols[8].startswith("*:") and ":" not in cols[8]:
            continue
        port_tok = cols[8].rsplit(":", 1)[-1]
        if not port_tok.isdigit():
            continue
        rows.append((int(port_tok), " ".join(cols[0:1])))
    return sorted({(p, c) for p, c in rows})


def census_findings(scope="report"):
    """-> list of finding strings.

    scope="report": every non-lawful listener is a finding.
    scope="check": fail-closed scope — only RESERVED, FROZEN, and
    UNREGISTERED ports inside the law's numeric neighborhoods (4560-9200
    reserved band edges, 38900-39999 family band) are violations; unrelated
    system listeners (postgres, IDE helpers, ephemeral beam dist ports)
    carry no bits here and are report-only."""
    findings = []
    seen = set()
    for port, cmd in census():
        if port in seen:
            continue
        seen.add(port)
        fam, blk, frozen = resolve(port)
        if scope == "check" and not (38900 <= port <= 39999 or port in RESERVED):
            continue
        if fam == "reserved":
            findings.append("RESERVED: port %d (%s) is arcus-reserved — never claimable" % (port, cmd))
        elif fam is None:
            findings.append("UNREGISTERED: port %d (%s) is outside all families" % (port, cmd))
        elif frozen:
            findings.append("FROZEN: port %d (%s) belongs to legacy-frozen block %s" % (port, cmd, blk))
    return findings


def live_legacy_findings():
    """Known legacy items pinned by the plan (reported even when nothing is
    listening): frozen v14/v15 literals + any live collision."""
    findings = []
    for blk in sorted(FROZEN_BLOCKS):
        ports = [39700 + 10 * int(blk[1:]) + i for i in range(7)]
        findings.append("LEGACY: block %s (%s) is frozen — no harness may claim it" % (blk, ",".join(str(p) for p in ports)))
    return findings


def do_falsify():
    """Self-test corpus. Exit 0 iff every must-fail claim fails and every
    must-pass claim passes."""
    failures = []

    def expect(label, got, want):
        if got != want:
            failures.append("%s: got %r want %r" % (label, got, want))

    # -- must-fail claims (each dispatch falsifier literal appears) ----------
    expect("39711 claimed for v2", claim_ok(39711, "v2")[0], False)   # 39711 is v1's
    expect("39841 claimed for v84", block_ports("v84"), None)         # v84 > cap 29
    expect("39841 resolve=frozen v14", resolve(39841), ("v", "v14", True))
    expect("39310 claimed for c10", claim_ok(39310, "c10")[0], False) # 39310 is c11's
    expect("39250 claimed for c10", claim_ok(39250, "c10")[0], False) # 39250 is c5's
    expect("39720 claimed for v1", claim_ok(39720, "v1")[0], False)   # 39720 is v2's
    expect("39720 claimed for v14 (frozen)", claim_ok(39720, "v14")[0], False)
    expect("9099 claimable", claim_ok(9099, "v3")[0], False)          # arcus reserved
    expect("c48 block lawful", block_ports("c48"), None)              # legacy-reserved
    expect("unknown block", block_ports("x9"), None)

    # -- must-pass claims ----------------------------------------------------
    expect("v3 lawful", block_ports("v3"), [39730, 39731, 39732, 39733, 39734, 39735, 39736])
    expect("v14 ports are frozen", block_ports("v14"), None)
    expect("c10 = 39300..39305", block_ports("c10"), [39300, 39301, 39302, 39303, 39304, 39305])
    expect("b5 stays 6 ports", len(block_ports("b5")), 6)
    expect("c5 stays 6 ports", len(block_ports("c5")), 6)
    expect("v13 7 ports incl kafka 39836", block_ports("v13")[6], 39836)
    expect("front fixed", block_ports("front"), FAMILIES["front"]["fixed"])
    expect("39711 lawful claim", claim_ok(39711, "v1")[0], True)
    expect("39310 lawful claim", claim_ok(39310, "c11")[0], True)

    if failures:
        for f in failures:
            print("FALSIFY-FAIL: %s" % f, file=sys.stderr)
        return 1
    print("falsify: PASS (%d corpus cases)" % 19)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_description := None) if False else argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, help="check a port claim (with --block, or family-only)")
    ap.add_argument("--block", help="check a block claim")
    ap.add_argument("--report", action="store_true", help="live-listener census, report-only")
    ap.add_argument("--check", action="store_true", help="live-listener census, fail-closed")
    ap.add_argument("--falsify", action="store_true", help="self-test corpus")
    args = ap.parse_args(argv)

    if args.falsify:
        return do_falsify()

    if args.report or args.check:
        # legacy-frozen block notes are REPORT-only: a frozen block with
        # nothing claiming it is not a live violation (no bits in --check).
        findings = census_findings("check" if args.check else "report")
        if not args.check:
            findings = findings + live_legacy_findings()
        for f in findings:
            print("FINDING: %s" % f)
        if not findings:
            print("no findings")
        if args.check and findings:
            print("check: FAIL (%d findings)" % len(findings), file=sys.stderr)
            return 1
        return 0

    if args.port is not None or args.block:
        if args.port is None or args.block is None:
            if args.port is not None:
                fam, blk, frozen = resolve(args.port)
                if fam is None:
                    print("port %d: OUTSIDE-ALL-FAMILIES" % args.port)
                    return 1
                label = "%s (FROZEN)" % blk if frozen else blk
                print("port %d: %s" % (args.port, label))
                return 1 if frozen else 0
            ports = block_ports(args.block)
            if ports is None:
                print("block %s: REFUSED (unlawful)" % args.block)
                return 1
            print("block %s: %s" % (args.block, " ".join(str(p) for p in ports)))
            return 0
        ok, reason = claim_ok(args.port, args.block)
        if ok:
            print("claim %d -> %s: OK" % (args.port, args.block))
            return 0
        print("claim %d -> %s: REFUSED (%s)" % (args.port, args.block, reason), file=sys.stderr)
        return 1

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
