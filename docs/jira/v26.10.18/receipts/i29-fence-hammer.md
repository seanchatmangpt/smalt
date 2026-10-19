# Receipt: i29 fence-10/11/12 triple hammer ×10

- Date: 2026-10-18
Context: slice(fence ×10)
- Standing: PASS (10/10 identical green)
- Subject: `/Users/sac/smalt` @ 6eec145 (working tree, shared machine)

## Subject identification

All three fences live in one file — there is no separate fence-10/11/12 file triple:

- `test/affidavit_wasm_failclosed_test.exs:549` — fence 10 (restart hammer, relative-ratio duration fence)
- `test/affidavit_wasm_failclosed_test.exs:657` — fence 11 (supervised-restart kill-loop hammer)
- `test/affidavit_wasm_failclosed_test.exs:759` — fence 12 (start while running is typed already_started passthrough)

Cross-references: `docs/jira/v26.10.18/rewrite-drafts/fence10-ratio.md`,
`docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md` (fence-10 evidence section),
`docs/jira/v26.10.18/REWRITE-STATUS.md` rows B3 / b-wasm-supervisor.

## Command

    for i in $(seq 1 10); do
      MIX_BUILD_ROOT=_build-ft-fh mix test test/affidavit_wasm_failclosed_test.exs
    done

Rationale: running three line-specs of the same file in one `mix test` invocation
(`mix test file:549 file:657 file:759`) reproduces a double application boot —
`Smalt.Application` fails with `Smalt.Store ... already started: #PID<...>` (Mix
re-enters the app boot per duplicate file spec). A single whole-file spec is the
sound shape; the whole file (14 tests) includes fences 10, 11, 12.

## 10-run table

| run | exit | summary |
|---|---|---|
| 1 | 0 | 14 tests, 0 failures |
| 2 | 0 | 14 tests, 0 failures |
| 3 | 0 | 0 failures (14 tests) |
| 4 | 0 | 14 tests, 0 failures |
| 5 | 0 | 14 tests, 0 failures |
| 6 | 0 | 14 tests, 0 failures |
| 7 | 0 | 0 failures, 14 tests |
| 8 | 0 | 14 tests, 0 failures |
| 9 | 0 | 14 tests, 0 failures |
| 10 | 0 | 14 tests, 0 failures |

Acceptance: 10/10 identical green — MET.

## Machine context (honest)

`just quiet-check` REFUSED during the window (load ~73/16 CPUs, sibling beams in
this and other checkouts, court ports 9443/8443/5672 held by an ssh forward not
owned by this lane). The hammer ran through it; no interference observed in runs
1-10. An earlier probe window (3 single-fence runs + 2 multi-spec runs) hit
2/3 red faces of the `Store already started` boot class on the same load — those
were pre-hammer probes, not hammer legs. No `_build` dirs removed; no edits; no git.

## Falsifier / non-vacuity

A red run would flip this receipt to FAIL; the earlier probe legs (multi-spec and
load-window) demonstrate the harness does fail loudly on the observed boot face.
Per-run logs: `/tmp/fence_h2_1.log` .. `/tmp/fence_h2_10.log`.
