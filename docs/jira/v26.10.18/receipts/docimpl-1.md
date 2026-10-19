# docimpl-1 — docs-audit D1+D11 implementation (README/CLAUDE.md/dev-loop)

Standing: PASS
Context: solo
Date: 2026-10-18

Ticket: docs-audit findings
`docs/jira/v26.10.18/docs-audit/d1-root-tutorials.md` +
`docs/jira/v26.10.18/docs-audit/d11-config.md`. No git (coordinator owns
transitions).

## Changes

README.md:

1. Invariant gates count 5→6, added `appconfig-etag-cas` to the gate list
   (matches `gates/appconfig_etag_cas_gate.py` on disk).
2. eh-run port defaults corrected to the real ones read from
   `test/sdk-smoke/eh-run.mjs:22-26`: AMQP 39172, EH 39173, ARM 39444,
   egress 39445, ARM-TLS 39446 (was the retired 15672/19443-class block).
3. Standing block date refreshed to 2026-10-18.
4. Eight new Part-2 sections, each citing existing receipts/docs (all
   paths existence-checked before landing):
   Planes (SMALT_PLANES, `lib/smalt/planes.ex:38`, receipt azb-04-plane-loader.md),
   azsim tier (10 files under `test/azsim/`, azb-14 receipt),
   Burn suite (`justfile.d/30-burn.just`, azb-13/burn-image receipts),
   Stress tier (`just test-stress`, `test/stress_tier_census_test.exs`,
   `docs/STRESS/BOUNDS.md`),
   Budget gate (`just test-budget`/`-seed`, `scripts/test_budget_gate.py`,
   rewrite-drafts/budget-gate.md),
   Zero-sleep doctrine (`docs/NO_SLEEP_DOCTRINE.md`,
   azb-21-zero-sleep.md receipt),
   Hex-only ex4pm (mix.exs:107 + ex4pm hex pin comment block),
   SmaltTest foundations (`test/support/case.ex`, `docs/TEST_ISOLATION.md`).

CLAUDE.md:

- `just invariant-gates` comment 5→6 gates + appconfig-etag-cas.
- `just verify-all` stage list now names test-stress/test-budget/sleep-gate
  (matches `scripts/verify_all.sh` stages c2/c3/g).
- semconv model path fixed to
  `lib/smalt/telemetry/semconv/model/smalt.yaml`.
- RECEIPT_CONTEXT_LAW path resolved to
  `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`.
- Test ladder: added `test-stress` / `test-budget` / `sleep-gate` lines.
- Three new convention bullets: Planes, Stress tier, Budget gate.

docs/how-to/dev-loop.md:

- "## The loop (just ingress)" → "## The loop" (dead qualifier removed).
- native-tier port range 29445-29449 → 29445-29450 (matches
  `justfile.d/22-native.just:56-63`, mcp_port 29450).
- "~8s full suite" claim replaced with the receipted 40-60s-class reality
  (the 8s figure was the 2026-10-14 suite; refresh rows show 40.8/51/57.9s).
- Known-state "latest counted" marked as-of-date: refresh-4 (8/1529) is
  still the latest counted full-suite run as of 2026-10-18; later rows are
  lane windows.

## Gate

`just docs-dod-check` after all edits:

```
OK    README.md
EXIT=0
```

Full run: 56/56 checks OK, exit 0 (2026-10-18, this tree).

## Verification of cited pins

Path/line existence check for every new citation (all present, none
MISSING): gates/appconfig_etag_cas_gate.py, lib/smalt/planes.ex:38
(`def resolve` doc line verified by sed), mix.exs:107
(`{:ash_ex4pm, "~> 26.10.1", ...}` verified by sed),
docs/jira/v26.10.18/receipts/{azb-04-plane-loader,azb-14-sigkill-storm,azb-13-boot-burn,burn-image,azb-21-zero-sleep}.md,
docs/NO_SLEEP_DOCTRINE.md, docs/STRESS/BOUNDS.md,
docs/jira/v26.10.18/rewrite-drafts/budget-gate.md,
docs/jira/v26.10.16/PUBLISH_RECORD.md, docs/TEST_ISOLATION.md,
docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md,
test/stress_tier_census_test.exs, scripts/test_budget_gate.py,
scripts/sleep_gate.py, test/support/case.ex.
