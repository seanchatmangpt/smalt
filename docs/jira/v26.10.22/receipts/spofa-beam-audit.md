# SPOF-A: BEAM Adversarial Zero-Mercy Audit — v26.10.22

**Standing:** PARTIAL_ALIVE (audit receipt; every finding carries a falsification court, none executed — read-only audit)
Repo: `/Users/sac/smalt` · branch `main` · Context: solo · Vectors 1, 2, 5 of the operator falsification audit
Method: full-corpus grep sweeps (`ets.new`, `heir`, `trap_exit`, `to_atom`, retry/backoff), targeted Read of every hit, start-site tracing to supervision tree. No code edits, no commits.

## CLOSED rows (known sites, verified landed on current tree — one line each, not findings)

- CLOSED (JA-R2 receipt): `Smalt.Apim` naked `spawn_link` owner → proper GenServer + `{:heir, :init}` rate table (apim.ex:46-67, 159).
- CLOSED (BK-57/ja-r3 receipt): `cosmos_sql.ex` wire-sourced atom minting (JA16-D1) — keyword binary match + `String.to_existing_atom` gated on the compile-time keyword set (cosmos_sql.ex ~766, law comment in place).
- CLOSED (TTV-5): every named `Smalt.Store` table `{:heir, :init}` + adoption path (store.ex:94-115); "tables die with Store" comment superseded in-code (store.ex:419).
- CLOSED (JA-6 re-witness → current tree): `RollingCounters` `{:heir, :init, []}` 3-tuple (telemetry.ex:289).
- CLOSED (since JA-1 #2): amqp10 settled-ledger holder is now `Smalt.Amqp10.Ledger` GenServer, `{:heir, :init, []}`, adopt-on-existing (amqp10_ledger.ex:64-80); `Amqp10.Connection` calls `Ledger.ensure()` (amqp10_connection.ex:232). Data-loss leg closed; see A-8 for the residual linkage note.
- CLOSED (JA-16 D2/D3 → JA-R1/R3): x_arr_cert silent `[]` and eh_throttle silent quota fallback — typed-site fixes landed; not re-derived.
- CLOSED: `Monitor.Metrics` unbounded-growth suspicion — prune tick exists (metrics.ex:332); `ActivityLog` 5k ring, `AppInsights` 10k ring — capped.
- CLOSED: `Monitor.Metrics` restart delete-recreate (`:ets.delete(@table)` at metrics.ex:309) — documented BK-33 warm-restart law, not a defect.

## Findings (ranked by blast radius)

### A-1 · HIGH · JournalSink crash loop takes the whole node down

**SPOF Identifier**: `Smalt.Storage.JournalSink` as a default-:permanent child of root `Smalt.Supervisor` (application.ex:50-55, `journal_sink_child/0`), whose entire failure surface is `File.mkdir_p!/1` / `File.open!` raises in `init/1` and `handle_continue(:open_segment, …)` (journal_sink.ex:152-172, 237-242) — plus `File.rename!`/`File.write!` in `seal/1`.

**Failure Classification**: Single-writer disk SPOF + supervision-intensity blast-radius inversion (a child whose restart cannot succeed restarts until the root's 3-in-5s intensity budget is spent, killing all four planes).

**Failure Scenario (mechanical)**: (1) Disk full, permission change, or read-only volume under `:journal_sink_dir` AFTER a successful boot (e.g. volume unmounted, disk-full mid-run). (2) `sync_tick` or the next `seal/1` hits `File.rename!`/`File.open!` raise inside the GenServer. (3) Root supervisor restarts it; `handle_continue(:open_segment)` raises again <5s later. (4) 3 failures in 5s → `Smalt.Supervisor` gives up → Application master stops → **whole node exits**; every plane (control 9443, TLS twin 9444, data 8443, AMQP 5672/5673, MCP  JA-1 census) dies for a disk-error-class fault. (5) Reboot loops the same crash loop.

**Blast Radius**: Total — every protocol on every plane, for a single-sink disk fault. Worst finding in this audit.

**Armstrong Decomposition Patch**: (a) Make JournalSink a `restart: :transient` child with typed `{:error, _}` init instead of raise; ( move the sink OUT of the root supervisor into its own supervisor (or DataSupervisor) with `max_restarts: 10/1s` so sink churn is contained; (c) on write error, degrade to log-and-drop (the established telemetry law, telemetry.ex:216) and retry `open_segment` on `send_after` backoff — journal is an observability/durability adjunct, not the request path. Never let a log sink's restart budget be paid for by the AMQP plane.

**Falsification Court (kill-test)**: Boot with `journal_sink_dir` on a tmpdir; chmod 000 the dir; send one append via the OcelEmitter path; assert (1) request planes still answer (ARM 200 + AMQP attach) after 3 sink restarts, (2) `Process.whereis(Smalt.Storage.JournalSink)` state is typed-degraded, not crash-looping, (3) repair the dir → sink resumes and `:status` shows frames flowing, (4) mutation: revert patch (make the child permanent + raising init) → same kill must take the node down → court is non-vacuous.

---

### A-2 · HIGH · EventHubs EHServer: first-caller-linked singleton with heir-less checkpoint/partition tables

**SPOF Identifier**: `Smalt.Messaging.EventHubs.Server` (nested in event_hubs.ex) — lazy-started singleton; its three tables `@partitions/@checkpoints/@cgs` created in `do_ensure_tables` (event_hubs.ex:699-712) with **no `:heir`**.

**Failure Classification**: Lazy-start silent-disarm (KD-117 heir class) + mailbox-serialization choke on the EH data path.

**Choke note**: every EH op (`next_seq`, `send_event`, `cas_claim`, `reserve`, `cg_*` — event_hubs.ex:70-538) funnels through one GenServer mailbox — this is the facade-era Store funnel shape JA-6 flagged, on a second protocol.

**Failure Scenario**: (1) First EH client call lazy-starts EHServer **linked to the client request process**. (2) That client (a Bandit request task or an Amqp.Connection) exits mid-flight. (3) EHServer dies with it → all three tables deleted → partition seq state, consumer-group checkpoints, and `cg_*` definitions vanish silently. (4) Next caller's `ensure_tables` recreates EMPTY tables: consumers re-read from the default checkpoint position → duplicate delivery or replay flood; per-partition sequence numbers reset → client-visible seq regressions. Silent — no log, no typed refusal.

**Blast Radius**: All Event Hubs ingress (5673 protocol): seq/checkpoint state loss, duplicate delivery, silent.

**Armstrong Decomposition Patch**: `{:heir, Process.whereis(:init), []}` on all three tables (shadow-table law, ~40 lines of precedent across data_plane/*); convert lazy start to a supervised child of IntegrationSupervisor (EventGrid family pattern with disclosed child_specs), or at minimum `Handle` unlink via `:erlang.disconnect_node`-free idiom: start via `ProcLib` + supervisor handoff.

**Falsification Court**: Real EH ingress flow: publish 5 events (seq 1-5), `GenServer.stop(EHServer, :kill)`, assert via a real client that (1) next publish gets seq 6 (state survived), (2) consumer-group checkpoint position preserved, (3) mutation: strip the heir opts → same kill must drop seq back to 1 → non-vacuous.

---

### A-3 · MED-HIGH · `.seal` protocol crash window permanently wedges boot replay

**SPOF-identifier**: `Smalt.Storage.JournalSink.seal/1` — order is `fsync → File.rename!(open→sealed/) → meta.json → .seal sentinel LAST` (journal_sink.ex:253-277).

**Failure Classification**: Single-writer disk: crash-window wedge via fail-closed reader.

**Failure Scenario**: (1) `File.rename!` lands the segment in `sealed/`. (2) Node dies (kill -9, power) before `File.write!(… .seal)`. (3) On next boot, `JournalReader.discover_sealed_segments` globs `sealed/*.journal` — the unsentineled segment IS listed (only `active/` is excluded). (4) `read_sealed_segment` returns `{:not_sealed, path}`. (5) `Store.boot_replay` fail-closed contract treats typed reader refusals as boot refusal → **every subsequent boot refuses with `{:journal_replay_failed, {:not_sealed, …}}`** — a one-instruction crash window converts a survivable crash into a manual-intervention boot wedge (operator must delete/move the segment, losing its frames).

**Blast Radius**: Node unbootable until manual surgery; affects the durability leg (TTV-4) exactly when a crash actually happened.

**Armstrong Decomposition**: Writer-side two-step: sentinel writes into sealed/ as `<seg>.journal.seal-pending` BEFORE the rename (or rename directly to `seg.journal.seal`), so rename-atomicity carries the seal; reader-side: `{:not_sealed}` on a segment whose bytes hash to a manifest-less tail = treat as active-segment remainder → typed SKIP + telemetry + continue, reserving boot refusal for CRC/manifest mismatch (integrity failures vs completeness failures must be distinct refusal types).

**Falsification Court**: (1) Seal a segment, delete its `.seal` file, boot → node boots, segment frames re-journaled or typed-skipped WITH telemetry, CRC-corrupted segment STILL refuses boot. (2) Mutation: revert reader patch → same state must refuse boot → non-vacuous.

---

### A-4 · MED · Lazy-started GenServers owning heir-less data tables (4-module family)

**SPOF Identifier**: Owner-GenServer ETS created with **no heir and lazy/first-caller linkage**:
- `Smalt.Sync.Store` — `:smalt_sync_frames` (sync/store.ex:96-102), lazy `ensure/0` start_link **linked to first caller** (sync/store.ex:34-49).
- `Smalt.Powl2.ServiceBusRuleManager` — `@table` + `@dlq` (powl2/sb_rules.ex:129-130).
- `Smalt.Powl2.ChangeFeed` gen_statem — `:"#{base}_docs"`, `:"#{base}_cdc"` (powl2/change_feed.ex:83-87) — also mints atoms via `:"#{base}_docs"` interpolation from caller-supplied `base`.
- `Smalt.Messaging.EhGeoDr` — `@table` (messaging/eh_geo_dr.ex:144-152) — comment claims "never dies with a mortal caller", but the server itself is mortal (lazy start).

**Failure Classification**: Lazy-start silent-disarm family (KD-117 class), plus atom minting (A-4d).

**Failure Scenario (Sync.Store)**: first `row_count/0` call lazy-starts the server in the caller's process; caller dies → server + `:smalt_sync_frames` deleted → sync court zero-mutation face reads 0 rows — courts read "clean" from a crash, i.e. the zero-mutation assertion face itself is disarmed by a crash.

**Blast radius**: sync frames, SB rule/DLQ state, change-feed docs/CDC, geo-DR config — per-module (protocol-local), silent data loss.

**Armstrong Decomposition**: Same patch as A-2 — heir 3-tuple on every table; move to supervised child specs or document the same-process-lifetime law in-code per the house idiom.

**Falsification Court**: per module: kill the owner mid-traffic, assert data survives + next caller re-adopts; mutation-strip heir → data drops → non-vacuous.

---

### A-5 · MED · pplan receipt atom minting per run_id (unbounded across runs)

**SPOF Identifier**: `Smalt.PPlan.ReceiptEngine.dets_name/1` — `String.to_atom("smalt_pplan_receipt_" <> run_id)` (pplan/receipt_engine.ex:231-235), with an in-code law comment claiming "caller-lifetime bracket". The comment is the defect: **atoms are never GC'd for node lifetime**; the bracket argument is invalid for the atom table. `close/1` closes the dets file but mints nothing back.

**Failure Classification**: Memory/drift — dynamic atom creation (JA-16 D1 class, remaining site).

**Failure Scenario**: Any workload minting unique run_ids (UUIDs per run) grows `:atom_count` monotonically forever. At ~1M atoms default VM limit, a long-lived node running bounded pplan workloads (this is the GraphLaw/pplan receipt path) hits `:system_limit` raise at a random later call — a crash whose cause is minutes-to-months stale. Same wire-reachability: run_id is caller-supplied binary, not validated against a bounded set.

**Blast Radius**: Node-lifetime atom exhaustion → random `:system_limit` crashes on the receipt path; non-recoverable without restart.

**Armstrong Decomposition**: derive the dets name from an existing atom (`String.to_existing_atom` with fallback to a single shared table keyed by run_id inside ONE dets file — duplicate_bag already keys by run_id (`:dets.insert(dets_name(run_id), {run_id, step})`), so per-run dets files are unnecessary — collapse to one file + key.

**Falsification Court**: 50k `open(run_id_i)` calls → assert `:erlang.system_info(:atom_count)` delta ≡ 0 (the ja5 atom-fence shape); mutation: revert → delta ≥ 50k → non-vacuous.

---

### A-6 · LOW-MED · Remaining to_atom sites (bounded, but unfiled)

**SPOF Identifier**: three remaining unguarded `String.to_atom` sites, all currently input-bounded but unfiled against the atom law:
- `powl_bridge.ex:298` — `Map.new(fn {k,v} -> {String.to_atom(k), v} end)` over JSON emitted by the external ex4pm script (`File.read!` + `Jason.decode!`). Script-controlled keys; trusted-execution assumption undisclosed.
- `law_compiler.ex:289` — `ctx_value` `String.to_atom(path)` from the admin-authored shapes file (JA-16 noted "bounded, trusted" — but it is per-path-per-file: a large shapes file still mints per-key).
- `change_feed.ex:84-85` — `:"#{base}_docs"` interpolation (see A-4d).

**Failure Classification**: Memory/drift — dynamic atom creation, remaining sites.

**Failure Scenario**: All require trusted/local input today (external script output, admin shapes file, module opts) — no wire reach. Classified LOW-MED because the codebase law (frame_codec.ex:800) is "never mint atoms from unverified input" and these are unfiled exceptions to it; future wiring (e.g. POWL ingest from the wire) promotes them silently.

**Blast radius**: node-lifetime atom growth, no current wire vector.

**Armstrong Decomposition**: either file each as a documented exception (one `# ATOM-LAW-EXCEPTION: <reason>` marker, sweepable) or convert to `to_existing_atom`/binary-keyed maps (script output doesn't need atom keys at all — `Map.new(fn {k,v} -> {k,v} end)` works for every consumer that just reads values).

**Falsification Court**: recurring gate (ARM-5 shape): every `String.to_atom`/`:"#{…}"` in lib/ must carry an exception marker or use `to_existing_atom`; unlisted = fail-closed refusal.

---

### A-7 · LOW · Wasm.Pool / Cluster still have no supervised start site

**SPOF Identifier**: `Smalt.Wasm.Pool` (pool.ex) and `Smalt.Cluster` (cluster.ex) — no child spec reference in application.ex or any plane supervisor (re-verified by grep: only health.ex/mcp/router.ex READ cluster_status; only bridge.ex references Pool).

**Failure Class**: unsupervised-by-construction (JA-1 #3/#4 carry-over, unchanged since BK-28 re-witness).

**Scenario**: if an embedder enables Cluster or a caller starts the Pool, it lives exactly as long as its starter. Cluster.enabled=true raises at init with no lawful start path.

**Blast Radius**: none today (dead code); latent for embedders.

**Armstrong Decomposition**: either wire child specs into a plane supervisor or delete both modules (ERRC: deletion outranks wiring for zero-consumer code).

**Falsification Court**: if wired: kill-test proves restart; if deleted: grep gate asserts zero references.

---

### A-8 · LOW · amqp10 Ledger ownership churn (closed leg residual)

**SPOF Identifier**: `Smalt.Amqp10.Ledger.ensure()` is called from the first Amqp10.Connection — the GenServer (heir'd table, so data is safe) is linked to that connection process, which is `:temporary` under ConnSup. Owner death → table survives via heir; next connection's `ensure()` re-adopts. Ownership churn is bounded and disclosed (amqp10_ledger.ex:11-25, 80+).

**Classification**: accepted residual, filed for completeness — data-loss leg CLOSED, ownership churn is a documented idiom. No action required; would only become a finding if the ledger owner gains non-heir state.

---

## Trap_exit sweep (vector 1, no findings)

All four live `Process.flag(:trap_exit, true)` sites are owner/pool roles with documented laws: wasm/pool.ex:38 (EXIT-driven respawn, though the pool itself is A-7), affidavit/wasm_engine_supervisor.ex:116 (AZB-22b zombie-ring law), amqp10_connection.ex:81 (connection-scoped containment), store/dets_mirror.ex:229 (JA-11 risk-class comment). No leaf-worker catch-alls masking supervisor crashes found.

## Mailbox choke sweep (vector 1)

- `Smalt.Store` single-process funnel — known JA-6 deviation #1, now explicitly JUDGED in-code (store.ex:81-89: full partitioning not necessary under heir+adoption; partition-kill blast = zero data loss). Carried as an accepted, receipted deviation — one line, not a finding.
- NEW choke of the same shape: **EHServer** (see A-2) — every Event Hubs op serializes through one mailbox with no partition striping. Second-protocol recurrence of the funnel shape.
- `JournalSink` append serializes behind `:file.write` to raw append-mode io (journal_sink.ex:179-194) — bounded per-frame cost, acceptable for a sink; the problem with the sink is A-1/A-3, not throughput.

## Retry loops (vector 5)

All retry/backoff sites are `Process.send_after` backoff with typed caps: cluster.ex (max_retries: 3 bounded budget, exhaustion recorded), event_grid.ex (`validate_retry_policy!` typed {max, ttl} + blob DLQ spill on exhaustion), enclave/doctor.ex (doubling, capped), wasm engine owner (own-mailbox backoff, deliberately off supervisor intensity). **No unbounded retry loop found.**

## Summary

| # | Severity | One-line |
|---|---|---|
| A-1 | HIGH | JournalSink crash loop consumes root supervisor intensity → whole node dies on a disk fault |
| A-2 | HIGH | EHServer lazy first-caller-linked, heir-less checkpoint/seq tables → silent EH state wipe |
| A-3 | MED-HIGH | .seal-after-rename crash window wedges boot replay fail-closed forever |
| A-4 | MED | 4-module lazy no-heir table family (sync_frames, sb_rules, change_feed, eh_geo_dr) |
| A-5 | MED | pplan per-run_id atom minting — atom-table exhaustion on long-lived nodes |
| A-6 | LOW-MED | 3 unfiled to_atom exceptions to the atom law (local-trust inputs) |
| A-7 | LOW | Wasm.Pool/Cluster unsupervised-by-construction (carry-over, dead code) |
| A-8 | LOW | amqp10 Ledger ownership churn — accepted residual, no action |

**Standing:** PARTIAL_ALIVE — 8 findings, 0 falsifier executed (read-only audit; A-1/A-2/A-3 each name a kill-test ready to author). Prior-audit sites verified closed on the current tree: Apim owner, cosmos_sql atoms, Store/RollingCounters/Apim heirs, amqp10 ledger data leg, x_arr_cert/eh_throttle typed fixes.
