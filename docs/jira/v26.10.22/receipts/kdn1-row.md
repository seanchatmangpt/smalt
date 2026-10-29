# KD-N1 — KD-178 register row: WebPubSub broker-restart silent wipe

**Standing:** ALIVE
**Context:** solo
**Date:** 2026-10-22

## Task

BK-WPSS2's receipt (`bkwpss2-recovery.md`, ALIVE) witnessed BK-WPSS2-N1 —
the broker-wipe silent-to-clients divergence — and claimed the divergence
was "now register-typed" but committed only its receipt. This lane verified
the claim and completed the registration.

## Verification (step 1 — row absent)

Embedded grep over both KNOWN_DIVERGENCES.md registers:

```
$ grep -in 'silent\|wipe\|drop.*connect\|wpss' \
    docs/jira/v26.10.22/KNOWN_DIVERGENCES.md \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
docs/jira/v26.10.22/KNOWN_DIVERGENCES.md:25:  registered, not silent. KD-COVERS shim: landing in flight (KD-169R —
```

The only hit is the KD-169 prose token "registered, not silent" — no KD row
carries the broker-wipe/Bandit-supervision-split divergence in either
register. Minted KD-178 (next free id; pointer said "Mint from KD-178",
highest minted was KD-177).

## What was minted

- **Canonical register** (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`):
  KD-178 table row — surface (WebPubSub broker `Smalt.WebPubSub` GenServer
  vs separately-supervised Bandit child), divergence (real supervised kill
  wipes groups registry + witness buffer to `{:ok, 0}` publishes and
  first-try rejoins while sockets ride Bandit; real Azure drops
  connections), evidence `docs/jira/v26.10.22/receipts/bkwpss2-recovery.md`
  (5/5 witnessed, Context: solo), typed posture **deliberate in-memory
  contract** (judged honestly: not a wire-format delta, no credential face
  opened; the surviving-socket channel is the same separately-supervised
  listener that keeps the wire face alive through broker restarts),
  close condition (socket lifetime linked to broker death with a witness
  receipt, or re-register), owner (Web PubSub follow-up lane).
- **Window pointer** (`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`): KD-178
  window row + pointer bump "Mint from KD-179".
- No `lib/` or `test/` edits. No KD-COVERS shim (registration-only row; a
  socket-lifetime link landing in `lib/smalt/webpubsub/` carries
  `# KD-COVERS: KD-178`).

## Gates (step 3)

```
$ python3 scripts/kd_flip.py
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 2
  KD-168: registrar hold — cross-id evidence matches are refused
  KD-174: no post-shim receipt newer than shim mtime (2026-10-22T06:30:52)
rc=0
```

kd_flip read-only: FLIP-ELIGIBLE 0 post-mint — the new row did not mint any
spurious flip eligibility (KD-168 hold intact, KD-174 pending unchanged).

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 326 receipt cites across 6 registers + 2 pattern docs -> OK
rc=0

$ just docs-dod-check
... (tail)
kd-receipt-fence: checked 326 receipt cites across 6 registers + 2 pattern docs -> OK
```

Fence and docs-dod both green (the row's cited receipt
`receipts/bkwpss2-recovery.md` exists on disk).

## Disposition

Registration complete. Status OPEN (registered); owner = Web PubSub
follow-up lane; flip only via `scripts/kd_flip.py --apply` gated on a
witness receipt postdating the socket-lifetime-link shim.

## Disclosure (commit hygiene, same-checkout fan-out)

Commit a1176901 swept two files this lane did NOT author or stage: the lane
staged exactly its 3 files, but the shared index already carried another
lane's in-flight staging — `docs/ERROR_CODES.md` (regen, 148 lines) and
`docs/jira/v26.10.22/receipts/expl12b-login-monitor.md` (EXPL12B receipt).
Both are disclosed here as NOT-KD-N1 content riding the shared index at
commit time; content is presumed another lane's legitimate landing (fence
+ docs-dod passed over the full tree post-commit). Per the immutable-commit
law the commit is not rewritten; coordinator should attribute those two
files to their owning lanes, not to KD-N1. Lesson applied: on a shared
checkout, verify `git diff --cached --name-only` against the lane's own
file list immediately before `git commit`.
