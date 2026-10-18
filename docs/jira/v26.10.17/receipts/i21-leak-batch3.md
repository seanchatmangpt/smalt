# i21-leak-batch3 — test-isolation leak batch 3 (lane: leak3)

standing: ALIVE
Context: slice (three leased files + leak-court static scan)

## Identity

- repo: /Users/sac/smalt (canonical checkout, branch main @ 558f8c3)
- lane build root: `MIX_BUILD_ROOT=_build-ft-leak3`
- files (per lease):
  - `test/mcp_test.exs` (:901-905 doctor_supervisor on_exit restore — save-prev instead of literal `Smalt.Supervisor`)
  - `test/data_plane/audit_planes_test.exs` (:smalt_sentinel_forensic named ETS + :l4_off_cas conditional cleanup → unconditional on_exit delete)
  - `test/smalt_native_hcl_ladder_test.exs` (DetsMirror stop/restart — verify on_exit repair, minimal fix + disclosure)

## Consequences (real diffs)

### 1. test/mcp_test.exs (lens-4 hostile fuzz test)

- Before: on_exit restored a literal `Smalt.Supervisor`, clobbering any
  other suite's override and pinned to the app default.
- After: `saved_supervisor = Application.get_env(:smalt, :doctor_supervisor, Smalt.Supervisor)`
  captured BEFORE the override, restored in on_exit.
- Two intermediate defects in my own first draft, both caught and fixed
  in-session:
  1. `get_env` without default → saved `nil` when unset; a stored `nil`
     defeats the router's `get_env(..., Smalt.Supervisor)` default and
     doctor.summary renders `supervisor_children: []` — reproduced as a
     1-in-4 flaky failure of "doctor.summary reports real supervisor
     children" (test/mcp_test.exs:414). Fixed by capturing with the same
     default the router uses. 5/5 green after fix; HEAD version ran 4/4
     green in parallel for the pre-existing-vs-introduced determination
     (verdict: introduced by my draft, now fixed).
  2. Two-line assignment `saved =\n  Application.get_env(...)` was
     invisible to the leak court's line-based save heuristic —
     `mcp_test.exs` stayed flagged "no save of prev value". Fixed by
     single-line assignment; the file is now unflagged.

### 2. test/data_plane/audit_planes_test.exs

- `:smalt_sentinel_forensic` named ETS (created owner-durable by the
  "parallel ingests" test) was never deleted — it survived the VM and the
  "off-state costs zero" court had to clean predecessor residue to stay
  green. Added unconditional on_exit delete.
- `:l4_off_cas` cleanup was conditional inside the test's `after` only
  (skipped on abnormal teardown); added unconditional on_exit delete.
- Remaining court flags on this file (:814 `:sentinel_dcr_strict`,
  :1294 `:rg_token_preserve_options`, :1328 `:event_stream_dedup_ids`)
  are env-mutation findings OUTSIDE the lease scope — not touched.

### 3. test/smalt_native_hcl_ladder_test.exs (DetsMirror restart)

- Verified the existing repair is NOT vacuous but WAS broken in the
  empty-tree case: `DetsMirror.start_link(dir: "tmp/dets")` fail-closes
  (dets open repair:false) when `tmp/dets` does not exist — witnessed
  directly: `mix run` witness exit=1, `** (File.Error) could not list
  directory "tmp/dets": no such File or directory` (full trace in
  /tmp/dets_witness.out). The bare restart could raise inside on_exit and
  the mirror would silently stay down.
- Minimal fix: `File.mkdir_p!("tmp/dets")` before restart, then verify
  the name is registered post-start_link, raising with a typed message if
  not. Disclosure: the pre-stop mirror's dir is not recoverable after
  GenServer.stop; every witnessed default-registered mirror at ladder
  time uses the default dir, so the restart target matches.

## Verification ladder (real output)

- HEAD baseline pre-session: `git status` showed mcp/audit_planes edits
  already? No — git status at session start showed only
  `test/amqp/broker_facade_test.exs` and `test/store_dets_test.exs`
  modified (other lanes; not touched by this lane).
- Baseline leak court (pre-edit): `[LEAK-COURT] exit=1 ... 119` uncovered
  mutations, `OFFENDERS (54 files, 119 mutations uncovered)`,
  `verdict=FAIL-TREE-LEAKS offenders=54`.
- Final leak court: `[LEAK-COUNT] exit=1` / `OFFENDERS (49 files, 109
  mutations uncovered)`, `verdict=FAIL-TREE-LEAKS offenders=49`.
  Delta: -5 files / -10 mutations, all attributable to leased files
  (mcp_test.exs now unflagged; audit_planes down to 3 out-of-lease env
  flags).
- Solo runs (MIX_BUILD_ROOT=_build-ft-leak3):
  - `test/mcp_test.exs` — 5/5 green after final fix:
    `52 tests, 0 failures`, exit 0.
  - `test/data_plane/audit_planes_test.exs` — 3/3 green:
    `82 tests, 0 failures`, exit 0.
  - `test/smalt_native_hcl_ladder_test.exs` — 3/3 green:
    `4 tests, 0 failures`, exit 0.

## Replay

```
cd /Users/sac/smalt
just leak-court-count          # expect: offenders=49 (was 54), mutations 109 (was 119)
MIX_BUILD_ROOT=_build-ft-leak3 mix test test/mcp_test.exs
MIX_BUILD_ROOT=_build-ft-leak3 mix test test/data_plane/audit_planes_test.exs
MIX_BUILD_ROOT=_build-ft-leak3 mix test test/smalt_native_hcl_ladder_test.exs
```

## Falsifiers

- Restore regression: delete the saved-value default in mcp_test and the
  doctor.summary children test goes flaky-red within ~4 runs (witnessed).
- Restart regression: remove `File.mkdir_p!` from the ladder on_exit and
  the restart raises File.Error when tmp/dets is absent (witnessed).
- Leak regression: recreate a named :smalt_sentinel_forensic without the
  on_exit delete and the leak court's manual residue check (off-state
  test) fails against predecessor residue.

## Standing

ALIVE — three solo-green suites with embedded real output, leak-court
delta witnessed (54→49 files / 119→109 mutations). No git (per lease).
Note: build root `_build-ft-leak3` left in place per lane discipline;
coordinator to reclaim via lane-clean at integration.
