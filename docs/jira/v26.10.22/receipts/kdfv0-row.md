# KD-FV0 — KD-181 minted: Kafka Fetch-v0 legacy face serves magic-2 verbatim

Standing: ALIVE (row registered; divergence witnessed fresh). Context: solo.

## Scope (lease)

Lane KD-FV0 owned ONE new KD row (KD-181) + this receipt. No `lib/` or
`test/` files touched. Harness scripts under `tmp/` (scratch, unindexed):
`tmp/kdfv0_boot_store.exs`, `tmp/kdfv0_probe.py`.

## Step 1 — KD-174 truth cell does not already cover this

Read the KD-174 canonical row (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`)
including the KD-174F two-layer truth-cell addendum: KD-174's scope is the
PRODUCE face — magic-2 payloads accepted inside in-matrix Produce v0-v2
requests (CRC32C-verified, stored, served byte-exact), out-of-matrix Produce
v3 REQUEST versions take the crash-only kill; close condition is a real
client NEGOTIATING magic-2 produce (Produce v3+ advertisement). The Fetch
face (down-conversion on low-version fetches) appears nowhere in the row;
the only fetch mention is "re-served byte-exact" — which is precisely the
behavior KD-181 registers as divergent on the legacy face. Different surface,
different close condition — no coverage overlap. Mint justified.

## Step 2 — Fresh probe (real client, stored magic-2, Fetch v0)

Harness: `tmp/kdfv0_boot_store.exs` (boots the smalt app test-tier on a free
ephemeral kafka port, stores a raw magic-2 RecordBatch — court-verbatim
`batch/2`/`record/1` builders, real `Wire.crc32c/1` — on topic "kafka" top
partition via in-matrix Produce v0, err=0 corr_match=true) + `tmp/kdfv0_probe.py`
(real kafka-python-ng subprocess, api_version=(0,9) → Fetch v0: first
produces 3 legacy frames on the partition with api_version=(0,10,0), then
consumes from 0).

First probe (single clean magic-2 batch only, no legacy frames): 1 record,
no crash — kafka-python-ng dispatches on the magic byte, so an ALONE magic-2
batch parses fine; the divergence needs a MIXED message set (the witness
premise). Second run added the legacy-produce leg — mixed set, crash face:

```
$ MIX_BUILD_ROOT=_build-kdfv0 MIX_ENV=test mix run --no-start tmp/kdfv0_boot_store.exs
KAFKA_PORT=55461
PRODUCE_V0_MAGIC2 part=1 err=0 corr_match=true
--- probe output ---
LEGACY_PRODUCED 3
REC b'\x00\x00\x02G \x84T\x00...kdfv0-magic2-value\x00' ts None off 0
REC b'kdfv0-legacy-0' ts 1792682095547 off 1
REC b'kdfv0-legacy-1' ts 1792682095650 off 2
REC b'kdfv0-legacy-2' ts 1792682095650 off 3
PART=1 CRASH=False
GOT 4 records, no crash
--- probe exit 1 (no crash variant) ---
```

Confirming run (60-byte magic-2 value, the bkkfkc batch shape):

```
$ MIX_BUILD_ROOT=_build-kdfv0 MIX_ENV=test mix run --no-start tmp/kdfv0_boot_store.exs
KAFKA_PORT=54932 (preceding boot, top-partition fix run: part=1 err=0)
--- probe output ---
LEGACY_PRODUCED 3
REC b'\x00\x00\x02\x02x+\xee\x00...\x01\x84\x01\x00\x00\x00\x01FFFF...(60 F)' ts None off 0
REC b'kdfv0-legacy-0' ... off 1-3
PART=1 CRASH=False
GOT 4 records, no crash
--- probe exit 1 ---
```

Finding: the stored magic-2 batch bytes are re-served VERBATIM on the Fetch
v0 face and delivered to a real legacy client as a GARBAGE legacy record —
value = the raw batch bytes (baseOffset, batchLength, CRC32C, recordsCount
fields all inside the "value"), timestamp None. Client-visible corruption.
Real Kafka down-converts magic-2 to message-set v0/1 on low-version fetches;
smalt serves the stored bytes with broker offset stamping only.

Typed residue: bkkfkc's struct.error arm (legacy_records.py, buffer 121 vs
131098) did NOT reproduce in the fresh probe — it is an order/content-
dependent client-side arm of the same verbatim-serve. Recorded in the row as
typed residue, not as the primary witness. The first no-crash run is the
probe's own negative control: alone-on-the-partition magic-2 parses clean,
mixed set corrupts — the divergence is real and face-specific, not a broken
probe.

## Step 3 — KD-181 minted

Canonical row appended to `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
(after KD-180); window row + mint pointer updated in
`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (Mint from KD-182; highest minted
id KD-181). Row carries: surface, divergence, fresh probe + bkkfkc typed
residue as evidence, typed posture OPEN (down-conversion owed by a fetch-face
lane), owner BK-122r kafka-parity lane, close condition = real client on
api_version≤1 fetches a magic-2-stored partition byte-exact, flip
receipt-gated via `scripts/kd_flip.py --apply`.

## Gates (fresh runs, actual exits)

```
$ MIX_BUILD_ROOT=_build-kdfv0 python3 scripts/kd_flip.py
KD-COVERS covers-map: 121 KD ids from 145 files
  (… per-id status map; KD-181 has no shim so is correctly absent …)
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
exit 0

$ MIX_BUILD_ROOT=_build-kdfv0 python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 768 receipt cites across 6 registers + 2 pattern
docs + 5 milestone docs (436 cites, 7 typed-gap skips) -> OK
exit 0

$ just docs-dod-check
kd-receipt-fence: checked 768 receipt cites across 6 registers + 2 pattern
docs + 5 milestone docs (436 cites, 7 typed-gap skips) -> OK
exit 0
```

kd_flip read-only: FLIP-ELIGIBLE 0 post-mint (no flip taken — registration
row, no shim); KD-181 correctly absent from the covers-map (no `# KD-COVERS:
KD-181` token in `lib/` yet). Fence and docs-dod both OK on 768 cites.
Pre-existing residue (not session-introduced): FLIP-PENDING-WITNESS 1 =
KD-168 registrar hold, witnessed before this lane opened.

## Standing

ALIVE — row minted with a fresh real-client witness on the current tree;
typed posture OPEN; owner named (BK-122r); close condition receipt-gated.
