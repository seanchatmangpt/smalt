#!/usr/bin/env python3
"""Mint a v2-conformant (chatman receipt.schema v2) JSON receipt (stdlib only).

WO-25..28 (v26.10.31 inversion): the former chatman/release-receipt/v1 shape is
absorbed/retired — this script now emits receipts validating against
~/.claude/dfcm/receipt.schema.json v2. Field mapping from the retired v1:

  v1 schema:"chatman/release-receipt/v1"      -> dropped ($id of the schema is the version)
  v1 subject.{repo,sha}                       -> identity.{repo,subject_sha}
  v1 subject.ref                              -> identity.subject (with --name)
  v1 execution.{command,exit_code,output_sha256} -> replay.commands[0].{cmd,exit,output_sha256}
  v1 court.{standing,rules,refusals}          -> standing.{value,derived_from} + provider_ext.release_court
  v1 anti_vacuity / supersedes / evidence_ceiling -> provider_ext.release_court / replay_binding / provider_ext
  v1 "DRAFT-STANDING: PENDING-COURT"          -> standing.value UNKNOWN (DRAFT is not a v2 standing)

A DRAFT mint (placeholder SHA or UNKNOWN via --draft) is clearly marked via
provider_ext.release_court.draft and must never be cited as court evidence.

Usage:
  scripts/mint_release_receipt.py \
    --sha <git sha> \
    --rules CHAIN_INTEGRITY,ZERO_UNRECEIPTED_ACTUATION,... \
    --refusals <path to refusals json, [] or list of refusal records> \
    --court-log <path to court x2 log> \
    --base-sha <base git sha> \
    [--release v26.10.31] [--repo /Users/sac/smalt] [--ref main] \
    [--supersedes-sha <sha>] [--supersedes-standing BLOCKED] \
    [--supersedes-note <text>] [--draft] \
    [-o <output path>]   # default: stdout
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_V2_ID = "https://chatmangpt.com/schema/receipt/v2"

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

    is_draft = args.sha.startswith("PLACEHOLDER") or args.draft
    log_sha = sha256_file(court_log)

    receipt = {
        "work_order_id": f"RELEASE:{args.release}",
        "origin_authority": {
            "grant": "NONE",
            "actor": args.actor,
            "ceiling": "SELECT",
            "lease": {
                "id": f"release-lease:{args.release}",
                "epoch": args.generated_at,
            },
        },
        "provider": {
            "name": "smalt-release-court",
            "transport": "local",
            "receipt_protocol": "court-x2",
            "authority_ceiling": "SELECT",
        },
        "provider_execution_id": log_sha[:16],
        "identity": {
            "subject": args.name,
            "repo": args.repo,
            "subject_sha": args.sha,
            "base_sha": args.base_sha,
        },
        "authority": {
            "ceiling": "SELECT",
            "grant": "NONE (court is receipt-level evidence; Verification does not imply DO)",
            "actor": args.actor,
            "lease": {
                "id": f"release-lease:{args.release}",
                "epoch": args.generated_at,
            },
        },
        "consequence": {
            "commits": [args.sha] if not args.sha.startswith("PLACEHOLDER") else [],
            "files_changed": [],
            "remote_effects": [],
        },
        "replay": {
            "commands": [
                {
                    "cmd": args.command,
                    "cwd": args.repo,
                    "exit": args.exit_code,
                    "summary": f"court rules: {','.join(rules)}",
                    "output_sha256": log_sha,
                }
            ],
            "durable_location": str(court_log),
        },
        "standing": {
            "value": "UNKNOWN" if is_draft else args.standing,
            "derived_from": (
                f"DRAFT: placeholder/pending-court mint from {log_sha[:16]}"
                if is_draft
                else f"replay.commands[0] at {args.sha} (court rules: {','.join(rules)})"
            ),
        },
        "provider_ext.release_court": {
                "court_standing": args.court_standing,
                "rules": rules,
                "refusals": refusals,
                "court_log": str(court_log),
                "evidence_ceiling": "LOCAL_RUN",
                "anti_vacuity": {
                    "mutants": [
                        {"rule": r, "mutation": args.mutant_note, "standing": "PENDING", "killed": None}
                        for r in rules
                    ],
                    "killed": 0,
                    "total": len(rules),
                    "note": "populated at real wrap mint from the court's mutant-kill report",
                },
                "draft": {
                    "is_draft": is_draft,
                    "reason": "placeholder/UNKNOWN mint, not court evidence",
                }
                if is_draft
                else None,
                "supersedes": {
                    "standing": args.supersedes_standing,
                    "type": args.supersedes_type,
                    "subject_sha": args.supersedes_sha,
                    "note": args.supersedes_note,
                }
                if (args.supersedes_sha or args.supersedes_note)
                else None,
                "generated_at": args.generated_at,
            }
    }
    return receipt


def main() -> None:
    ap = argparse.ArgumentParser(description="Mint a v2-conformant release receipt")
    ap.add_argument("--sha", required=True)
    ap.add_argument("--base-sha", required=True)
    ap.add_argument("--rules", default=",".join(DEFAULT_RULES))
    ap.add_argument("--refusals", required=True)
    ap.add_argument("--court-log", required=True)
    ap.add_argument("--release", default="v26.10.31")
    ap.add_argument("--repo", default="/Users/sac/smalt")
    ap.add_argument("--ref", default="main")
    ap.add_argument("--name", default="release-receipt")
    ap.add_argument("--actor", default="release-court")
    ap.add_argument(
        "--standing",
        default="PARTIAL_ALIVE",
        help="final standing when NOT a draft (default PARTIAL_ALIVE)",
    )
    ap.add_argument("--draft", action="store_true", help="mint as UNKNOWN standing (draft)")
    ap.add_argument("--court-standing", default="PENDING")
    ap.add_argument("--command", default="just court-x2")
    ap.add_argument(
        "--toolchain-note",
        default="elixir/erlang via asdf (see .tool-versions); mix test + court-x2",
    )
    ap.add_argument("--exit-code", type=int, default=-1)
    ap.add_argument("--mutant-note", default="pending real court run")
    ap.add_argument("--supersedes-sha", default="")
    ap.add_argument("--supersedes-standing", default="BLOCKED")
    ap.add_argument("--supersedes-type", default="RED_COURT_X2")
    ap.add_argument("--supersedes-note", default="")
    ap.add_argument("-o", "--out", default="-")
    args = ap.parse_args()
    args.generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")

    receipt = build(args)
    text = json.dumps(receipt, indent=2) + "\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        Path(args.out).write_text(text)
        print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
