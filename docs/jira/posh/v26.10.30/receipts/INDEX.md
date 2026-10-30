# receipts/INDEX.md — v26.10.30 Receipt Register (lane 52, 2026-10-30)

One row per receipt file/dir under `docs/jira/posh/v26.10.30/receipts/`,
re-read from disk 2026-10-30. No c2 receipt exists under receipts/ as of this
index (checked: no filename matches c2/court-*c2).

| Path (under `receipts/`) | What it witnesses | Date |
|---|---|---|
| `posh-court/posh-court-green.json` | posh-court standing receipt: FAIL, exit 1, 0/8 PASS — died in `[POSH-COURT-PRE]` at `[KIND-IMAGES-FAIL]` (kind disk preflight); no stage ever witnessed | 2026-10-30 |
| `posh-court/go-gates-witness-f11.json` | Go gate outputs witnessed by lane F11 (vet/test-class gates on the posh Go tree) | 2026-10-30 |
| `posh-court/live-wire-witness-f2.json` | Live-wire witness receipt from lane F2 (real traffic-class probe against the running substrate) | 2026-10-30 |
| `measure/posh002-latency.json` | POSH-002 membrane latency instrument run — the only measure-phase instrument receipt in-tree (gap 10 row d) | 2026-10-30 |
| `migration/terraform-provider-smalt-ledger.md` | POSH-007 migration ledger: Elixir→Go terraform-provider-smalt migration steps and residue | 2026-10-30 |
| `migration/posh007-errc-delete-receipt.json` | POSH-007 ERRC delete receipt (removals applied under the migration) | 2026-10-30 |
| `parity/posh009-coverage-gate-green.json` | POSH-009 coverage gate GREEN run receipt (`scripts/posh_coverage.py` exit 0) | 2026-10-30 |
| `parity/posh009-coverage-gate-flip.json` | POSH-009 coverage gate non-vacuity flip receipt (gate flips on a real mutation) | 2026-10-30 |
| `mutation/turnstile-flip.json` | Turnstile non-vacuity mutation court receipt (flip witnessed) | 2026-10-30 |
| `wave2-membrane-receipt.json` | Wave-2 membrane work-order receipt (identity/authority/consequence fields; work_order_id POSH-002-class) | 2026-10-30 |
| `dflss_audit_receipt.json` | DMADV window audit receipt: git SHA `35bd36d0…`, timestamp 2026-10-30T12:05:00-07:00, lane + CGO fields | 2026-10-30 |
| `final-wave-receipt.md` | Lane F17 aggregation receipt: every gate re-run on disk ~12:04–12:10; gate 1 (go test) and gate 5 real failures documented; commit-order plan + PARTIAL verdict | 2026-10-30 |
| `lease-cleanup.md` | Lane F10 lease cleanup across `/Users/sac/smalt` and `/Users/sac/cai/courtroom-platform-az` (build-root lease deletion per fanout cleanup law) | 2026-10-30 |
| `schema_parity_live.md` | Lane F3: schema-parity gate run against a live consumer plan | 2026-10-30 |
