# KD-SKEP — adversarial register-integrity audit (canonical + window KD registers)

**Standing:** **PARTIAL_ALIVE** — zero fatal integrity violations on the checked set; 2 MED + 2 LOW-MED typed findings (below).
Context: solo
Date: 2026-10-22 (observations pinned ~05:10 local; see live-substrate note F6)
Lane: KD-SKEP (read-only skeptic; wrote only this receipt)

## Scope

Canonical register `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (171 rows) and
window pointer doc `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (6 bullets,
KD-169..KD-174), plus gates `scripts/kd_receipt_fence.py` / `scripts/kd_flip.py`
(read-only). Inputs: `kdsync-pointer-sync.md`, `kdmirror-canonical-sync.md`,
`kddod-pointer-fence.md` read first, as tasked.

## Gates re-run independently (real output)

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 308 receipt cites across 6 registers -> OK
fence-exit=0

$ python3 scripts/kd_flip.py        # read-only, two runs minutes apart
run-1: FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 1 (KD-171),
       WITNESS-AMBIGUOUS: 1 (KD-168, 3 candidate receipts)
run-2: FLIP-ELIGIBLE: 0, FLIP-PENDING-WITNESS: 3
         KD-168: no post-shim receipt newer than shim mtime (05:07:32)
         KD-169: 1 mention-only receipt (kd171r-secret-gate.md), flip refused
         KD-174: no post-shim receipt newer than shim mtime (05:04:38)
flip-exit=0 (both runs)

$ just docs-dod-check (tail)
OK ... / kd-receipt-fence: checked 308 receipt cites across 6 registers -> OK
docs-dod-exit=0
```

The KD-169 mention-only refusal is the tool's typed mention-only class firing
correctly (kd171r receipt names KD-169 but carries no close evidence for it).
Exit-0 with pending rows is the tool's documented standing: pending is a
loud-not-flipped state, not a pass.

## Mechanical checks (own independent implementations, as run)

```
$ grep -oE '\| KD-[0-9]+' canonical | sort -V | uniq -d | wc -l   -> 0
$ grep -oE '\| KD-[0-9]+' window    | sort -V | uniq -d | wc -l   -> 0
$ awk last-non-empty-cell census: 171 rows = 86 CLOSED-SIMULATED,
  35 CLOSED-WITH-RECEIPT, 21 CLOSED-WITH-EVIDENCE, 11 CLOSED-OBSOLETE,
  5 CLOSED, 5 CLOSED-with-receipt, 2 PINION, 2 PINION-WITNESSED,
  1 ENVIRONMENT-PINION, 1 UNSUPPORTED-BY-COST, 5 OPEN
$ window bullets {KD-169..KD-174} - canonical rows = empty  (projection law holds)
$ highest id mentioned anywhere (canonical+window) = KD-174
$ window pointer: "Mint from KD-175 (highest minted id is KD-174)"  -> matches highest+1
```

All six registers' pointer-vs-highest sweep (own check): v26.10.22 correct;
v26.10.19 ("Mint from KD-99", highest mentioned 120) and v26.10.20
("Mint from KD-143", highest mentioned 157) carry stale pointers — both are
CLOSED windows, pre-existing, out of this window's edit scope (F5 LOW).

## Findings (typed)

- **F1 [MED, register-content]** — Terminal-gate rule gap: the 4 OPEN
  "(registered)" rows (KD-169, KD-171, KD-163 no — KD-169/171/173/174) carry a
  close condition (falsifier) and typed posture but NO explicit owner /
  next-action fields; only KD-168's status cell has the full
  falsifier+owner+next-action triple. Per the terminal-gate rule
  ("every OPEN row's disposition has falsifier+owner+next-action"), these four
  are incomplete.
- **F2 [MED, standing-vs-evidence contradiction]** — canonical KD-172 row:
  status cell reads CLOSED-WITH-EVIDENCE (repair landed, kd173r receipt) while
  its evidence cell still says "KD-COVERS shim: none yet (registration-only
  row; a gate landing in `lib/smalt/messaging/amqp/sas_verifier.ex` carries
  `# KD-COVERS: KD-171`) — and it names the WRONG id `# KD-COVERS: KD-171`
  (the row was renumbered out of a KD-171 id collision and the prose never
  followed).
  Disk truth: sas_verifier.ex:190 carries `# KD-COVERS: KD-172`. The row
  text was never updated at flip time; both the flip lane (KD-173R) and the
  mirror lane (KD-MIRROR) verified mtime/flip state but not row-prose.
- **F3 [LOW-MED, stale-text]** — "shim: none" claims that are false on disk:
  KD-171 row says "KD-COVERS shim: none" while `workspace/lib/caller-gate.ts:3`
  carries `// KD-COVERS: KD-171`; KD-169 row says "shim: none yet" while
  `lib/smalt/webpubsub/router.ex` now implements the server-credential 401
  gate (mtime 05:03). Register prose lags landed code; standing OPEN is
  correct (flip is receipt-gated), but the "shim: none" sentences are
  factually false and will mislead the next registrar.
- **F4 [LOW, cite-content]** — cite-mention grep over all 5 OPEN rows + 10
  most-recently-touched CLOSED rows (15 cites / 14 receipts — sample stated
  honestly): 12/15 receipts name their row id; 3 do not (KD-168 ←
  az2-maa-attestation.md, KD-170 ← az3-confidential-ledger.md, KD-165 ←
  bk83-sync-e2e-auth.md). All three are receipts that predate the row id
  (renumber/collision-era); DOD existence fence passes, content-level mention
  is absent. No contradiction of standing — the load-bearing witnesses for
  these rows (bk11 triage, az3 court text itself, bk106) do name the rows.
- **F5 [LOW, pre-existing]** — stale "Mint from" pointers in CLOSED windows
  v26.10.19 and v26.10.20 (highest-mentioned id has moved past the pointer).
  Not introduced this session; noted, not owed by this window.
- **F6 [observation-window note]** — the substrate was LIVE under this audit:
  between two kd_flip runs minutes apart, PENDING went 1→3 as concurrent lanes
  landed shims (router.ex 05:03, kafka maa/kafka shims 05:04/05:07) and a new
  receipt `kd171r-secret-gate.md` appeared. All numbers in this receipt are
  pinned to ~05:10; a later reader must re-run the gates, not cite these.
  The KD-169 flip-pending entry proving the mention-only class fires on the
  kd171r receipt is a real witnessed firing of that fence.

## What held (no defect)

- No duplicate ids in either register; window rows are a strict subset of
  canonical rows (projection law intact after the KD-MIRROR lane).
- Receipt-cite existence fence green and independently re-verified (308 cites
  / 6 registers, exit 0), incl. the 5 phantoms KD-DOD fixed; docs-dod wiring
  carries the fence.
- Window pointer matches highest-minted+1 (KD-174 → mint from KD-175).
- kd_flip typed refusals fire for real (mention-only, witness-ambiguous
  resolved by newer shim — both classes observed firing this window).
- OPEN row KD-168's typed disposition is complete (falsifier, owner
  "az2 attestation lane", next action).

## Standing

PARTIAL_ALIVE — the register's mechanical integrity (uniqueness, projection,
pointer, cite-existence, flip-gating) is intact on the checked set; the
content-level defects F1/F2/F3 are registrar-text defects that do not corrupt
gate behavior but do misstate on-disk truth and should be fixed forward by a
registrar lane (KD-172 row prose, the four OPEN rows' owner/next-action
fields, KD-169/171 "shim: none" sentences).
