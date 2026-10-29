# BK-NFRV — NFR-row terminal audit of PRD.md v26.10.22 (skeptic, read-only)

**Standing**: ALIVE (audit; every NFR row holds its evidence class; 3 residuals still honestly typed). `Context: solo`
Lane: BK-NFRV · Date: 2026-10-22 · Method: per-row disk re-read of receipts cited by PRD §3/§4/§4a + raw-number spot-verify against receipt bodies and bench jsonl on disk.

## Per-row table (PRD §3 NFR anchors × §4 court matrix)

| Row | Requirement | PRD anchor claim | Disk verification (raw evidence re-read) | Verdict |
|---|---|---|---|---|
| NFR-LAT-002 | CAS p99 ≤5µs | native CAS put-if-match p99 5µs / 383,186 ops/s (`tmp/bench/powl-native-face.jsonl`) | jsonl on disk (mtime Oct 21): `ops_per_sec:383185.8, p99_ms:0.005` — matches 5µs / 383,186 ops/s (rounded). Receipt `receipts/bk5-powlbench.md` carries same face. | PASS — receipt-gated, measured anchor |
| NFR-LAT-005 | Sieve ≤0.50µs + ≤60 reds/step | 0.25µs median / 285.5 reds, drift 0.073–0.154%; reds-leg MET, wall-clock leg gated on quiescence (TTV-7b BLOCKED-ON-QUIESCENCE) | `../v26.10.21/receipts/gl9-governance-tax.md` ALIVE: median-diff **0.25 µs/step** (rows +0.25µs ×2); `ttv7-warmed-p99-standard.md` PARTIAL_ALIVE: warmed mean 285.45 reds, drift 0.073%; `ttv7b-quiesced-rerun.md` standing literally **BLOCKED-ON-QUIESCENCE** — typed, not smoothed. | PASS — both legs typed honestly |
| NFR-DUR-001 | Zero committed-key loss | TTV-4 kill court 100% survive | `../v26.10.21/receipts/ttv4-journal-boot-replay.md` Standing: **ALIVE**; kill court legs re-observed inside `just bkvc-court` leg 1, `Result: 7 passed` ×2 exit 0 (`receipts/bkvc-consolidated-courts.md` ALIVE). | PASS — receipt-gated |
| NFR-DUR-002 | Cascade ≤1.0ms | "JA-7 crash-only court: 0ms cascades ×10 cycles" | Crash-only court evidence exists: `../v26.10.21/receipts/amqp10-court-closure.md` PASS (SK1/SK1b 0ms, ADV-1 mid-frame-RST 0–1ms ×3); amqp10-skeptic-redispatch PASS. **But no receipt on disk is labeled "JA-7"** — label resolves to the amqp10 crash-only lane. | PASS with DRIFT row D1 (citation label, not evidence) |
| NFR-DUR-003 | Cold boot ≤2,000ms | TTV-6 re-typed ceiling, falsifier named | `ttv6-cold-boot-gate.md` Standing: **ALIVE** — ceiling re-type 500ms→2,000ms with named falsifier on disk. | PASS — receipt-gated |
| NFR-SEC-001 | Δatoms ≡ 0 @100k hostile | atom fence ja5 court; JA-R3 falsifier | `receipts/bkvc-consolidated-courts.md` → bkvc ALIVE ×2 (`Result: 7 passed`, atom-clamp leg re-observes JA-R3 D1 law on real `:atom_count`); `receipts/bksec-nfr-closures.md` PARTIAL_ALIVE composition-era standing superseded by bkvc named-court landing — consistent, not smoothed. | PASS |
| NFR-SEC-002 | Cert fail-closed observable | JA-R3 D2 (Logger.error ×4) | bkvc receipt: accept face on real minted CA + missing-`ca_certfile` typed refusal witnessed; court found+fixed real RSA `{e,n}` swap defect (`{:error, {:bad_cert, :invalid_signature}}`), 33-passed adjacency suite exit 0. `ja-r3-ja16-defect-fixes.md` Standing: PASS. | PASS — receipt-gated |
| NFR-SEC-003 | 16MiB/64MiB sandbox ceilings | GWS-11 measured boundary map | `../v26.10.21/receipts/gws11-wasm-memory-wall.md` ALIVE 7/7: request cap 16,777,216 B via `gl_alloc` null return; 64 MiB = HOST-layer `wasmtime --max-memory 67108864`, honestly typed "NOT DECLARED at wasm layer" — boundary map is measured, not asserted. | PASS |
| NFR-SEC-004 | Private-token gate | NEW WO COURT-PRIVATE-TRIP | `receipts/bk50-private-trip.md` honest RED (41 hits triaged) → `receipts/bk54-private-trip-remediation.md` **ALIVE** GREEN; `scripts/private_trip.py` on disk + wired in `justfile.d/48-private-trip.just` (gate + self-test recipes). | PASS — RED→GREEN chain intact |
| NFR-EVI-001 | O(1) receipt, two surfaces | sync token fixed 320 B (BK-92); seal term 48 words = 384 B n=10..10^5 post-GAP-6a | `receipts/bk92-receipt-sot.md` ALIVE (320-byte binary/640-hex, cross-mint byte-identical); `receipts/bkrsize-receipt-truth.md` ALIVE — reconciles 320 B/40-word vs 48-word as two DIFFERENT objects, both O(1), re-measured this session. MERKLE-O1 standalone court still PARTIAL_ALIVE in §4 (typed OPEN in §5). | PASS (residual typed) |
| NFR-EVI-002 | Cross-engine byte identity | GWS-12 court | `../v26.10.21/receipts/gws12-cross-engine-determinism.md` Standing: **PASS** (3 legs, partition identical, 2 typed findings). | PASS |
| NFR-LAT-001 | Local write p99 ≤10µs | SYNC-2 gate (browser-side court) | `receipts/ath2-nextjs-client.md` Standing: **ALIVE (browser surface); sync server leg PARTIAL_ALIVE** — matches PRD §2 FR-CLI row and §5 Gate-2 text. The ≤10µs wall-clock number itself has no measured anchor yet (court pending); typed as pending gate, not claimed MET. | PASS as typed (number UNANCHORED-by-design pending SYNC-2 court) |
| FR-SNC-001..004 | SYNC-1 receiver 5-gate court | ALIVE 11/11 | `receipts/ath1-batch-frame-receiver.md` Standing: ALIVE — 11/11 court gates green; auth `bk76-sync-auth-witness.md`, e2e `bk83-sync-e2e-auth.md` on disk. | PASS |
| FR-SNC-005/006 | fast-forward Merkle + join gate ω | UNBUILT (typed) | `receipts/bkvc-consolidated-courts.md` line 97: "the courts are UNBUILT because the capabilities are UNBUILT", falsifier+greps embedded; PRD §4 row says UNBUILT with owner (SYNC follow-up WO); §5 (b)/(c) OPEN. | PASS — honestly UNBUILT, not smoothed |
| COURT-MERKLE-O1 | NFR-EVI-001 standalone court | PARTIAL_ALIVE, court pending | PRD §4 + §5 both carry it OPEN; parent `../v26.10.21/receipts/pb4-merkle-dual-path.md` on disk (REFUTED-as-noise for the O(n) variant; O(1) law holds, 16-row jsonl on disk). | PASS — residual intact |
| UNANCHORED ledger | 5.0µs commit / WAL append; Merkle verify <0.2ms | typed UNANCHORED | `SYNC-RECEIPT-CHAIN.md` §7 lists both UNANCHORED with scope conditions; `ARCH-SYNC-MEMO.md` rows 25/27/48/49 same typing + named close condition. | PASS — honest residual intact |

## DRIFT rows (typed, owner: BK-NFRV → PRD owner for D1)

- **D1**: PRD §3 NFR-DUR-002 cites "JA-7 crash-only court"; no receipt on disk carries the JA-7 label — the evidence is `../v26.10.21/receipts/amqp10-court-closure.md` (PASS, 0ms cascades) + `amqp10-skeptic-redispatch.md`. Citation-label drift only; the measured evidence exists and supports ≤1.0ms. Fix: re-point the §3 cell to the amqp10-court-closure receipt path (owner: BK-PRDR-class PRD-matrix lane, next refresh).
- No other drift: every §4 cell's standing line matches its receipt's own standing header (bksec-nfr-closures PARTIAL_ALIVE is composition-era and superseded by bkvc ALIVE ×2 — supersession consistent, not smoothing).

## Non-vacuity

Audit is read-only; the per-row table above embeds raw on-disk numbers (p99_ms:0.005, ops 383185.8, 285.45 reds, 0.25µs, 320 B, 48 words, `Result: 7 passed`, 11/11) compared against PRD cell text — a PRD cell that had claimed numbers absent from disk would have produced a DRIFT row; the table is the kill witness for that branch.

## Commands (embedded output)

```
grep '"ops_per_sec"\|"p99_ms"' tmp/bench/powl-native-face.jsonl
→ "ops_per_sec":895335.3 / "p99_ms":0.002 ; "ops_per_sec":383185.8 / "p99_ms":0.005 ; ...
[ -f scripts/private_trip.py ] → present; grep private_trip justfile.d/*.just → 48-private-trip.just:8,12
grep Standing receipts/bkvc-consolidated-courts.md → ALIVE ×2, Result: 7 passed
```

## Falsifier

Any §3/§4 NFR cell whose cited receipt is absent (`[ -f ]` fails), whose standing line diverges from the receipt header, or whose measured number is not reproducible from the receipt/jsonl body → DRIFT row. D1 fired on label resolution, not on evidence absence.
