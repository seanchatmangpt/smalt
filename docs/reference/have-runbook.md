# HAVE Runbook (smalt adaptation)

High-Assurance Verification Engine — Level-1 supervisory layer, adapted to
smalt paths and the current landing state. Every path and command below is
grounded against the repo; each procedure is marked `AUTOMATED` (a script
in `scripts/have/` does the work) or `MANUAL` (operator). The ledger state
lives in `tmp/have/` (gitignored; `.gitignore` line 116).

## 1. Architecture

Three tiers:

```
+------------------------------------------------------------------+
| TIER 1 — SUPERVISORY (cron, 5m)                                  |
|   scripts/have/pool_saturation_guard.py per cycle:               |
|     count workers -> compare N vs target N=20 -> typed alert     |
|     row + dispatch request -> touch heartbeat                    |
|   Reads:    pgrep -f 'mix test|docker'                           |
|   Writes:   tmp/have/state_ledger.jsonl (alert rows),            |
|             tmp/have/dispatch_requests.jsonl,                    |
|             tmp/have/heartbeat.json                              |
+------------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------------+
| TIER 2 — CONTROL (state + procedures)                            |
|   scripts/have/state_ledger.py: atomic-append JSONL ledger,      |
|   RP-01 sanitizer, heartbeat touch/age. Alert classes SEV1-SEV4  |
|   (section 4). Recipes: justfile.d/31-have.just.                 |
|   Writes:   tmp/have/run_state.jsonl,                            |
|             tmp/have/have_l1.heartbeat,                          |
|             tmp/have/quarantine/*.tar.gz                         |
+------------------------------------------------------------------+
                              |
                              v
+------------------------------------------------------------------+
| TIER 3 — WORKERS                                                 |
|   The smalt worker fleet: distinct lines of                      |
|     pgrep -f 'mix test|docker'                                   |
|   (mix test runs, docker burn jobs, SDK smoke harnesses).        |
|   Target pool N=20.                                              |
+------------------------------------------------------------------+
```

Tier boundary is typed: the supervisory tier cannot spawn workers — it
appends a `dispatch_request` row and the 5m cron loop is the actuator.
The guard counts process lines; it reads nothing else about workers.

## 2. Operational invariants

| Invariant | Value | Grounding |
|---|---|---|
| Target pool | N=20 (`DEFAULT_TARGET_POOL = 20`) | `scripts/have/pool_saturation_guard.py` |
| Guard cycle | 5 min (`just have-cycle`) | `justfile.d/31-have.just` |
| Sustain window | last 2 heartbeat samples both < 15 | `SEV2_SUSTAINED_THRESHOLD = 15`, `SUSTAIN_WINDOW = 2` |
| Heartbeat TTL | stale when age > 10 min (2 cycles) | `state_ledger.py heartbeat_age/1`; TTL = 2x the 5m cycle |
| State conservation | per-place token drift `produced - consumed - final_marking` must be 0 (RP-04) | `scripts/have/petri_conformance.py` docstring |
| Ledger kinds closed | kind in `heartbeat\|dispatch\|receipt\|alert`, anything else refused | `KINDS` tuple, `state_ledger.py` |
| Zero sleeps | deadlines are timestamp arithmetic, never wall-clock waits | `pool_saturation_guard.py` module docstring |

## 3. have_* telemetry catalog

Only rows the landed scripts actually emit; thresholds as receipted in
`docs/jira/v26.10.18/receipts/have-2-pool-guard.md`.

| Telemetry | Emitter | Payload | Trigger / threshold | Standing |
|---|---|---|---|---|
| `have_worker_fleet_active_count` (alert) | `pool_saturation_guard.py` | `deficit`, `severity`, `sustained`, `target_pool`, `workers`, `ts` | N < 20; SEV2 iff this and previous sample both < 15 | ALIVE (receipted) |
| `have_worker_fleet_active_count` (dispatch) | `pool_saturation_guard.py` | `kind: dispatch_request`, `deficit`, `requested_by`, `severity`, `target_pool`, `workers`, `ts` | appended whenever N < 20 | ALIVE (receipted) |
| heartbeat | guard + `just have-heartbeat` | `heartbeat.json` (ts/epoch/workers/status); `have_l1.heartbeat` (epoch float) | touched every 5m cycle | ALIVE (receipted) |
| `ALRT-SEV1-PETRI-TOKEN-IMBALANCE` | `petri_conformance.py` | names the exact broken lifecycle link | per-place drift != 0 | LANDED, NOT RUNNABLE (RP-04 note) |

Do not mint new `have_*` names unilaterally — same discipline as GAP
tokens: a new name needs a landing receipt.

## 4. Alert classification

| Sev | Meaning | Grounded example | Response |
|---|---|---|---|
| SEV1 | verification itself is broken | `pgrep` counter failure typed `-1` (never read as 0 workers); `ALRT-SEV1-PETRI-TOKEN-IMBALANCE` | immediate operator action; RP-03/RP-04 |
| SEV2 | sustained deficit (< 15 on this and previous sample) | receipt live run 2: SEV3→SEV2 flip on real state (workers=6) | RP-02 |
| SEV3 | first-observation deficit, unproven duration | receipt live run 1 (workers=6, SEV3) | observe next cycle; escalate if sustained |
| SEV4 | midband 15-19: below target, above sustained threshold | `midband-sev4` self-check fixture | no action; trend only |

## 5. Procedures RP-01..RP-04

### RP-01 — State-ledger recovery — AUTOMATED

The ledger appends atomically (tmp file + POSIX `os.replace` rename in
`state_ledger.py`), so a crash mid-append cannot expose a partial record
under the ledger path. Belt-and-suspenders: the RP-01 step-3 sanitizer
truncates trailing half-written JSONL lines and reports the retained count.

```bash
just have-sanitize
# -> retained=N dropped=M
just have-read
# -> JSON, one entry per line of tmp/have/run_state.jsonl
```

### RP-02 — Pool deficit response — AUTOMATED arm + MANUAL tail

Automated arm (already done by the guard before an operator looks):

1. Typed alert row + dispatch request appended; heartbeat touched.
   Run/inspect with `just have-cycle`.

Manual tail (no script exists — honest boundary: the guard cannot spawn
Claude agents, it requests; the cron loop is the actuator):

1. Confirm the deficit row: `just have-read` or
   `tail tmp/have/dispatch_requests.jsonl` (read `deficit`, `severity`).
2. Dispatch workers up to N=20 by the fleet mechanism of the day. MANUAL.
3. Next `just have-cycle` must flip status OK with no new dispatch row
   (falsifier: `no-dispatch-on-recovery` self-check fixture).

### RP-02b — Stale heartbeat (L1 down) — MANUAL

`have_l1.heartbeat` older than 10 minutes (2 cycles) means the supervisory
tier itself is down. The guard cannot observe its own death, so this check
is MANUAL by construction — an external clock, not the guard:

```bash
just have-heartbeat
# -> heartbeat age=N.NNNs ; age > 600s = L1 down, proceed to RP-02 manual tail
```

### RP-03 — Quarantine + forensic snapshot — steps 1-2 AUTOMATED, step 3 MANUAL

The quarantine arm has run for real: `tmp/have/quarantine/` holds bundles
(`corrupt_state_20261019T043*.tar.gz`) and `tmp/have/fixture/{clean,corrupt,torn}`
back the ledger tests (`tmp/have/test_state_ledger.py`). On a corrupted
ledger:

1. Snapshot the corrupted ledger into quarantine:

   ```bash
   tar -czf tmp/have/quarantine/corrupt_state_$(date -u +%Y%m%dT%H%M%S).tar.gz \
     tmp/have/state_ledger.jsonl
   ```

2. Run the sanitizer: `just have-sanitize` (RP-01).
3. Confirm the retained count against the last known-good state. MANUAL.

### RP-04 — Formal conformance (Petri token balance) — AUTOMATED (IN-FLIGHT)

Contract (docstring of `scripts/have/petri_conformance.py`): replay an
OCEL 2.0 log (as emitted by `scripts/burn_to_ocel2.py`) against the
settlement lifecycle net
`arm.resource.transition -> amqp.delivery.settled -> blob.custody.transition`;
compute per-place drift = produced - consumed - final marking; drift != 0
emits `ALRT-SEV1-PETRI-TOKEN-IMBALANCE`.

```bash
python3 scripts/have/petri_conformance.py <log.ocel.json> \
  --net scripts/have/petri_net.json --quarantine --mint-adr --quiet
# exit 0 conformant / 1 imbalance or regression / 2 usage-IO
```

Imbalance classification:

- REGRESSION: event type IS declared in the net (an existing lifecycle
  link broke) -> `--quarantine` writes `tmp/have/QUARANTINE`, exit 1.
- PROTOCOL-UPDATE: event type the net does not declare (the process
  changed) -> `--mint-adr` writes an ADR under
  `docs/jira/v26.10.18/decisions/`.

**Honest landing note**: `scripts/have/petri_net.json` is not on disk and
the script is mid-write (truncated `_final_marking`); RP-04 is NOT yet
runnable. Until the net lands, conformance is MANUAL (read the OCEL log
against the lifecycle by hand). Do not cite the docstring as automation.

## 6. Watchdog crontab templates

The 5m guard cycle as cron (script exits 0 even on deficit — the alert row
is the signal; never let cron mail-storm on the deficit path):

```cron
# HAVE L1 pool-saturation guard, every 5 minutes (repo: /Users/sac/smalt)
*/5 * * * * cd /Users/sac/smalt && python3 scripts/have/pool_saturation_guard.py >> tmp/have/cron.log 2>&1
```

Equivalent `just` form:

```cron
*/5 * * * * cd /Users/sac/smalt && just have-cycle >> tmp/have/cron.log 2>&1
```

Optional external watchdog (RP-02b): a second, independent entry that
detects the first watchdog's own heartbeat going stale — the guard cannot
observe its own death, so the external timer is the only detector:

```cron
# L1-down detector, hourly; fires only when the heartbeat is stale > 10 min
15 * * * * test $(cd /Users/sac/smalt && python3 -c "import time,pathlib;hb=pathlib.Path('tmp/have/have_l1.heartbeat');print(0 if not hb.exists() else time.time()-float(hb.read_text().strip()))") -lt 600 || echo "HAVE L1 DOWN: heartbeat stale > 600s" | mail -s "SEV1 HAVE-L1-DOWN" "$USER"
```

`tmp/have/cron.log` is scratch (under the gitignored `tmp/have/`), not an
indexed receipt.

## 7. Triage quick-reference

```
alert row?
├─ type=have_worker_fleet_active_count
│   ├─ severity=SEV1  -> counter fail: check pgrep availability, run RP-01
│   ├─ severity=SEV2  -> sustained deficit (<15 x2): RP-02 (dispatch workers)
│   ├─ severity=SEV3  -> first observation: watch next cycle, RP-02 if sustained
│   └─ severity=SEV4  -> midband 15-19: trend only
├─ type=ALRT-SEV1-PETRI-TOKEN-IMBALANCE
│   ├─ REGRESSION (type in net)        -> RP-04 --quarantine, exit 1
│   └─ PROTOCOL-UPDATE (type unknown)  -> RP-04 --mint-adr (decision record)
├─ no rows for > 2 cycles?
│   └─ heartbeat age > 600s            -> L1 down (RP-02b), external watchdog fires
└─ ledger unreadable / torn lines?
    └─ quarantine snapshot (RP-03), then RP-01 sanitize
```

## See Also

- `docs/jira/v26.10.18/receipts/have-2-pool-guard.md` — receipted
  thresholds and live SEV3→SEV2 witness
- `scripts/have/pool_saturation_guard.py`, `scripts/have/state_ledger.py`,
  `scripts/have/petri_conformance.py`
- `justfile.d/31-have.just` — operator recipes (`just have-*`)
- `tmp/have/test_state_ledger.py` — ledger unit tests + fixtures
