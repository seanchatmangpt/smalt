# 07 — TUI telemetry + watcher seam contracts (lane 7, v26.10.31)

Subject: /Users/sac/smalt @ main (uncommitted wave state, 2026-10-30)
Closes: GM1 (TUI invents telemetry — never reads posh_status.sh / dx_report.py),
GM5 (watcher watches regen-check-owned generated paths — reload-storm risk).
Companions: gaps/60-status-command.md (GAP60/DOD7: posh_status.sh is the single
glance), gaps/76-gemini-reconciliation.md (stateless-law context).

## GM1 — TUI consumes membrane-side data (TelemetrySource seam)

**Current defect.** `posh/internal/tui/telemetry.go` defines `TelemetrySource`
but the only implementation, `DirectMetricsSource`, derives everything
in-process (metrics registry + doctor.Run) — the TUI shows telemetry no
membrane-side surface (posh_status.sh sections, dx_report.py SPC table) would
confirm. Two status surfaces, zero shared source. Additionally
`DirectMetricsSource` seeds `cachedAndon = "GREEN"` (telemetry.go:49) — an
invented default state shown before any probe ever ran.

**Stateless-law ruling.** posh stays stateless and disposable (SPAF Rule 1;
docs/jira/v26.10.31/00-unification-dialect-decision.md law 4; the file was
being renamed by a concurrent lane mid-read — text cited from grep witness).
The supervisor's UDS (`run/posh.sock`) is reload-owned: it exists to hot-swap
the worker; routing status reads through it would make the served process
report on itself and pin state in a disposable component. **Posh-side exec of
the report-only scripts is the lawful transport**; UDS status ops are unlawful
under the stateless law. Exec is report-only by the scripts' own contract
(posh_status.sh header: "Report-only: never builds, never applies";
dx_report.py: "Exit 0 always"), so it cannot mutate membrane state.

### Contract: ScriptStatusSource

New `TelemetrySource` implementation (new file
`posh/internal/tui/script_source.go`):

```go
// ScriptStatusSource wraps scripts/posh_status.sh (sections) and
// scripts/dx_report.py (SPC rows) via read-only exec. Never builds,
// never applies. Timestamp-gated throttling (no-sleep doctrine):
// posh_status.sh at most once per 10s (measured runtime ~5-20s:
// kubectl + gates), dx_report.py once per 3s.
type ScriptStatusSource struct {
    StatusScript string // path to posh_status.sh
    DxReport     string // path to dx_report.py
    MinInterval  time.Duration
    DxInterval   time.Duration
}
```

Semantics:

- `Snapshot(ctx)` runs `bash scripts/posh_status.sh --json` and
  `python3 scripts/dx_report.py --json` via `exec.CommandContext(ctx, ...)`,
  parses output into snapshot fields. On exec error or unexpected exit, keep
  the last good snapshot and render UNKNOWN — never a default of GREEN (the
  telemetry.go:49 seed is deleted; see edits below).
- Throttle by timestamp gate (`now.Sub(last) > interval`), the existing
  DirectMetricsSource doctor-throttle pattern — no sleeps.
- Compose, don't fork: a `CompositeSource` merges `DirectMetricsSource`
  (in-process throughput/quantiles/conns) with `ScriptStatusSource`
  (AndonStatus from the script's own OVERALL line, section verdicts, raw
  lines into RecentLogs, dx rows); later source wins per-field when non-zero.

### Machine-readable script modes (required for typed parse; smallest diffs)

- `scripts/posh_status.sh`: optional `--json` flag. When set, emit one JSON
  object per verdict line: `{"section":"PLANE","verdict":"OK","detail":"..."}`
  plus a final `{"section":"OVERALL","verdict":"GREEN|RED","exit":N}` line.
  Exit-code contract unchanged (0 / 2). Prose mode stays the default;
  `just posh-status` unchanged (thin-wire GAP60 contract preserved). The
  verdict() helper gains one branch writing JSON to stdout when
  `POS(fmt)`-style flag set — ~10-line diff.
- `scripts/dx_report.py`: `--json` flag emitting the per-gate rows (gate, n,
  pass rate, p50/p99 ms, bf) as a JSON array; exit 0 unchanged; NO DATA case
  emits `{"rows":[],"no_data":true}`.

### Exact file edits

1. `posh/internal/tui/telemetry.go`: delete the `cachedAndon: "GREEN"` seed
   (seed "" and render UNKNOWN until first successful probe); add
   `PoshSections` and `DxRows` fields to `TelemetrySnapshot`; add
   `CompositeSource` implementing TelemetrySource.
2. `posh/internal/tui/script_source.go` (new): `ScriptStatusSource`,
   `parsePoshStatusJSON`, `parseDxJSON`; table-driven tests exec the real
   scripts with a presence-guarded `t.Skip` (Chicago: real collaborators, no
   mocks), plus a fixture recorded from a real run.
3. `posh/cmd/posh/main.go`, two call sites — `runDev` TUI branch (~line 227)
   and `runTUI` (~line 256):

```go
source := tui.NewCompositeSource(
    tui.NewDirectMetricsSource(reg, docOpt),
    tui.NewScriptStatusSource("scripts/posh_status.sh",
                              "scripts/dx_report.py"))
```

   In `runDev`, pass the supervisor's ctx into the source so TUI teardown
   cancels in-flight script execs (exec.CommandContext with the shared ctx).
4. `scripts/posh_status.sh` + `scripts/dx_report.py`: `--json` modes per
   contract; `bash -n` and `python3 -m py_compile` clean; prose default
   byte-unchanged.

### Close conditions (GM1)

- CC-GM1-1: `grep -rn 'GREEN' posh/internal/tui/telemetry.go` → no hardcoded
  default-andon hit.
- CC-GM1-2 (real run): `go run ./cmd/posh tui` renders section verdicts whose
  (section, verdict) pairs match a concurrent `bash scripts/posh_status.sh`
  run in value.
- CC-GM1-3: `python3 scripts/dx_report.py --json` output parses in the source
  test against a fixture recorded from a real run.
- CC-GM1-4: `go test ./posh/internal/tui/...` passes; zero `mock`/`fake` in
  the new test files.
- CC-GM1-5: prose mode unchanged — `bash scripts/posh_status.sh` output
  matches a pre-edit capture (shim-court-style before/after on a temp copy).

## GM5 — watcher stops watching regen-check-owned paths

**Current defect.** `posh/internal/dev/watcher.go:31` `IgnorePrefix` is
`[".git","bin","run","var","tmp",".hypothesis","_build","deps"]` — no
`internal/adapter` or `config` entries. `posh/internal/adapter/*.go` are
regen-check-owned generated code (ggen projection) and
`posh/config/egress_allowlist.generated.yaml` is generated; a regen during
`posh dev` mints events → spurious `Reload` → reload storm (each reload is a
full `go build`).

### Contract

IgnorePrefix gains generated-path entries; the matcher is extended so
path-qualified entries (containing `/`) match as relative-path prefixes while
plain names keep segment semantics.

### Exact edits

1. `posh/internal/dev/watcher.go:31`:

```go
IgnorePrefix: []string{".git", "bin", "run", "var", "tmp", ".hypothesis",
    "_build", "deps", "internal/adapter", "config"},
```

2. `shouldHandle` ignore loop (watcher.go:192-196), final form:

```go
for _, ig := range w.cfg.IgnorePrefix {
    if strings.Contains(ig, "/") {
        // path-qualified entry: match as relative path prefix anywhere
        if strings.HasPrefix(ev.Name, ig+"/") ||
            strings.HasSuffix(ev.Name, "/"+ig+"/"+filepath.Base(ev.Name)) ||
            strings.Contains(ev.Name, "/"+ig+"/") {
            return false
        }
        continue
    }
    if strings.Contains(ev.Name, "/"+ig+"/") || strings.HasPrefix(ev.Name, ig+"/") {
        return false
    }
}
```

   (Plain-name branch is byte-identical behavior to today; path-qualified
   branch is additive.)
3. `addRoots` walk skip (watcher.go:100-105) gains the same path-qualified
   branch so the generated dirs are not even watched (SkipDir), not just
   filtered post-event — otherwise fsnotify still buffers their events.
   Note: `addRoots` matches on `filepath.Base(path)` only; extend it to test
   the root-relative path against path-qualified IgnorePrefix entries
   identically.
4. L42 fragment paths: UNVERIFIED — no `L42` fragment directory found under
   `posh/` this session (searched names `L42`, `l42`, `fragment` in
   `posh/internal`, `posh/config`). If the implementation lane locates the
   regen fragment dir, add it to IgnorePrefix with a receipt; do not guess a
   path.

### Close conditions (GM5)

- CC-GM5-1 (mutation, shim-court style): touch a file under
  `posh/internal/adapter/` and under `posh/config/` while `posh dev` runs —
  zero `change detected` reload lines within one debounce window (before-edit
  witness: reload fires on the same touch).
- CC-GM5-2: touch a file in `posh/internal/dev/` — reload still fires
  (non-vacuity: the gate must still flip for owned paths).
- CC-GM5-3: `go test ./posh/internal/dev/...` passes, including a new
  `TestShouldHandleGeneratedPaths` table test with real fsnotify events
  replayed against the real watcher.

## Seam 3 — single status surface ownership (DOD7 vs TUI dashboard)

**Ruling**: `scripts/posh_status.sh` owns the status surface (GAP60/DOD7
receipt: typed sections, exit contract, ALIVE 2026-10-30). The TUI dashboard
is a *renderer* over it, never a second source of truth. The L50/GM6 gate:
any new surface that displays estate status must consume posh_status.sh
output (directly or via the ScriptStatusSource seam); a surface that computes
its own section verdicts is a fork and is refused. Enforcement: CC-GM1-2 is
the conformance court — TUI-rendered verdicts must match posh_status.sh
value-for-value; divergence fails the court. `just posh-status` remains the
headless face; `posh tui` is the interactive face of the same data.

## Status

- This lane: **ALIVE** (2026-10-30, M7 implementation lane). Spec implemented
  and falsified green this session.
- GM1 closed: `DirectMetricsSource` no longer seeds `cachedAndon = "GREEN"`
  (seed deleted, telemetry.go — CC-GM1-1 grep for `GREEN` in tui telemetry
  files: only a comment hit, zero code hits); `ScriptStatusSource`
  (`posh/internal/tui/script_source.go`) execs the real report-only scripts,
  timestamp-gate throttled (10s status / 3s dx), keeps last-good on failure,
  typed errors (`ScriptNotFoundError`, parser errors) on malformed payloads —
  mutated-source probe in `script_source_test.go`
  (`TestParsePoshStatusJSON_MalformedIsTypedError`) asserts no GREEN is ever
  synthesized from prose/truncated/empty/garbage input; `CompositeSource`
  merges Direct + Script sources later-wins; `cmd/posh/main.go` both TUI call
  sites wired via `tui.NewCompositeSource(NewDirectMetricsSource, NewScriptStatusSource)`.
- GM5 closed: `IgnorePrefix` gains `internal/adapter`, `config`
  (`posh/internal/dev/watcher.go`); path-qualified matching added to
  `shouldHandle` and `addRoots` (generated dirs are SkipDir'd, never watched);
  real-execution court `TestWatcherIgnoresGeneratedLive`
  (`watcher_live_test.go`): real fsnotify watcher over a real repo-local temp
  tree — touches under `internal/adapter/` and `config/` yield zero events in
  a bounded window, owned-path touch still fires (non-vacuity). Note:
  `t.TempDir()` is unusable for live watcher fixtures (its `/var/folders/`
  path matches the `var` ignore prefix).
- Scripts: `scripts/posh_status.sh --json` (JSON lines + OVERALL line, exit
  contract 0/2 unchanged — witnessed live: exit 2 RED OVERALL parsed by the
  Go source test) and `scripts/dx_report.py --json` (single JSON payload,
  `{"rows":[...],"no_data":bool}`); prose mode byte-equivalent (CC-GM1-5:
  before/after diff over reconstructed pre-edit copy — sections and exit code
  identical, only timestamp line differs).
- L42 fragment paths: **VERIFIED on disk** — `posh/internal/adapter/`
  (11 generated_*.go files) and `posh/config/egress_allowlist.generated.yaml`
  both exist; both are covered by the new IgnorePrefix entries. The "L42
  fragment directory" of the earlier UNVERIFIED note resolves to these
  regen-check-owned generated surfaces; no separate L42 dir exists.
- Falsifier: `cd posh && go build ./... && go vet ./internal/tui/...
  ./internal/dev/... && go test ./internal/tui/... ./internal/dev/...` → exit 0;
  full `go test ./...` exit 0. CC-GM1-2 (live TUI vs script value conformance)
  and the live `posh dev` touch court remain UNVERIFIED (interactive TUI /
  long-running supervisor), superseded in-unit by the real-execution watcher
  court and the real-exec parse tests.
