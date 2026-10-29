# JA-3: Hot-Code Upgrade Readiness Audit (Joe Armstrong definition of done)

**Standing:** **PARTIAL_ALIVE** — live hot-reload witnessed (PASS) on a real
running process; fleet-wide hot-UPGRADE readiness **not met** (0/33 modules
export `code_change/3`, 0 use the tail-call reload idiom).

Context: full

Toolchain: OTP 29.1.2 / Elixir 1.20.4-otp-29 (asdf, repo `.tool-versions`),
`MIX_BUILD_ROOT=_build-ja3`.

## Census (lib/smalt)

- 33 `use GenServer` modules; plus `Smalt.Application` and
  `lib/smalt/messaging/amqp10/amqp10_connection.ex` touching
  gen_statem/raw `:gen_server`; 5 explicit Supervisor modules.
- **`code_change/3`: 0 of 33** — no module exports the OTP upgrade callback
  (`grep -rn code_change lib/smalt --include='*.ex'` → no matches).
- **`?MODULE:loop()` fully-qualified tail-call idiom: 0** across the tree.
  The only raw loop is `lib/smalt/arm_gateway/lro.ex` `fallback_loop/3`,
  a **local** tail call — pins the old code until the loop exits, but each
  loop is deadline-bounded to one LRO op, so staleness is bounded.
- State records that would break across a reload without `code_change`
  (`defstruct` as GenServer state):
  - `lib/smalt/messaging/amqp/cbs_router.ex` — `%CBSRouter{table, audience_config}`
  - `lib/smalt/hw/virtual_serial.ex` — `%VirtualSerial{device, decoder, counter, serial, stdio}` (decode state machine state)
  - `lib/smalt/monitor/metrics.ex` — `%{table: table}` plain map (benign shape)
  - (`lib/smalt/telemetry.ex`'s `%Span{}` defstruct is a public type, not GenServer state)
- Remaining ~29 GenServers hold plain maps of refs/tables/counters —
  reload-tolerant by shape, but NOT provably upgrade-safe: a state-shape
  change crashes on first message post-load; supervision restarts re-init on
  the NEW code, so the failure mode is a bounded restart storm, not
  persistent corruption.

## Live hot-code witness (real process, not census)

Subject: `Smalt.Monitor.Metrics`, started standalone under `:telemetry` only
(app not booted; no ports taken). Script: `tmp/ja3_witness.exs`.

Run: `MIX_BUILD_ROOT=_build-ja3 mix run --no-start tmp/ja3_witness.exs`

Verbatim output of the passing run:

```
WITNESS-START pid=#PID<0.522.0> module=Smalt.Monitor.Metrics
BASELINE rows=1 alive=true
VARIANT-LOADED which=[]
AFTER-LOAD probe={:hot_code_variant, nil} rows=1 same_pid=true alive=true
ORIGINAL-RELOADED which=~c"/Users/sac/smalt/_build-ja3/dev/lib/smalt/ebin/Elixir.Smalt.Monitor.Metrics.beam"
RESTORED probe_face=:gone rows=1 same_pid=true alive=true
WITNESS-PASS
```

What it proves, step by step:

1. Baseline: real face exercised (`:telemetry.execute` egress-refused event
   → 1 ETS row), process alive, named via the module.
2. A no-op variant with an added `:ja3_probe` face was loaded over the
   running module (`Code.compile_string`, the in-memory load path; the
   original beam was then restored with `:code.load_binary` from
   `_build-ja3`).
3. The **same pid** adopted the new code: `:ja3_probe` answered
   `{:hot_code_variant, nil}` — `nil` because the process ran the NEW code
   against its OLD state (`ja3_variant` key absent from the pre-upgrade
   state map). This is exactly the Armstrong upgrade condition, exercised on
   a running, named, telemetry-attached process.
4. State survived both swaps intact (rows=1 across baseline/variant/restore).
5. After `:code.load_binary` of the original beam, the probe face is gone
   (`events/0` returns the original list) and the same pid still serves.

Witness-design note (honest disclosure): the restore check deliberately uses
the exported `events/0` face, not a `:ja3_probe` call — the ORIGINAL module
defines no `handle_call/3` at all, so a probe call post-restore crashes the
server (GenServer's generated fallback raises inside the server; the client
sees an exit). That behavior is itself a census finding: most smalt
GenServers have no defensive `handle_call` fallback, so post-reload probing
with stale faces is crash-prone.

## Findings

1. **`Smalt.Monitor.Metrics.raw_rows/0` is broken for any non-empty table**
   (pre-existing, witnessed in this lane's first run):
   `table_rows/1` yields 4-tuples `{key, count, sum, max}` but `raw_rows`
   maps with a 3-tuple pattern `{r, m, b} = k` → FunctionClauseError on the
   first row. Not fixed here (audit lane; `lib/` is shared). Suggested fix:
   pattern `{k, c, s, mx}`.
2. **Reload works; upgrade does not.** No `code_change/3` anywhere → the OTP
   release-handler/appup flow is NOT READY (0/33).
3. Tail-call reload idiom absent (0 hits); the single raw loop
   (`lro.ex fallback_loop/3`) is local-call-pinned per-op, bounded.

## Verification commands (verbatim)

```
grep -rln 'use GenServer' lib/smalt --include='*.ex' | wc -l        # 33
grep -rn code_change lib/smalt --include='*.ex'                     # no matches
grep -rn 'MODULE:.*loop' lib/smalt --include='*.ex'                 # no matches
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-ja3 mix run --no-start tmp/ja3_witness.exs    # WITNESS-PASS
```

Witness script retained at `/Users/sac/smalt/tmp/ja3_witness.exs` (scratch,
not indexed).
