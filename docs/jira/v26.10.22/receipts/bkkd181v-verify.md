# BK-KD181V — KD-181 mint verification (read-only lane)

Standing: ALIVE. Context: solo.

## Checks (fresh runs on the current tree, actual exits)

### 1. Canonical register — docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:364

KD-181 row present, status OPEN, owner present, close condition present:

```
$ grep -n "KD-181" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
364:| KD-181 | Kafka Fetch-v0/v1 legacy face serves stored magic-2 batches
verbatim — no down-conversion (lane KD-FV0, 2026-10-22;
`lib/smalt/messaging/kafka/conn.ex` fetch response path; registration-only
row — a fetch-face down-conversion landing in `lib/smalt/messaging/kafka/`
carries `# KD-COVERS: KD-181`) | … (fresh probe witness + bkkfkc typed
residue evidence) | fresh probe witness: lane KD-FV0 harness
`tmp/kdfv0_boot_store.exs` + `tmp/kdfv0_probe.py` … +
`docs/jira/v26.10.22/receipts/bkkfkc-legacy-count.md` | a real client on
api_version≤1 (Fetch v0/v1) fetches a magic-2-stored partition byte-exact
(down-converted message-set v0/1) — flip receipt-gated via
scripts/kd_flip.py --apply, or the row is re-registered under a stronger
typed posture | OPEN (registered; owner = BK-122r kafka-parity lane —
fetch-face down-conversion, conn.ex fetch response versioning; next action
= down-convert magic-2 → message-set v0/1 on Fetch v0/v1 responses …) |
```

### 2. Window register — docs/jira/v26.10.22/KNOWN_DIVERGENCES.md

KD-181 window row present (lines 13-28) AND the mint pointer advanced:

```
$ sed -n '1,15p' docs/jira/v26.10.22/KNOWN_DIVERGENCES.md
… Mint from KD-182 (highest minted id is
KD-181 — lane KD-FV0 2026-10-22 minted the Kafka Fetch-v0 legacy-face
magic-2 verbatim-serve divergence row, canonical table). …
- KD-181 — Kafka Fetch-v0/v1 legacy face serves stored magic-2 batches
  verbatim, no down-conversion (KD-FV0, 2026-10-22; … Status: OPEN
  (registered). Evidence: receipt `receipts/kdfv0-row.md` + …
```

Pointer advanced correctly: "Mint from KD-182", "highest minted id is KD-181".

### 3. Gates (fresh runs)

```
$ grep -rn "KD-COVERS: KD-181" lib/ | wc -l
       0

$ MIX_BUILD_ROOT=_build-kdkd181v python3 scripts/kd_flip.py
KD-COVERS covers-map: 121 KD ids from 145 files
  (… per-id map; KD-181 ABSENT — correct, no shim …)
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
exit 0

$ MIX_BUILD_ROOT=_build-kdkd181v python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 768 receipt cites across 6 registers + 2 pattern
docs + 5 milestone docs (436 cites, 7 typed-gap skips) -> OK
exit 0

$ just docs-dod-check
kd-receipt-fence: checked 768 receipt cites across 6 registers + 2 pattern
docs + 5 milestone docs (436 cites, 7 typed-gap skips) -> OK
exit 0
```

### 4. Truth-cell re-verification (KD-174 covers PRODUCE only)

Fresh read of the KD-174 canonical row (v26.10.14 register line 354): scope
is the (0,10,0)-negotiated legacy message-set surface — the two-layer
KD-174F addendum places ALL magic-2 handling under the PRODUCE face:
request-VERSION gating (Produce v3 → crash-only kill) and PAYLOAD acceptance
inside in-matrix Produce v0-v2 (CRC32C-verified, stored, re-served
byte-exact). Close condition: "a real client NEGOTIATES magic-2 produce".
The only fetch mention in the row is "re-served byte-exact on fetch" — the
Fetch-v0 down-conversion face (real Kafka emits message-set v0/1 on low-
version fetches) appears nowhere. Disjoint surface, disjoint close condition:
KD-174 does not cover KD-181's divergence. Mint justified. Re-confirmed.

## Standing

ALIVE — both registers carry KD-181 (OPEN, owner BK-122r, close condition
present), pointer advanced (Mint from KD-182, highest = KD-181), no shim in
lib/ (KD-181 correctly absent from the kd_flip covers-map, FLIP-ELIGIBLE 0),
fence + docs-dod exit 0 on 768 cites, truth cell holds.

Pre-existing residue (not session-introduced): FLIP-PENDING-WITNESS 1 =
KD-168 registrar hold, witnessed before this lane opened.
