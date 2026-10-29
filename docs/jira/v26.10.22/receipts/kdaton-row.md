# Receipt: KD-ATON — KD-179 register row minted, sas_verifier inet_aton shorthand-loopback observation registered

- **Date**: 2026-10-22
- **Lane**: BK-ATON (registrar; owns the KD-179 row + this receipt only)
- **Standing**: **ALIVE**
- **Context**: solo

## What was minted

KD-179 — surface: `lib/smalt/messaging/amqp/sas_verifier.ex`
`loopback_ipv4?/1` via `:inet.parse_address/1`. Divergence: the AMQP SAS
audience check accepts inet_aton shorthand loopback literals (`0177.0.0.1`,
`0x7f.0.0.1`, `127.1`, `2130706433` — each witnessed `{ok,{127,0,0,1}}`)
that real Azure's dotted-quad URI-authority parsing would 401. Typed
posture: **accepted-because-genuinely-loopback** — every accepted shorthand
parses to `{127,0,0,1}` itself and an address literal never consults DNS,
so no accepted shape can name a foreign host; the KD-173 host-scoping law's
intent holds; classification NON-DEFECT, observation registered not
repaired. Close condition: a strict dotted-quad-only shape guard (4
dot-separated decimal octets, no `0x`/short/integer forms) lands with a
witness receipt IF a divergence is ever witnessed downstream (shorthand
resolving non-loopback, or a real-SDK leg 401ing where smalt accepts).
Also registered on the row: `[::ffff:127.0.0.1]` refuses fail-closed —
safe-direction false negative.

Witnesses: `receipts/bkampv-parse-verify.md` (BK-AMPV, ALIVE, Context:
solo — LEG3 typed verdicts for all four shorthand accepts, evil-host
falsifiers still 401) + `receipts/bkampf1-loopback-parse.md` (BK-AMPF1,
the F1 repair provenance the verify rode on).

## Register edits

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — the canonical KD-179 row was
  found already landed at HEAD by the coordinator mid-session (this lane's
  row text converged with it); the file was restored byte-exact to HEAD to
  keep the landed row authoritative, zero churn (`git diff` clean).
- `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` — window pointer bumped
  Mint-from KD-179 → **KD-180** and the KD-179 window row added under
  "Rows minted this window" (HEAD carried neither).

## Gates (embedded output, post-mint re-run)

```
$ python3 scripts/kd_flip.py
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2 (pre-mint: KD-168 registrar hold + KD-174
mention-only) -> 1 post-mint (KD-174 pending resolved by a concurrent lane
mid-session; KD-168 hold intact)
```

(read-only; FLIP-ELIGIBLE 0 pre- and post-mint — KD-179 is registration-only,
no KD-COVERS shim minted, so no flip eligibility is created)

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 327 receipt cites across 6 registers + 2 pattern docs -> OK   (pre-mint)
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK   (post-mint, this receipt + kdn1-row.md counted)

$ just docs-dod-check
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/RECEIPTS.md
...
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
```

All three gates green pre- and post-mint.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
python3 scripts/kd_flip.py                 # read-only: FLIP-ELIGIBLE 0
python3 scripts/kd_receipt_fence.py        # OK, 329 cites
just docs-dod-check                        # OK
grep -c 'KD-179' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md   # 1
grep -c 'KD-180' docs/jira/v26.10.22/KNOWN_DIVERGENCES.md   # 1 (mint-from)
```

No `lib/`, `test/`, or `smalt-cli/` edits. The pre-existing `smalt-cli/tests/test_ty_arm_handshake.py`
worktree modification is another lane's in-flight file — untouched, unstaged.
