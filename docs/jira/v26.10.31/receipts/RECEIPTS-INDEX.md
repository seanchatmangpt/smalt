# RECEIPTS-INDEX — v26.10.31 consolidation lane 3

Generated 2026-10-30 by consolidation lane 3. Read-only sweep of
`docs/jira/posh/v26.10.30/receipts/**` plus the adapters receipts dir
(`adapters/terraform-provider-smalt/scripts/receipts/`). No re-derivation —
verdicts and SHAs are read from the files. SHA column: first 40-hex found in
the file (subject SHA where the receipt declares one); "(as-of)" = no 40-hex
SHA in the file, standing is as-of its write time. `scripts/receipts/` at repo
root is absent on disk (confirmed missing — see MISSING rows).

## v26.10.30 receipts — `docs/jira/posh/v26.10.30/receipts/`

| Date | Subject SHA | Verdict (as written) | Path |
|---|---|---|---|
| 2026-10-30 | f0e0a12575c38f07e37a40ed58f4e448086c97b3 (base 845c1318…) | ALIVE (consequence standing, derived from make build/test/poshvet-budget/pgo-merge/doctor 12-probe) | receipts/wave2-membrane-receipt.json |
| 2026-10-30 | none in file — as-of (subject: archived Elixir spike, sha256 f0fe321b…dab6a16d) | ALIVE — plan completes; 6 falsifier-found gaps patched, enumerated | receipts/schema_parity_live.md |
| 2026-10-30 | f0e0a12575c38f07e37a40ed58f4e448086c97b3 (base 845c1318…) | ALIVE (12-Probe Andon GREEN, 0.0 DPMO; work_order SPEC-2610-PISO-RELEASE) | receipts/v26.10.30-release-receipt.json |
| 2026-10-30 | none in file — as-of (~12:10 local; AS-OF NOTE: superseded in part by later lanes) | PARTIAL — 7/8 packages pass; gate 1 andon in-flight; live-wire substrate BLOCKED at wrap | receipts/final-wave-receipt.md |
| 2026-10-30 | none in file — as-of | COMPLETE (F10) — freed 0 bytes; nothing to delete; canonical `_build` untouched | receipts/lease-cleanup.md |
| 2026-10-30 | none in file — as-of (subject /tmp/f2-provider copy of the Elixir spike) | ALIVE — provider court exit 0, 8/8 stages PASS, twice consecutively | receipts/provider-court-20261030.md |
| 2026-10-30 | 35bd36d021928f083f42d484ffdd2676adb89e82 | window audit: DPMO 0.0, static binary note; andon signals UNKNOWN×4 / GREEN×1 / PASS×1 at audit time (pending receipts later landed, incl. go-gates-witness-f11) | receipts/dflss_audit_receipt.json |
| 2026-10-30 | n/a (shas are file-hash shas: before 36caf455…/after 36caf455… byte-exact restore) | PASS (F4) — non-vacuity witnessed: shim exit 2, 3/4 tests fail with plug disabled; restore 4 passed | receipts/mutation/turnstile-flip.json |
| 2026-10-30 | n/a (file sha256 before/flip recorded) | FAIL-as-expected (flip exit 1) — ghost face `wire_op:echo` flagged loudly; non-vacuity proven | receipts/parity/posh009-coverage-gate-flip.json |
| 2026-10-30 | n/a | PASS exit 0 — 15 faces / 15 cells, 9 pass + 6 registered-divergence, zero silent gaps | receipts/parity/posh009-coverage-gate-green.json |
| 2026-10-30 | none — as-of | FAIL — exit 1, died in [POSH-COURT-PRE] at [KIND-IMAGES-FAIL] (kind node disk low); no stage witnessed | receipts/posh-court/posh-court-green.json |
| 2026-10-30 | none — as-of (subject beam pid 47052, ARM plane 127.0.0.1:9443) | ALIVE — STS mint + turnstile blake3 recompute match on GET/PUT | receipts/posh-court/live-wire-witness-f2.json |
| 2026-10-30 | none — as-of (subject posh Go tree) | GREEN — gofmt/vet/test -race all exit 0, 7 packages ok; NAT64 e2e PASS | receipts/posh-court/go-gates-witness-f11.json |
| 2026-10-30 | none — as-of | PASS — BenchmarkWriteFrame median 2087 ns/op, 9 allocs/op; p99 SLA UNMEASURED (no load rig) | receipts/measure/posh002-latency.json |
| 2026-10-30 | none — as-of | Disk finding: tree contains Go provider only; Elixir-spike premise does not match disk (31 files enumerated) | receipts/migration/terraform-provider-smalt-ledger.md |
| 2026-10-30 | none — as-of | APPLIED / ALIVE (POSH-007 ERRC delete; coordinator-owned transition; lane W-F draft) | receipts/migration/posh007-errc-delete-receipt.json |

## Adapters receipts — `adapters/terraform-provider-smalt/scripts/receipts/`

| Date | Subject SHA | Verdict (as written) | Path |
|---|---|---|---|
| 2026-10-30 | none in file — as-of (subject: working tree, uncommitted) | ALIVE — provider package gates executed this session; closes G2/G3/G5/G6 as loud-by-default | adapters/terraform-provider-smalt/scripts/receipts/c2-honesty-law-2026-10-30.md |
| 2026-10-30 | none in file — as-of | MIXED — stages 1–4 PASS, stage5 apply FAIL, stage6 falsifier FAIL, stage7 drift-replan FAIL | adapters/terraform-provider-smalt/scripts/receipts/provider-court-2026-10-30.md |

Note: `scripts/receipts/` at the smalt repo root is MISSING (gap-59 census and
this sweep agree). The two adapter receipts above are the only files in any
`scripts/receipts/` path on disk.

## Loud MISSING — referenced by lanes, absent on disk

| Missing path | Referenced by |
|---|---|
| `docs/jira/posh/v26.10.30/receipts/c2-honesty-law-2026-10-30.md` | lane references expecting it under the window receipts/; actual file lives at adapters/terraform-provider-smalt/scripts/receipts/ (INDEX.md: "no c2 receipt exists under receipts/") |
| `docs/jira/posh/v26.10.30/receipts/provider-court-2026-10-30.md` | hyphenated-date reference; actual file is `provider-court-20261030.md` (no hyphens) |
| `docs/jira/v26.10.25/receipts/court-x2-2026-10-25.md` | gaps/61-feedback-latency.md:101 (cited as MISS in that gap doc) |
| `docs/jira/v26.10.25/receipts/release-receipt.json` | gaps/61-feedback-latency.md:102 (cited as MISS) |
| `scripts/receipts/` (repo root) | gaps/59-receipts-discoverability.md census ("MISSING"); `just receipts` recipe references it |
| `posh/var/andon.jsonl` | gaps/41-andon-wiring-landing.md (chain landed at /Users/sac/smalt/posh/var/andon.jsonl, 7 rows — not present on disk now), gaps/59, gaps/60 |
| `tmp/posh/andon.jsonl` | gaps/66-dx-telemetry.md, gaps/10-observability.md (ephemeral default path) |
| `.ggen-v2/receipt-log.jsonl` | gaps/59 census — MISSING |
| `receipts/2026-10-30.jsonl` / `receipts/INDEX.jsonl` / `receipts/used_attrs.json` | string references inside receipts/ docs; no files on disk |

Note on andon/SLA fixtures: no andon/SLA *receipt* files exist under the
window receipts tree. Andon evidence in-tree is code + gap docs
(`posh/internal/andon/receipt.go`, gaps/41, charter/glossary) plus the
12-Probe Andon GREEN claim inside `v26.10.30-release-receipt.json`; the
runtime chains (`posh/var/andon.jsonl`, `tmp/posh/andon.jsonl`) are absent.
The POSH-006 SLA fixture is referenced in gap docs only — no fixture receipt
on disk.
