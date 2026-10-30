# Gap 10 — Observability Across the Estate

Status line: **PARTIAL** — instrumentation exists and runs (smalt telemetry/OCEL, posh
andon chain + slog), but nothing aggregates, exports, or correlates it; no SLO is being
measured by a running instrument; receipt durability for the andon chain is ephemeral.

Per-estate status vocabulary: ALIVE = ran this session with a named instrument; PARTIAL =
exists but incomplete; MISSING = nothing exists.

## 1. Inventory

| Estate | Surface | What exists | Status | Evidence |
|---|---|---|---|---|
| smalt | `lib/smalt/telemetry.ex` + `lib/smalt/telemetry/` | `:telemetry` handlers, RollingCounters (wired in `application.ex`, `monitor/metrics.ex`), sealed_log | ALIVE | files on disk; counters referenced from `application.ex`/`store_tables.ex` |
| smalt | `lib/smalt/telemetry/ocel_ndjson.ex`, `ocel_emitter.ex`, `court_ocel.ex`, `affidavit_ocel.ex`, `enclave_ocel.ex` | OCEL NDJSON event emitter per object family | ALIVE | modules exist under `lib/` (compiled by the smalt build) |
| smalt | `docs/jira/posh/v26.10.30/receipts/` + `smalt/tmp/posh/` | receipt dirs incl. `receipts/measure/posh002-latency.json`; court logs in `tmp/posh/` | ALIVE | `receipts/measure/posh002-latency.json` on disk |
| posh (Go) | `internal/andon/` + `cmd/andon/main.go` | andon state machine with hash-chained JSONL receipt chain, default path `tmp/posh/andon.jsonl` (repo-relative, ephemeral) | ALIVE | `cmd/andon/main.go:38` default `-receipts tmp/posh/andon.jsonl` |
| posh (Go) | `internal/logging/logging.go` | structured JSON slog on stderr, `POSH_LOG_LEVEL` | ALIVE | `logging.go:33` `slog.NewJSONHandler(os.Stderr, …)` |
| posh (Go) | `scripts/coverage.py` + `KNOWN_DIVERGENCES.md` | coverage receipts derived from `lib/`-surface inventory | ALIVE | `scripts/coverage.py` on disk |
| posh (Go) | `cmd/posh/main.go` | dev-only pprof; no `/metrics` endpoint, no Prometheus/OTel | PARTIAL | grep for `pprof\|prometheus\|/metrics` hits only `cmd/posh/main.go`; nothing in `internal/server` |
| kind lane | `k8s/kind-config.yaml`, `k8s/smalt-backend.yaml`, `justfile.d/52-kind.just` | cluster + backend StatefulSet + posh UDS sidecar | PARTIAL | gap 03 (`03-kind-vs-aca.md`) already rates orchestration parity PARTIAL |
| kind lane | log aggregation (fluent-bit/loki/OTel collector DaemonSet) | none | MISSING | no collector manifests under `k8s/`; only `kubectl logs` |
| consumer (courtroom-platform-az) | `infra/environments/dev/platform/main.tf` | `azurerm_log_analytics_workspace` + `logs_destination = "log-analytics"` — prod log destination exists | ALIVE (prod) | `main.tf:37,81-82` |
| consumer (local) | local log query/export path | nothing — Log Analytics has no local counterpart | MISSING | no local collector config anywhere in the estate |

## 2. Gaps and close conditions

| # | Gap | Severity | Close condition (falsifiable) |
|---|---|---|---|
| (a) | No log aggregation for the kind cluster: stdout/stderr die with the pod; `kubectl logs` is the only reader; no collector DaemonSet (fluent-bit/Loki/OTel) is deployed | HIGH | A collector DaemonSet runs on kind, log content reaches a queryable store, and killing+restarting the backend pod does not lose the pre-crash log lines (receipt: before/after query results) |
| (b) | andon.jsonl (posh, hash-chained Go receipts) vs smalt OCEL NDJSON are two receipt formats with no correlation field (no shared run-id / case-id / object id mapping) | MEDIUM | One run produces both an andon receipt and OCEL events carrying a shared correlation id; a query over either store resolves the other's records for the same run |
| (c) | posh emits structured slog JSON to stderr but nothing scrapes/exports it; no `/metrics` endpoint (dev pprof only); counters never leave the process | MEDIUM | posh exposes `/metrics` (Prom text or OTel) and a scrape config consumes it; a scraped counter increments under real load and is observable from outside the process |
| (d) | dfcharter `measure.md` defines M1–Mn with named instruments (p99 latency, GC traces, cycles/msg), but only one receipt (`receipts/measure/posh002-latency.json`) exists — the measure phase is on paper, not running | HIGH | Each CTQ metric in `measure.md` has a scheduled instrument run emitting a fresh timestamped receipt under `receipts/measure/`; a metric whose instrument has not run in the current cycle reads UNVERIFIED in any status claim |
| (e) | Receipt durability: andon default path is repo-relative `tmp/posh/andon.jsonl`; `make clean`/lane cleanup wipes `tmp/`; receipts do not survive a clean checkout | HIGH | Receipt chain default path moves to a durable location (or an explicit `-receipts` is always passed by the runner recipe); falsifier: run andon → `make clean` → read the chain back and verify the hash chain still verifies, exit 0 |

## 3. Notes

- Gap (e) is the sharpest: `cmd/andon/main.go:38` hard-codes the ephemeral default, and
  `Makefile:54 clean` target removes build artifacts under the repo root — the default
  receipt chain shares the wiped directory tree. One-line fix (durable default or required
  flag) with a non-vacuous court: delete-then-verify chain still replays.
- Gap (a) is scoped by gap 03 (`03-kind-vs-aca.md`), which already rates log parity NONE;
  this lane records the missing collector, not the parity table.
- Prod is the only estate with a real log destination (Log Analytics via
  `logs_destination = "log-analytics"`, `main.tf:81-82`); local dev has no counterpart, so
  local observability is `kubectl logs` + manual `tail` of `tmp/posh/` files.
