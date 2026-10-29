# BK-FIN3 — FINAL-RELEASE-26.10.22 refresh (census re-run + gate-ledger refresh + seal inputs)

**Standing:** ALIVE · **Context:** solo · 2026-10-22 · Lane BK-FIN3
Files owned/edited: `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` (only doc),
this receipt. No `lib/`, `test/`, or coordinator-owned doc edits.

## 1. Fresh mechanical KD census (bk10c awk convention, real counts)

`awk -F'|'` status-cell (`$(NF-1)`) extraction over every `| KD-nn |` row in
the canonical register `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`:

- **TOTAL 177**, 0 duplicate ids (`grep -oE '^\| KD-[0-9]+' | sort | uniq -d` → empty)
- CLOSED (all faces, `^CLOSED` case-insensitive): **166**
- OPEN (TYPED DISPOSITION): **5** — KD-168, KD-174, KD-177, KD-178, KD-179
- PINION **2** (KD-05, KD-101) + PINION-WITNESSED **2** (KD-159, KD-160) = 4
- ENVIRONMENT-PINION **1** (KD-162)
- UNSUPPORTED-BY-COST **1** (KD-90)

166+5+4+1+1 = 177, no skew. Delta vs the doc's previous 172 (BK-FIN): KD-176
(MAA nonce registry, mint-then-close), KD-177 (loopback-unwitnessable
hardware-anchored trust class row), KD-178 (Web PubSub supervision split),
KD-179 (inet_aton loopback shorthand, accepted-because-genuinely-loopback),
KD-180 (Kafka legacy recordsCount, mint-then-closed CLOSED-WITH-EVIDENCE)
minted since; KD-173 and KD-175 flipped CLOSED since the last census lineage
snapshot (doc previously listed them OPEN). v26.10.22 pointer names KD-180 as
highest minted / KD-181 next — consistent with the canonical table.

## 2. Gate-ledger refresh (every standing re-read from the receipt on disk at use time)

- **COURT-CLI-SURFACE** — new row: `bkclirow-cells.md` (ALIVE, Context: solo);
  typed from `bkcliv-final-verify.md` (ALIVE: 149+37+35(+2 skipped)+102 py
  passes on the live `:enforce` substrate, pyright 0 errors); PARTIAL_ALIVE
  residues (`expl12-cli-flag-parity.md`, `expl12v-auth-uniform.md`) preserved
  as their own auth-uniformity row (expl12v PARTIAL_ALIVE → `expl12f-auth-final.md`
  ALIVE).
- **Monitor face** — `bkmon3-final-standing.md` (PARTIAL_ALIVE — metrics 500
  gone, CLI face repaired; residue BK-MON3-F1 dead join predicate) →
  `bkmon4-final-verify.md` (ALIVE at HEAD `daea2d87`).
- **Kafka legacy face** — `bkkfkskep-kafka-audit.md` → BK-KFKC repair
  (`# KD-COVERS: KD-180`) → `bkkfkv-replay-verify.md` (ALIVE — mixed-size
  legacy series byte-exact across seal→kill→restart, planted count=5 lie
  advances hwm exactly 2, magic-2 lie → typed err=2); KD-180 CLOSED-WITH-EVIDENCE.
- **Fence exemption + regression fix** — `bkxprif-plug400-exempt.md` (ALIVE —
  typed 400 no longer swallowed by the crash-path fence,
  `lib/smalt/arm_gateway/router.ex:146`) → `bkxpriv-exempt-verify.md` (ALIVE,
  cross-suite) + `bk115b-trip-regression.md` (ALIVE — both gates green on the
  exact subject).
- **Citation fences** — `bkciteg-citation-fence.md` (ALIVE) →
  `bkcitev-fence-verify.md` (ALIVE).
- **Standing-contract hardening** — bkstand2 (13/13, NO-STANDING 27→13) →
  bkstand3 (12 prose-only rows, →0) → bkstand4 (residue closed to one honestly
  typed extractor artifact) + bkfmt + bk100b, all PARTIAL_ALIVE as receipted.
- **Store4 disposition** — `store4-partition-court.md` (ALIVE, court 4/4 PASS
  ×3) + `bkst4w-store4-disposition.md` (ALIVE, `test/internal/store4_no_boot_test.exs`).
- **F1-A mirror closure** — `bkf1a-needsat-mirror.md` → `bkfondv-f1a-verify.md`
  (PARTIAL_ALIVE) → `bkfondw-f1a-closure.md` (ALIVE); pattern companion
  `bkbmir3-mirror-wave3.md` (ALIVE, 0 untracked of 59).

## 3. Seal inputs (typed, not smoothed)

- **Court census 6/6: GREEN** — `bkcens4-wave4.md` (ALIVE, 6/6 on the sealed
  population) + `bkcens5-wave5.md` (ALIVE, JA10 dead allowlist closed, internal
  census exit 0 `Result: 5 passed`).
- **witness-all freshness: IN-FLIGHT** — BK-WIT4 has no receipt on disk; latest
  landed is `bkwit3-witness-final.md` (PARTIAL_ALIVE, 130 green / 337
  stale-typed / 25 red, all classified, zero untyped SKIPs). Typed IN-FLIGHT.
- **Last full-suite line: NO quiescent green** — `bkseal3-quiesced-rerun.md`
  (PARTIAL_ALIVE — full `mix test` compile-aborted on an in-flight lane file,
  no result line) and `bkseal4-close-condition.md` (PARTIAL_ALIVE — census 6/6
  reached but close condition NOT met). Last numeric line remains
  `bkseal2-fullgreen-recheck.md` 764/780 (failures from unregistered in-flight
  test files + cross-lane collisions, zero pointing at `lib/`). No quiescent
  full-suite green exists on disk as of this refresh; seal stays PENDING.

## 4. Verification (commands + exits)

- Census commands embedded above (awk/grep/sort/uniq), run this session on
  `/Users/sac/smalt` @ current HEAD.
- Path verification: every newly cited receipt path `[ -f ]`-verified at use
  time — 30 newly cited paths all OK; typed-MISSING expected receipts (each
  types its gap in the doc): fr-snc-005, fr-snc-006, bk44-witness-all,
  bk35-head-court-sweep, ttv7b-quiesced-flip, bkseal5-*, ttv5-store-partitioning,
  bk53-finalrelease-seal.
- `just docs-dod-check` → **exit 0** (kd-receipt-fence: 767 cites, 7 typed-gap
  skips — all on this doc's typed-gap lines → OK).
- `python3 scripts/receipt_index.py` → **exit 0** (receipts=1516 sdk=61
  suspects=9, all 9 SUSPECT rows pre-existing, none mine);
  RECEIPTS.md/INDEX.md regens restored byte-exact — coordinator-owned, other
  lanes in flight.

## 5. Falsifier / residual risk

- Census counts are re-derivable by the embedded awk one-liner; a skew or a
  duplicate id would flip this row to SUSPECT.
- If BK-WIT4 / BK-SEAL5 / bk44-witness-all land postdating this draft, the
  IN-FLIGHT typings above are stale by design — successor lane re-points them.
