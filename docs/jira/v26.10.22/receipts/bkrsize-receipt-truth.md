# BK-RSIZE — receipt-size ground truth: both figures are real, of different surfaces — ALIVE

**Standing**: ALIVE
Context: solo
Date: 2026-10-22
Lane: BK-RSIZE

## Resolution of BK-WP2 finding D1

**No measurement is wrong and no minter diverged.** The 320 B / 40-word claim and
PB4-R's 48-word figure measure two DIFFERENT objects:

1. `Smalt.Sync.Receipt.mint/1` token (BK-92 cross-mint surface): fixed 320-byte
   binary, 640-char lowercase hex. Layout-pinned, a pure function of
   (leafCount, root). **Re-measured on real output this session: byte_size = 320,
   token = 640 chars, header `534d4c5400000001` at n=10.** BK-92's
   byte-identical cross-mint claim is about THIS object and is unaffected —
   no differential re-run required (nothing changed its inputs or shape).
2. `Smalt.PPlan.ReceiptEngine.seal_receipt/3` receipt MAP (the PB-4 bench
   subject, `surface: "pplan.receipt_engine.seal"` in
   `tmp/bench/pb4-merkle-dual.jsonl`): an Elixir map term whose heap size is
   measured by `:erts_debug.size/1`. **Re-measured on real output this session:
   46 heap words (368 B) for a 0-step seal (`run_id` only); 48 heap words
   (384 B) in the PB4-R harness (10 live-DETS steps).** The GAP-6a PROV-O
   agent chain (BK-129rr, PASS; BK-111, ALIVE) added `:agent` + 3 agent
   ntriples lines — this grew the term from the pre-GAP-6a 40 words to
   46–48. PB4-R's 48 is REAL, not a measurement artifact.

Keys witnessed on the real seal: `[:signature, :step_count, :merkle_root,
:ntriples, :run_id, :agent, :phi_lease_final]` (the `:agent` key is the
GAP-6a addition). `ntriples` binary = 458 B at 0 steps.

The O(1) law itself holds on both surfaces: sync token fixed 320 B at every n;
seal term 48 words at every n∈{10..10^5} (PB4-R re-run).

## Embedded commands + output

```
$ MIX_BUILD_ROOT=_build-rsize MIX_ENV=dev mix run --no-start -e '...'
SYNC_MINT token_len_chars=640
SYNC byte_size=320 erts_words=8
SYNC n=10 byte_size=320 head=534d4c5400000001
SEAL keys=[:signature, :step_count, :merkle_root, :ntriples, :run_id, :agent, :phi_lease_final]
SEAL erts_words=46 bytes_if_8per_word=368
SEAL ntriples_bytes=458
```

(compile exit 0; full-app boot refused — Kafka 9092 eaddrinuse from a
concurrent substrate, off-path since `--no-start` needs no app boot.)

## Doc updates (this lane)

- `docs/jira/v26.10.22/SYNC-RECEIPT-CHAIN.md` §3: the "O(1) size claim"
  bullet mis-anchored PB-4 to the sync token section; now types the two
  surfaces (sync token 320 B layout-pinned; PB-4/pplan term 48 words
  post-GAP-6a).
- `docs/jira/v26.10.22/ARCH-SYNC-MEMO.md` §2 Provenance row: 40-word (320 B)
  → 48-word (384 B) pplan receipt post-GAP-6a (bk129rr/PB4-R anchors).
- Whitepaper `lithography.tex` D1 figures NOT edited (operator-flagged,
  one-writer rule) — the fix is now: 40→48 words, 320→384 B, and cite the
  seal ladder from the PB4-R re-run (`receipts/pb4r-identity-court.md`).

## Falsifier status

Killed: "one of the measurements is wrong" — both reproduce exactly. Killed:
"the two minters diverged" — BK-92's subject (sync token) is unchanged at
320 B and remains a byte-identical function of (leafCount, root); the pplan
seal is not a BK-92 surface. Survived: the receipts genuinely grew via
GAP-6a; docs carried the stale pre-GAP-6a figure.
