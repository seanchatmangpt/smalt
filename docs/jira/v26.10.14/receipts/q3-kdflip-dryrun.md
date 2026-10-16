# Q-3: kd_flip.py pre-flight dry run (F-3)

Lane: Q-3, 2026-10-15. Tool: `scripts/kd_flip.py` (247 lines). Dry run, no
`--apply`, no commits.

## Live run + exit

```
$ python3 scripts/kd_flip.py
KD-COVERS covers-map: 6 KD ids from 7 files
  KD-15: [CLOSED-with-receipt ...] lib/smalt/auth/bearer.ex, lib/smalt/egress_router.ex
  KD-18: [CLOSED-with-receipt ...] lib/smalt/messaging/amqp/connection.ex
  KD-19: [CLOSED-with-receipt ...] lib/smalt/messaging/amqp/connection.ex
  KD-20: [CLOSED-with-receipt ...] lib/smalt/messaging/amqp/connection.ex
  KD-21: [CLOSED-SIMULATED ...] lib/smalt/messaging/amqp/connection.ex
  KD-49: [CLOSED-SIMULATED ...] lib/smalt/messaging/amqp/connection.ex

FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
EXIT=0
```

## (1) Token parse audit

All 7 `KD-COVERS` tokens across the scan roots (`lib/` + `workspace/lib`;
workspace/lib contributed 0 files) parse cleanly, including both stress forms:

| token site | ids | parses |
|---|---|---|
| `lib/smalt/egress_router.ex:48` | KD-15 | yes |
| `lib/smalt/auth/bearer.ex:505` | KD-15 | yes |
| `lib/smalt/messaging/amqp/connection.ex:266` | KD-21 (mid-comment: `# KD-21 shim (KD-COVERS: KD-21): ...`) | yes |
| `lib/smalt/messaging/amqp/connection.ex:474` | KD-49 | yes |
| `lib/smalt/messaging/amqp/connection.ex:937` | KD-19 (trailing em-dash prose) | yes |
| `lib/smalt/messaging/amqp/connection.ex:1126` | KD-18,KD-20 (comma form + trailing prose) | yes — splits into two ids |
| `lib/smalt/messaging/amqp/connection.ex:1155` | KD-18 | yes |

Coverage deltas vs the task brief:
- bearer.ex / egress_router.ex carry only `KD-15` — no separate S-3 tokens.
- No separate S-4 tokens in egress_router.ex.
- `blob_storage.ex` contains zero KD-COVERS tokens (verified: zero KD- mentions
  in the file). The X-1/KD-52 fix landed WITHOUT a token, so the covers-map has
  no KD-52 entry.

## (2) Unhandled-exception audit (F-8 class)

F-8's flagged class was `.get()`-on-str at sdk_coverage.py:212.
`kd_flip.py` contains zero `.get(` calls (grep: no matches). Closest analogs:

- `entry[p]` (line 104): dict keyed by `pathlib.Path` (hashable); the
  `p not in entry or` guard short-circuits. Safe.
- `parts[5]` (load_register line 74): guarded by `len(parts) < 6: continue`;
  `flip_line` only runs on registered rows. Safe.
- `p.stat()` (line 103): unguarded TOCTOU — a file deleted mid-scan raises
  FileNotFoundError. Latent, not exercised this run (exit 0, no errors).
  Not the F-8 class.

## (3) mtime witness logic — verified by scratch simulation

The live run evaluated no witness (no covered row is OPEN), so the logic was
verified in a /tmp scratch tree with a real KD-21 OPEN row, real file mtimes,
real receipts — no mocks:

- shim `touch`ed newer than receipt → `FLIP-PENDING-WITNESS: no post-shim
  receipt newer than shim mtime (2026-10-15T20:36:05)` — correct.
- receipt `touch`ed newer than shim → `FLIP-ELIGIBLE: 1, KD-21: witness
  docs/jira/v26.10.14/receipts/w.md` — correct; newest-passing-witness-wins.

## (4) exit-1 missing-register gate — verified in scratch

Scratch tree with `# KD-COVERS: KD-9999` absent from its register:

```
UNKNOWN KD IDS in KD-COVERS tokens (register sync required): KD-9999
EXIT=1
```

Exit 1 fires, and `--apply` additionally refuses while unknowns are present
(kd_flip.py:226-227). Gate works. Scratch dirs (/tmp/kdflip-gate,
/tmp/kdflip-g2) removed.

## Flip forecast — what F-3's --apply would flip right now

**Nothing: 0 rows.** The tool only considers rows with status exactly `OPEN`
(kd_flip.py:194). On-disk register statuses:

| KD | register status (KNOWN_DIVERGENCES.md) | covered by token | --apply would flip? |
|---|---|---|---|
| KD-15 | CLOSED-with-receipt (receipts/s3-kv-challenge.md) | yes | no — not OPEN |
| KD-18 | CLOSED-with-receipt (receipts/s2-eh-shims.md, court NON-VACUOUS) | yes | no |
| KD-19 | CLOSED-with-receipt (receipts/s2-eh-shims.md) | yes | no |
| KD-20 | CLOSED-with-receipt (receipts/s2-eh-shims.md) | yes | no |
| KD-21 | CLOSED-SIMULATED (row 37) | yes | no — already flipped |
| KD-49 | CLOSED-SIMULATED (row 66) | yes | no — already flipped |
| KD-52 | CLOSED (row 68, receipts/x1-blocklist-fix.md) | NO token | no — outside tool surface |

The register has already advanced past the tool: KD-15/18/19/20 closed by
hand with receipts, KD-21/49 already CLOSED-SIMULATED. KD-52 closed without a
shim token. For a future `--apply` to have work, a row must be OPEN + covered
+ newer PASS receipt; the only OPEN register row (KD-47, SB scheduleMessage)
has no shim token, so the tool ignores it.

## Receipt

- Subject: /Users/sac/smalt @ main 518b31a (dirty working tree; lib/ as on disk
  2026-10-15)
- Commands: `python3 scripts/kd_flip.py` (exit 0); two /tmp scratch
  simulations; grep token audit
- Verification: Chicago — real script, real register, real mtimes; no mocks
- Falsifiers run: exit-1 gate (fired, witnessed); mtime logic both directions
  (pending and eligible both witnessed)
- Standing: dry-run ALIVE; F-3 `--apply` forecast = no-op
- BLOCKED / UNSUPPORTED / REFUSED: none
