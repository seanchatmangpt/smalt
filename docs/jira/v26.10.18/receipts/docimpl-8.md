# docimpl-8 — TEST_ISOLATION.md ground-truth rewrite (d6 findings)
Context: solo(docs-audit d6 ground-truth greps + just docs-dod-check exit 0; no mix test invocation)

Date: 2026-10-18 · Lane: docs-audit D6 implement · No git (per dispatch)
Subject: `/Users/sac/smalt` @ main, HEAD 6681746 + in-flight tree

## What changed

`docs/TEST_ISOLATION.md` rewritten to ground truth per
`docs/jira/v26.10.18/docs-audit/d6-generated.md`:

1. **async:true inventory re-derived at HEAD** — now 16 files (was 11).
   Six new: `assert_eventually`, `defaults`, `enclave_hcl`,
   `fin_ops_calculator`, `provider_matrix`, `stress_tier_census`.
   `test/amqp/management_rpc_test.exs` left the inventory — now
   `async: false` ×2 (`use ExUnit.Case` :8, :585 module), F13 citation
   `docs/jira/v26.10.17/receipts/i21d-store-clear-async.md` (witnessed DLQ
   corruption under shuffle from shared sb-table wipes). The "no
   async:true module touches the Store" claim re-verified per-file:
   `grep -c "Store\\."` → 0 in all 16 (single `smalt_graphlaw_matrix`
   hit is its own in-file comment at :148).
2. **Store.clear inventory re-derived** — `grep -rn "Store\.clear" test/`
   = 39 files / 53 call sites, + 2 lib sites
   (`lib/smalt/enclave/doctor.ex:277`, `:292`). 53 sites = 37 `.exs`
   modules + 2 `test/support` helpers (`store_resilient.ex`,
   `wire_helpers.ex`). All 37 modules named in the doc; all clearing
   modules are `async: false`.
3. **New §6 Isolation court (AZB-11)** — static + runtime twin
   (`scripts/isolation_court.py`, `just isolation-court` /
   `isolation-court-runtime`), env-restore + start_link rules,
   fail-closed fixtures/self-check, runtime exemption registry
   (`test/support/isolation_runtime_exemptions.exs`, 14 patterns,
   name-deltas only — env leaks never exemptable).
4. **New §7 SleepWindows** — `SmaltTest.SleepWindows`
   (`test/support/sleep_windows.ex`), six named B1 time-advance windows,
   no-sleep-doctrine Law-1 exception, 6 consumer files listed. The
   `:stress` tier row was already present in the §3 tag table (landed
   with the stress tier; left intact).

## Verification (real output, this session)

Static isolation court (doc §6 claims vs behavior):

```
== isolation court (AZB-11) ==
scanned 166 test module files
PASS fixture:clean-put_restored (expected PASS, scanner PASS)
PASS fixture:bare-put_env (expected REFUSE, scanner REFUSE); 5 env mutation `smalt.:probe_key` (no save of prev value)
PASS fixture:named-start_link (expected REFUSE, scanner REFUSE); 5 start_link in test body must be start_supervised!/1 (Agent.start_link(fn -> :ok end, name: :iso_court_leaked_name)
PASS fixture:exempt-honored (expected PASS, scanner PASS)
-- OFFENDERS: none --
verdict=PASS static=GREEN fixtures=REFUSED-OK elapsed=2.04s   # exit 0
```

Anti-vacuity self-check (`isolation_court.py --self-check`, exit 0):

```
PASS self-check/bare.exs -> REFUSE [(5, 'env mutation `smalt.:probe_key` (no save of prev value)')]
PASS self-check/bare_exempt.exs -> PASS []
self-check verdict=PASS
```

Docs DoD gate:

```
just docs-dod-check   → 51 × "OK ..." lines, exit 0
```

## Inventory derivation commands (replay)

```
grep -rln "async: true" test/ --include='*.exs' | sort        # 16 files
grep -rn "Store\.clear" test/ | wc -l                          # 53 sites
grep -rl  "Store\.clear" test/ | wc -l                         # 39 files
grep -rn "Store\.clear" lib/                                   # doctor.ex:277,:292
```

## Standing

ALIVE for the doc-rewrite scope. Notes:

- `gates/test_isolation_leak_gate.py` exits 1 (17 files / 39 uncovered
  mutations) — PRE-EXISTING, not touched by this docs-only session; the
  doc does not claim the leak gate is green. The stricter isolation
  court (`just isolation-court`) is GREEN over the same tree.
- `docs/jira/v26.10.18/RECEIPTS.md` is generated — this receipt joins it
  via the next `just receipt-index` run.
