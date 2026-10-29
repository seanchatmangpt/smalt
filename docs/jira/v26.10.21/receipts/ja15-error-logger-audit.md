# Receipt: JA-15 — error/Logger doctrine audit + court (Joe Armstrong: log where it happens, debuggable remotely)

Context: solo

**Standing:** **PASS (court 4/4, two consecutive green runs) + audit table with 5 typed gaps (no code changes required to close them — adoption rows, not defects)**

Date: 2026-10-21 · Lane: JA-15 (OTP-29 lane) · Build root: `_build-ja15` ·
Toolchain: OTP 29.1.2 + Elixir 1.20.4-otp-29 (`.tool-versions` pin; ambient shell defaults to
OTP 28 — PATH corrected for every command).
Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(ambient `just bench-machine`; court runs themselves executed on the pinned OTP 29.1.2 toolchain)

## Subject

Audit + court of the substrate's error/Logger posture against the Joe Armstrong doctrine:
errors are logged where they happen, with enough context to debug remotely. Per sampled
crash path the output is typed against 4 fields: process label / exception / stacktrace /
correlation id.

## 1. Census (lib/smalt)

- 53 Logger calls across 20 files: 34 `Logger.warning`, 10 `Logger.error`, 8 `Logger.debug`,
  1 `Logger.info`. Zero `Logger.metadata/1` call sites in `lib/`.
- 11 `Process.set_label/1` sites (IMPL-6/IMPL-26 schema `%{service:, role:, correlation_id:}`
  where context exists). One schema deviation found: `lib/smalt/messaging/amqp10/amqp10_ledger.ex:56`
  labels with a bare tuple `{__MODULE__, :settled_ledger_owner}` instead of the map schema —
  renders fine in crash reports but is not queryable by service/role. Typed gap G1.
- 18 `:telemetry.execute` sites. Crash paths reach telemetry only on the messaging faces
  (event_grid, eh_throttle, eh_capture); cosmos/blob/KV faces do not emit telemetry on
  error paths — typed gap G2 (low: wire errors are typed envelopes).
- No `config :logger` anywhere (config/*.exs, mix.exs, rel/ absent): the substrate rides
  Elixir's default logger pipeline (console handler + Logger.Translator). Labels therefore
  render in crash reports everywhere — mix boot AND release boot (witnessed, §3).
- `with_valid_body`/`safe_dispatch` in `lib/smalt/egress_router.ex:3279/3319` (the
  containment seam whose rescue logs `"egress invalid body on ..."` with request-path
  context) have **zero callers** — the seam is unwired. The contained-error logging it
  promises currently happens only through per-face rescues (blob encode, amqp pump).
  Typed gap G3.
- Wire probe (real HTTP against a real boot, `tmp/ja15_probe.exs`): the cosmos face's
  malformed-document-id 400 and the ledger/garbage 201 paths are **silent** — typed
  envelope on the wire, no site log, no telemetry. Typed gap G4 (refusals are not logged
  where they happen; Joe Armstrong score: correct-but-quiet).

## 2. Court (test/internal/ja15_error_logger_court_test.exs — 4 tests, OTP-29)

`MIX_BUILD_ROOT=_build-ja15 mix test test/internal/ja15_error_logger_court_test.exs` →
`Result: 4 passed` (5.5s), **two consecutive green runs** (tmp/ja15-court17.log, court18.log).

1. **AMQP-10 face, labeled actor crash — 4 fields**: a test-owned real
   `Smalt.Amqp.Listener` (`{:sb, 0, conn_sup: nil}`, real bound socket) is crashed with an
   unknown `GenServer.call` (real FunctionClauseError, unlinked + monitored so the link
   exit does not mask the report). The captured crash report carries:
   `Process Label: %{service: :amqp, role: :listener, correlation_id: :sb}` (fields 1+4),
   `** (FunctionClauseError) no function clause matching in Smalt.Amqp.Listener.handle_call/3`
   (field 2), and the full stacktrace incl. `listener.ex:104` and `gen_server.erl` frames
   (field 3). FULL 4/4.
2. **Label correlation id rides any proc_lib crash**: a Task under a real
   `Task.Supervisor` carries label `%{..., correlation_id: :ja15_request_42}`; its crash
   report renders `correlation_id: :ja15_request_42` + `** (stop) {:ja15_boom, ...}`.
   (The Logger.metadata variant does NOT render under the default formatter — typed gap
   G5 below.)
3. **AMQP pump containment**: real connection over a real socketpair; a wrong 8-byte
   protocol header written from the peer socket produces the site-level
   `[amqp-conn] closing on :bad_protocol_header` warning (contained, typed, connection
   stops normally — never a naked crash). Witnessed via a raw ETS logger handler + the
   internal bounded poll helper.
4. **Hostile formatter**: `Smalt.Ja15.HostileFormatter.format/2` (always raises) is
   installed on the `:default` handler (or a dedicated `logger_std_h` handler when
   `:default` is mid-swap by a neighboring capture_log). Real events + a real crash flow
   through the hostile window: the substrate supervisor stays alive and responsive,
   logger accepts config churn, the hostile formatter is restored, and a post-restore
   event renders. OTP additionally announces every drop loudly — witnessed verbatim in
   court18.log:

   ```
   error: FORMATTER CRASH: {string,<<"ja15 hostile probe 1">>}
   debug: FORMATTER CRASH: {report,[{formatter_crashed,'Elixir.Smalt.Ja15.HostileFormatter'},{config,format},...]}
   Logger - error: {removed_failing_handler,ja15_site}
   ```

   Verdict: the system survives; the event is dropped LOUDLY (per-event FORMATTER CRASH
   notice, then the failing handler is removed by OTP with `{removed_failing_handler, _}`),
   and the pipeline is restorable. PASS, typed DROPPED-LOUDLY.

## 3. Release boot (item 2 of the order)

`mix release smalt` (prod, `_build-ja15`) → boot via `bin/smalt eval` on the pinned
toolchain: boot-tree labels read back intact
(`RELEASE_BOOT_LABEL: {:label, %{service: :amqp, role: :sweeper}}`), and a labeled
`proc_lib` crash in the release VM renders the label through the same Logger pipeline
(no rel/ dir, no custom logger config — the release inherits the default pipeline that
the court proves renders labels). First release build failed boot on the since-fixed
Elixir 1.20.4 `{:local, _}` name rejection (JA-1/JA-4/JA-10's fix landed mid-lane);
rebuild at the fixed tree boots clean. Disclosed: the release snapshot is lane-local and
uncommitted — the witness is of the tree state at run time, not a pinned SHA.

## 4. Four-field completeness table (typed per sampled crash path)

| # | Face / crash path | Process label | Exception | Stacktrace | Correlation id | Verdict |
|---|---|---|---|---|---|---|
| 1 | amqp10: labeled Listener GenServer crash | PRESENT (`role: :listener, correlation_id: :sb`) | PRESENT (FunctionClauseError) | PRESENT (listener.ex:104 + gen_server frames) | PRESENT (rides label) | **4/4 FULL** |
| 2 | any face: Task/proc_lib crash with label | PRESENT | PRESENT (`** (stop)`) | PRESENT | PRESENT (rides label) | **4/4 FULL** |
| 3 | amqp: contained pump fault (bad protocol header) | ABSENT (containment line only) | ABSENT (message only) | ABSENT (no stacktrace) | ABSENT (no id) | 0/4 typed gap G1-class: site log carries the typed reason, not the 4 fields |
| 4 | cosmos: malformed doc id 400 (wire) | ABSENT | ABSENT | ABSENT | ABSENT (envelope only) | silent-but-typed — gap G4 |
| 5 | blob/ledger: garbage body 201/400 (wire) | ABSENT | ABSENT | ABSENT | ABSENT | silent — gap G4 |
| 6 | arm_gateway: Plug.ErrorHandler crash 500 | ABSENT (no label on request procs) | PRESENT (Exception.format kind/reason/stack) | PRESENT | PARTIAL (x-ms-request-id in response header only, not in the log line) | 2/4 — best HTTP-face site log |
| 7 | hostile: crashing formatter | n/a | FORMATTER CRASH notice | n/a | n/a | DROPPED-LOUDLY, system survives |

## 5. Typed gaps (adoption rows, ordered)

- **G1** — amqp10_ledger label deviates from the IMPL-6 map schema (tuple label).
- **G2** — cosmos/blob/KV error paths emit no telemetry (messaging faces do).
- **G3** — `with_valid_body`/`safe_dispatch` containment seam in egress_router.ex is
  unwired (zero callers); the "egress invalid body on <path>" site log is currently
  unreachable dead code.
- **G4** — cosmos/blob wire refusals are typed-but-silent; no site log, no label, no id.
- **G5** — `Logger.metadata` correlation ids do NOT render under the default formatter
  (metadata list empty by default) and raw handlers never see SASL reports (Elixir
  primary translator filter `sasl: false`, IMPL-6's finding re-confirmed: `FILTERS=`
  witness in tmp/ja15-meta.out lineage). Correlation ids are debuggable today ONLY via
  process labels; metadata-based ids require formatter config to surface.

## Falsifier / replay

`MIX_BUILD_ROOT=_build-ja15 mix test test/internal/ja15_error_logger_court_test.exs` on
HEAD must return `4 passed`; removing any `Process.set_label` from
`lib/smalt/messaging/amqp/listener.ex:72` flips test 1 (missing `Process Label:` line);
making `Smalt.Ja15.HostileFormatter.format/2` not raise flips test 4 (no hostile window).

Court file (lane-owned, uncommitted): `/Users/sac/smalt/test/internal/ja15_error_logger_court_test.exs`
Receipt: `/Users/sac/smalt/docs/jira/v26.10.21/receipts/ja15-error-logger-audit.md`
