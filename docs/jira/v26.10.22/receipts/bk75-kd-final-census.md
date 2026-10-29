# BK-75 — KD Register Final Census (v26.10.22 wrap)

**Standing:** **PASS** — register satisfies the terminal gate. Every row is CLOSED-family or a
typed Disposition; the only 2 OPEN rows (KD-88, KD-153) each carry owner + falsifier +
next-action. Zero kd_flip skew. One cross-doc staleness named below (pointer doc
distribution lines, not the register itself).

Context: solo

Date: 2026-10-21. Read-only census; register untouched (flips belong to owning lanes).

## Method (mechanical, re-read at use time)

Python line-parse of every `| KD-nn |` row's final status cell in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (343 lines; id range KD-01..KD-163,
160 rows — KD-95, KD-96, KD-158 never minted; no duplicates).

## (1) Status-cell classification counts

| class | count | rows |
|---|---|---|
| CLOSED (all faces incl. bare `CLOSED`) | 152 | 150 `CLOSED-*` (WITH-RECEIPT / SIMULATED / OBSOLETE / WITH-EVIDENCE) + KD-52, KD-63 (bare `CLOSED` with in-row close text) |
| OPEN | 2 | KD-88 (EH checkpoint-store pump warm-up race, cold boot), KD-153 (SB ARM namespace PUT 202 vs real 200/201 LRO face) |
| PINION / PINION-WITNESSED | 4 | KD-05, KD-101, KD-159, KD-160 (159/160 witnessed via `docs/jira/v26.10.21/receipts/bk48-pinion-witness.md`, verified on disk) |
| ENVIRONMENT-PINION | 1 | KD-162 (local OTP 29.1.2 `runtime_tools.app` install defect; fix named in-row) |
| UNSUPPORTED-BY-COST | 1 | KD-90 (affidavit seal latency, b3sum subprocess dominance; bench-pinned, typed disposition) |
| **total** | **160** | |

## (2) Non-CLOSED rows — owner / falsifier / next-action gate

The table schema has no dedicated owner column; ownership is named in-row. Per-row check:

| row | status | owner | falsifier / pinion basis | next-action |
|---|---|---|---|---|
| KD-88 | OPEN | named in-row | yes — repeated cold-boot runs of the EH dataplane court, all 20 events + checkpoint first attempt | root-cause or stabilize pump attach; court re-run closes |
| KD-153 | OPEN | registrar-owned (mirrored from v26.10.20) | yes — PUT answers 200/201 post-shim with wire witness | flip receipt-gated via scripts/kd_flip.py; typed pinion is the alternative arm |
| KD-05 | PINION | yes (per K1 disposition) | pinion, permanent-by-design (no falsifier owed) | none owed |
| KD-101 | PINION | yes (per K7 disposition) | pinion, air-gap remote-push permanent-by-design | none owed |
| KD-159 | PINION-WITNESSED | yes (BK-48) | witness receipt, not a falsifier — pinion class | none owed |
| KD-160 | PINION-WITNESSED | yes (BK-48) | witness receipt — pinion class | none owed |
| KD-162 | ENVIRONMENT-PINION | yes (registrar disposition 2026-10-21) | environment defect (install-level, not code) | fix named in-row: verify `runtime_tools.app` in active toolchain |
| KD-90 | UNSUPPORTED-BY-COST | yes | bench-pinned (`docs/jira/v26.10.16/bench/affidavit-seal.jsonl`, verified on disk) | none — typed disposition |

Notes: pinion-class rows carry no falsifier by design — their basis is the witness that
pinned the permanent behavior (BK-48 receipt verified on disk). KD-52 / KD-63 use bare
`CLOSED` rather than a `CLOSED-*` token; both carry in-row close text with receipts —
tolerated vocabulary drift, not a gate failure, named here so the wrap knows.

## (3) kd_flip.py read-only parse

```
KD-COVERS covers-map: 111 KD ids from 130 files
FLIP-PENDING-WITNESS: 0
```

Exit 0. Zero skew — exit 0 also proves every `# KD-COVERS: KD-nn` token in lib/ and
workspace/lib resolves to a register row (the tool exits 1 on unknown ids): register and
shim layer are in sync.

## (4) `just kd-stale`

```
[KD-STALE] no pending-witness rows
FLIP-PENDING-WITNESS: 0
```

Exit 0, zero pending flips.

## (5) Pointer-doc cross-check

`docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` ("Open residuals — KD register census
(fresh, 2026-10-21)") states **160 rows total** — matches the mechanical count exactly.
Its distribution is now stale: it counts **5 OPEN** (KD-88, KD-90, KD-153, KD-159,
KD-160) where the fresh census has **2 OPEN** (KD-88, KD-153) — KD-90 flipped to
UNSUPPORTED-BY-COST and KD-159/160 flipped to PINION-WITNESSED after that census was
taken. Fix: refresh the distribution lines in FINAL-RELEASE-26.10.22.md from this
receipt before seal. The row-count claim (160) is correct as printed.
`docs/WIRE_PARITY.md:267` pointer checked — no row-count claim, no drift.

## Terminal-gate posture

"Every row CLOSED-* or typed Disposition with falsifier+owner+next-action": **SATISFIED**.

- 152/160 CLOSED; 6/160 typed Dispositions (4 PINION, 1 ENVIRONMENT-PINION,
  1 UNSUPPORTED-BY-COST), each with owner + basis + (where applicable) next-action.
- 2/160 OPEN (KD-88, KD-153), both fully specified (owner + falsifier + next-action).
- Rows failing the gate: **none**.

## Verdict

PASS. 160 rows: 152 CLOSED / 2 OPEN (fully specified) / 6 typed Disposition /
0 pending flips / 0 register-shim skew. Register is wrap-ready.

## Falsifier

Re-run the census: any non-CLOSED row lacking owner, falsifier-or-pinion-basis, or
next-action; any kd_flip exit 1 (unknown KD-COVERS id); any nonzero
FLIP-PENDING-WITNESS; or a post-refresh FINAL-RELEASE distribution that diverges from
this receipt's counts — any of these flips this receipt to FAIL/STALE.
