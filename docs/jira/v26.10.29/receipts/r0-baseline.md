# r0 — Baseline validation (pre-implementation)

- window: v26.10.29 · date: 2026-10-29 · subject: smalt @ 35bd36d0 (dirty:
  graphlaw admission_gate.ex + namespace_put_test.exs + 2 untracked test
  files — another lane's in-flight work, untouched by this window)
- standing: **PARTIAL_ALIVE — baseline court RED, failures pre-existing**

## Tiers run (driver: /tmp/smalt-validate/baseline.sh)

| tier | rc | result |
|---|---|---|
| quiet-check | 1 | REFUSE: load 25.5/23.8 > 16-cpu threshold (this validation's own parallel lanes contributed) |
| doctor | 0 | PASS |
| test-offline (`just test-offline`) | 2 | **1274/1417 passed, 8 skipped, 12 excluded, 143 failed** (525.6s) |
| integration (`mix test test/integration`, _build-baseline) | 2 | **565/671 passed, 7 skipped, 12 excluded, 106 failed** |
| status | 0 | report-only PASS |

## Failure shape (triage level: census)

Failures span AMQP wire, blob-face, KV, terraform-export, MCP tools — broad,
not isolated to the dirty files' domains (graphlaw/namespace). Cross-checked
against README's documented court-x2 shifting-failure flake family + the
loaded host — subset likely environmental; subset real. NOT triaged to root
cause this window: the 249-line failure ledger is preserved at
/tmp/smalt-validate/{test-offline,integration}.log for a dedicated lane.

## Consumer lane (courtroom-platform-az @ 338caed)

npm ci failed on BOTH machine-default node v26 (engines `>=22 <25`,
engine-strict) and nvm default v20 (repo .nvmrc pins 20 — contradicts its own
engines). Node 22.23.4 provisioned via nvm; consumer court re-runs under it
(T03).
