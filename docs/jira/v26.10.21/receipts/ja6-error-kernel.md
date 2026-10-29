# JA-6: Smalt Error Kernel — Classification & Blast Radius

**Standing:** **PARTIAL PASS — kernel is real, held, and tested, but not minimal.**
Repo: `/Users/sac/smalt`, branch `main` · Context: solo

## 1. Kernel classification

| Component | File | Kernel class | Why |
|---|---|---|---|
| `Smalt.Application.start/2` | `lib/smalt/application.ex` | **KERNEL** | boot path; `= :ok` match on `SasVerifier.validate_boot_key!/0` and strict `bind_ip/0` raise = fail-closed boot, zero swallowing |
| `Smalt.Supervisor` (root) | same file, line 43 | **KERNEL** | `:one_for_one` root; only the four planes + 3 shared infra children + optional tails |
| `Smalt.Plane.DataSupervisor` | `lib/smalt/plane/data_supervisor.ex` | **KERNEL ROOT** | owns `Smalt.Store` — the single durable-state owner |
| `Smalt.Store` | `lib/smalt/store.ex` | **KERNEL, INNERMOST** | every ARM/Cosmos/KV/queue path reads its named ETS tables; tables die with the GenServer |
| `Smalt.Telemetry.RollingCounters` | `lib/smalt/telemetry.ex:186` | **KERNEL-adjacent (accepted soft)** | shared counter substrate on the root supervisor |
| `Smalt.Monitor.Metrics` | `lib/smalt/monitor/metrics.ex` | **KERNEL-adjacent (hardened)** | ETS with `:heir` — table survives its own death |
| 4 plane supervisors | `lib/smalt/plane/*_supervisor.ex` | **KERNEL ROOTS** | partition fault domains; `max_restarts: 5 / 5s` each |
| `Smalt.Apim` | `lib/smalt/apim.ex` | **EDGE, not kernel** | rate-limit pre-filter; degrades independently |

Not kernel: `ArmGateway.Router`, `EgressRouter`, `AmqpBroker`, `WasmEngine` — big workers, correct per the axiom.

## 2. Zero-defensive-programming invariant

**HELD — no unconditional swallowing found.** Every `try/rescue` in kernel code is typed to `ArgumentError` with a documented law:

- `store.ex` — **zero** try/rescue. The dangerous calls (`compare_and_swap/4`, `insert_new/3`, `next_seq/3`) validate the table in the **caller** and raise, with an explicit comment: crash the caller, not the shared Store GenServer (store.ex:217-226). Textbook error kernel.
- `telemetry.ex:216-234, 311-329` — log-and-drop post-boot only; **re-raises** pre-boot as a "boot-order violation". The boot/post-boot line is a `:persistent_term` marker. This is not defensive swallowing; it is a typed partition between fail-fast and fail-open.
- `monitor/metrics.ex:206, 240, 279` — same law; `merge/2` drift documented as bounded and self-correcting.
- `planes.ex:66` — `String.to_atom` fallback (atom-creation, not error swallowing).
- `apim.ex:126` — `:ets.new` race guard (raise vs. retry, not swallow).

## 3. Minimality verdict: **NOT MINIMAL, by a bounded amount**

Violations of "small kernel, big workers":

1. **`Smalt.Store` is a single process on the hot path of every data-plane write.** `insert_new`, `compare_and_swap`, `cas_delete`, `next_seq` all funnel through one `GenServer.call` (`@call_timeout 5_000`). A Store crash kills **all** named tables → every ARM/Cosmos/SB write fails for the restart window. This is the largest blast radius in the system, and it sits at the innermost kernel position.
2. **`RollingCounters` owns its table with no `:heir`.** Its death deletes `:smalt_rolling_counters` mid-prune-gap; counters during the gap are log-and-drop (documented loss, `telemetry.ex:216`). `Monitor.Metrics` solved this exact problem with a 3-tuple `:heir` (metrics.ex init) — RollingCounters did not.
3. **Integration plane's lazy store guard** (`integration_supervisor.ex:28`, `Process.whereis(Smalt.Store) == nil`) is decided at supervision **init** time only — it is a boot-shape decision, not runtime healing.

Mitigating: the plane partition (`AZB-09`), bounded `shutdown: 10_000` on all Bandit listeners (`AZB-22b`), and caller-side fail-closed table guards keep the kernel *shallow*, even though its innermost member is hot.

## 4. Court / census — blast-radius table

Real kills exist: `/Users/sac/smalt/test/internal/plane_blast_radius_test.exs` (Chicago discipline: real `Supervisor.terminate_child`/`restart_child`, real sockets, no mocks).

| Killed (real exit) | Recovers | Cascades | Evidence |
|---|---|---|---|
| Egress Bandit listener (Data) | `Supervisor.restart_child` seam; sibling `Store` pid **identical** during outage; ARM port still answers | none outside child | plane_blast_radius_test.exs:79-99 |
| `Smalt.AmqpBroker` (Integration) | restart seam + port rebind (bounded poll ≤10s); `Store` untouched; egress port serves during outage | AMQP 5672 down for the window | :102-138 |
| **`Smalt.Store` via DataSupervisor** | **NOT auto-healed** — stays down until the owner's restart seam; fresh pid + full table re-materialization on restart | **every data-plane write (CAS/insert_new/next_seq) fails; ARM writes 500; SB queues ETS.lookup raises** | :141-179 |
| `RollingCounters` | root supervisor restarts it; `init/1` recreates the table; bumps during the gap log-and-drop | counter undercount only | telemetry.ex law comments |
| `Monitor.Metrics` | restart; table survives via `:heir` | none — worst case one drift sample | metrics.ex init comment |
| Boot-time config defect | **nothing** — `raise` at `Application.start/2` | whole node refuses to boot (intended fail-closed) | application.ex:34, 169-195 |

## Standing

- **Kernel existence**: CONFIRMED, cleanly layered (boot refuse → root → planes → Store).
- **Invariant**: HELD — all swallowing is typed, boot-gated, and commented with law + witness receipts (lc1, AZB-17, R157, A32).
- **Minimality**: NOT MET strictly. `Smalt.Store`'s process-funnel position and `RollingCounters`' missing `:heir` are the two concrete deviations from the OTP axiom; the Store blast radius is empirically demonstrated (not speculated) by the AZB-17 test row.
- **Gap**: no kill test exists for `RollingCounters`/`Monitor.Metrics` themselves — the blast-radius table's last two rows are code-derived, not court-proven. Recommended JA follow-up: add those two kills to `plane_blast_radius_test.exs`, and consider `:heir` parity for the counters table.

## Re-witness (BK-28, 2026-10-21)

Re-derived from the CURRENT tree.

```
$ grep -n 'heir' lib/smalt/telemetry.ex lib/smalt/monitor/metrics.ex
lib/smalt/monitor/metrics.ex:300:  # 3-tuple :heir form (keyword form raises ArgumentError) — table survives
lib/smalt/monitor/metrics.ex:307:        {:heir, Process.whereis(:init), []}
# (no telemetry.ex hit — RollingCounters table STILL has no :heir)
$ ls -la test/internal/plane_blast_radius_test.exs
-rw-r--r--@ 1 sac  staff  8986 Oct 19 09:57 test/internal/plane_blast_radius_test.exs
$ sed -n '62,74p' lib/smalt/store.ex   # NEW since the original audit: TTV-4 boot replay
    # TTV-4: replay-then-listen. With :journal_sink_dir unset (default) this
    # is a no-op; when set, every SEALED journal segment is replayed BEFORE
    # the GenServer finishes init, so no request can observe a half-replayed
    # table set. A replay failure refuses boot ({:stop, {:journal_replay_failed, reason}}).
```

- **Kernel classification — HELD, unchanged** (boot refuse → root → 4 planes → Store; all still
  present on the current tree).
- **Deviation #1 (Store hot-path funnel) — STILL OPEN**: store.ex:376 still documents
  "named ETS tables die with it; a restart loses data" for the non-journal path.
- **Deviation #2 (RollingCounters missing `:heir`) — STILL OPEN**: telemetry.ex has zero `heir`
  hits; `Monitor.Metrics` keeps its 3-tuple `:heir` (metrics.ex:300-307). JA-R2's heir fix went
  to the Apim rate table (ja-r2-apim-atom-bridge-fixes.md), not the counters table.
- **Minimality gap on kill-tests — PARTIALLY IMPROVED**: `plane_blast_radius_test.exs` remains
  (Oct 19), and TTV-4 boot journal replay (store.ex:79-121, `replay_sealed/1` + `boot_replay/1`
  in `init`, refuse-boot-on-replay-failure) materially shrinks the Store cold-restart blast
  radius the original table called "NOT auto-healed" — the journal leg of recovery is now wired.
- Standing update: **PARTIAL PASS — kernel real and tested; Store funnel + RollingCounters `:heir`
  gaps remain; journal-replay leg of Store recovery landed (TTV-4) since the original audit.**
