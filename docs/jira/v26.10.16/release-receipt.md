# Release Receipt (v26.10.16)

- schema: `chatman/release-receipt/v1`
- standing: **DRAFT-STANDING: PENDING-COURT** (placeholder mint; subject SHA pending the real court-x2 run at wrap)
- supersedes: prior red court-x2 attempt at `fd9cfea` (2026-10-16)
- minted by: `scripts/mint_release_receipt.py` (stdlib only)

```json
{
  "schema": "chatman/release-receipt/v1",
  "release": "v26.10.16",
  "name": "release-receipt",
  "repo": "smalt",
  "standing": "DRAFT-STANDING: PENDING-COURT",
  "type": "RELEASE_ADMISSION_COURT",
  "subject": {
    "repo": "smalt",
    "sha": "PLACEHOLDER_SHA_PENDING_COURT_X2",
    "ref": "main"
  },
  "court": {
    "standing": "PENDING",
    "rules": [
      "CHAIN_INTEGRITY",
      "ZERO_UNRECEIPTED_ACTUATION",
      "DO_REQUIRES_AUTHORITY",
      "CONSTRUCT_REQUIRES_ADMISSION",
      "RECEIPT_DIGEST_VALID",
      "AT_MOST_ONCE_CONSEQUENCE",
      "CRASH_WINDOW_RECONCILED",
      "UNKNOWN_NOT_PROMOTED"
    ],
    "refusals": []
  },
  "execution": {
    "command": "just court-x2",
    "toolchain": "elixir/erlang via mise (see .tool-versions); mix test + court-x2",
    "exit_code": -1,
    "output_sha256": "ec6e438447d1e94f843eae709fe1e50a59c3cd334d0836e20937c9c40757e699",
    "court_log": "/tmp/placeholder-court.log"
  },
  "anti_vacuity": {
    "mutants": [
      {
        "rule": "CHAIN_INTEGRITY",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "ZERO_UNRECEIPTED_ACTUATION",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "DO_REQUIRES_AUTHORITY",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "CONSTRUCT_REQUIRES_ADMISSION",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "RECEIPT_DIGEST_VALID",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "AT_MOST_ONCE_CONSEQUENCE",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "CRASH_WINDOW_RECONCILED",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      },
      {
        "rule": "UNKNOWN_NOT_PROMOTED",
        "mutation": "pending real court run",
        "standing": "PENDING",
        "killed": null
      }
    ],
    "killed": 0,
    "total": 8,
    "note": "populated at real wrap mint from the court's mutant-kill report"
  },
  "authority": "NONE (court is receipt-level evidence; Verification does not imply DO)",
  "evidence_ceiling": "LOCAL_RUN",
  "generated_at": "2026-10-16T21:44:09+00:00",
  "supersedes": {
    "standing": "BLOCKED",
    "type": "RED_COURT_X2",
    "subject_sha": "fd9cfea",
    "note": "prior red court-x2 attempt at fd9cfea (2026-10-16); this receipt supersedes it once the green court-x2 run lands"
  },
  "draft": {
    "is_draft": true,
    "reason": "DRAFT-STANDING: PENDING-COURT; placeholder mint, not court evidence"
  }
}
```
