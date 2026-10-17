#!/usr/bin/env python3
"""Mint a chatman/release-receipt/v1 JSON receipt (no deps, stdlib only).

Shape canonicalized from affidavit release v26.9.25 receipts/brce-ledger.json.
Executed for real at wrap, post court-x2. A DRAFT mint (placeholder SHA or
DRAFT-STANDING) is clearly marked and must never be cited as court evidence.

Usage:
  scripts/mint_release_receipt.py \
    --sha <git sha> \
    --rules CHAIN_INTEGRITY,ZERO_UNRECEIPTED_ACTUATION,... \
    --refusals <path to refusals json, [] or list of refusal records> \
    --court-log <path to court x2 log> \
    [--release v26.10.16] [--repo smalt] [--ref main] \
    [--supersedes-sha <sha>] [--supersedes-standing BLOCKED] \
    [--supersedes-note <text>] [--standing DRAFT-STANDING: PENDING-COURT] \
    [-o <output path>]   # default: stdout
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = "chatman/release-receipt/v1"

DEFAULT_RULES = [
    "CHAIN_INTEGRITY",
    "ZERO_UNRECEIPTED_ACTUATION",
    "DO_REQUIRES_AUTHORITY",
    "CONSTRUCT_REQUIRES_ADMISSION",
    "RECEIPT_DIGEST_VALID",
    "AT_MOST_ONCE_CONSEQUENCE",
    "CRASH_WINDOW_RECONCILED",
    "UNKNOWN_NOT_PROMOTED",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_refusals(path: str) -> list:
    p = Path(path)
    if not p.exists():
        sys.exit(f"refusals path not found: {p}")
    data = json.loads(p.read_text())
    if isinstance(data, dict):
        data = data.get("refusals", [])
    if not isinstance(data, list):
        sys.exit(f"refusals must be a JSON list (or object with 'refusals'): {p}")
    return data


def build(args) -> dict:
    rules = [r.strip() for r in args.rules.split(",") if r.strip()] or DEFAULT_RULES
    refusals = load_refusals(args.refusals)
    court_log = Path(args.court_log)
    if not court_log.exists():
        sys.exit(f"court-log path not found: {court_log}")

    is_draft = args.sha.startswith("PLACEHOLDER") or args.standing.startswith("DRAFT")

    receipt = {
        "schema": SCHEMA,
        "release": args.release,
        "name": args.name,
        "repo": args.repo,
        "standing": args.standing,
        "type": args.type,
        "subject": {
            "repo": args.repo,
            "sha": args.sha,
            "ref": args.ref,
        },
        "court": {
            "standing": args.court_standing,
            "rules": rules,
            "refusals": refusals,
        },
        "execution": {
            "command": args.command,
            "toolchain": args.toolchain,
            "exit_code": args.exit_code,
            "output_sha256": sha256_file(court_log),
            "court_log": str(court_log),
        },
        "anti_vacuity": {
            "mutants": [
                {"rule": r, "mutation": args.mutant_note, "standing": "PENDING", "killed": None}
                for r in rules
            ],
            "killed": 0,
            "total": len(rules),
            "note": "populated at real wrap mint from the court's mutant-kill report",
        },
        "authority": "NONE (court is receipt-level evidence; Verification does not imply DO)",
        "evidence_ceiling": "LOCAL_RUN",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
    }

    if args.supersedes_sha or args.supersedes_note:
        receipt["supersedes"] = {
            "standing": args.supersedes_standing,
            "type": args.supersedes_type,
            "subject_sha": args.supersedes_sha,
            "note": args.supersedes_note,
        }

    if is_draft:
        receipt["draft"] = {
            "is_draft": True,
            "reason": "DRAFT-STANDING: PENDING-COURT; placeholder mint, not court evidence",
        }
    return receipt


def main() -> None:
    ap = argparse.ArgumentParser(description="Mint a chatman/release-receipt/v1 JSON receipt")
    ap.add_argument("--sha", required=True)
    ap.add_argument("--rules", default=",".join(DEFAULT_RULES))
    ap.add_argument("--refusals", required=True)
    ap.add_argument("--court-log", required=True)
    ap.add_argument("--release", default="v26.10.16")
    ap.add_argument("--repo", default="smalt")
    ap.add_argument("--ref", default="main")
    ap.add_argument("--name", default="release-receipt")
    ap.add_argument("--type", default="RELEASE_ADMISSION_COURT")
    ap.add_argument("--standing", default="DRAFT-STANDING: PENDING-COURT")
    ap.add_argument("--court-standing", default="PENDING")
    ap.add_argument("--command", default="just court-x2")
    ap.add_argument(
        "--toolchain",
        default="elixir/erlang via mise (see .tool-versions); mix test + court-x2",
    )
    ap.add_argument("--exit-code", type=int, default=-1)
    ap.add_argument("--mutant-note", default="pending real court run")
    ap.add_argument("--supersedes-sha", default="")
    ap.add_argument("--supersedes-standing", default="BLOCKED")
    ap.add_argument("--supersedes-type", default="RED_COURT_X2")
    ap.add_argument("--supersedes-note", default="")
    ap.add_argument("-o", "--out", default="-")
    args = ap.parse_args()

    receipt = build(args)
    text = json.dumps(receipt, indent=2) + "\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        Path(args.out).write_text(text)
        print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
