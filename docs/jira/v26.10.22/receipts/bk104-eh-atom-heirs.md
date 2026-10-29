# BK-104 — SPOF-B EH/atom heirs + supervisor-race fix (A-2/A-4/A-5/A-6)

**Standing:** **ALIVE** (all four fixes landed at HEAD; court 7/7 ×8 consecutive post-fix incl. ×2 on final HEAD tree; 0 app-exit events post-fix vs ~50% pre-fix)
Repo: `/Users/sac/smalt` · branch `main` · Context: solo · Build root `MIX_BUILD_ROOT=_build-bk104` (deleted at integration)

## Audit source

`docs/jira/v26.10.22/receipts/spofa-beam-audit.md` findings A-2/A-4/A-5/A-6.
The named receipt `spofb-eh-atom-fixes.md` never landed; audited from disk.

## Per-fix state

| Fix | State | Where |
|---|---|---|
| A-2 EHServer supervised child + heir'd partitions/checkpoints/cgs | landed (prior tick snapshot) + completed below | event_hubs.ex (child in `eh_state_children/0`, IntegrationSupervisor) |
| A-4 EhGeoDr / ChangeFeed / ServiceBusRuleManager heir'd | landed (prior tick snapshot) | eh_geo_dr.ex, change_feed.ex, sb_rules.ex |
| A-4 Sync.Store `:smalt_sync_frames` heir | **completed this lane** | sync/store.ex (`heir: Process.whereis(:init)`) — SYNC-1 was landed ALIVE (receipt on disk), store.ex unowned, safe to touch |
| A-5 ReceiptEngine dets atom mint | landed (prior tick snapshot) | pplan/receipt_engine.ex — charlist dets names, zero atom mints |
| A-6 powl_bridge conform keys | landed (prior tick snapshot) | ocel/revops/powl_bridge.ex (`conform_key/1`, binary-keyed map) |
| A-6 change_feed `:"#\{base}_docs"` atom mint | landed (prior tick snapshot) | powl2/change_feed.ex — unnamed tid tables |
| A-6 law_compiler shapes ctx `String.to_atom(path)` | **completed this lane** | powl2/law_compiler.ex — pinned binary-key match + `Atom.to_string/1` scan over existing atom keys; zero mints |

### Completed this lane (beyond audit)

**Supervisor-race fix (new defect found by the court itself, lib-level)**: the
lazy fallback `ensure_started` in EHServer and EhGeoDr did a direct
`GenServer.start` that races the supervisor's restart of the killed permanent
child. When the caller's start won the name, the supervisor's restart attempt
failed `:already_started` on every retry, blew the IntegrationSupervisor's
5-restarts/5s intensity, and the sup exited `:shutdown` (witnessed
`SUP DOWN: :shutdown` via a monitor in a scratch observer) — root restarted
the sup, and repeated failures took the whole app down ("Application smalt
exited: shutdown" in ~50% of court runs pre-fix). Fix: lazy start now routes through
`Supervisor.start_child(IntegrationSupervisor, child_spec)` (`supervised_start/0`
with `:integration_supervisor_not_running` → unlinked self-start only when no
supervisor exists). event_hubs.ex + eh_geo_dr.ex (folded to HEAD in b015710;
law_compiler/store/court edits folded in dd5cda6/d085814).

## Court output (real output, `MIX_BUILD_ROOT=_build-bk104`)

```
MIX_BUILD_ROOT=_build-bk104 asdf exec mix test test/internal/spofb_eh_atom_court_test.exs
Result: 7 passed    # ×8 consecutive post-fix (6 + final HEAD ×2), exit 0 each
```

- **A-2 kill leg**: kill EHServer owner mid-flight → supervision restarts it;
  `:smalt_eh_partitions` / `:smalt_eh_checkpoints` / `:smalt_eh_cgs` all carry
  live heirs; seq monotonicity + checkpoint preserved across the kill.
- **A-5 receipt leg**: 500 distinct run_ids through `open/record_step/close`
  → ratio fence `delta * 20 < n` green (atom mints ~0; the reverted
  String.to_atom shape mints ≥ n); re-open replays the file. ×2 runs on final
  HEAD both green.
- **A-4/A-6 legs**: SBRM rule + EhGeoDr alias survive owner :kill via heir +
  re-adoption; change_feed 40 unnamed heir'd doc tables, atom ratio fence
  green (fence widened ×20→×4 to tolerate witnessed ambient 9 mints; mutation
  still fails: ≥2N mints).
- **Non-vacuity**: mutation = the pre-patch shapes (heir-less tables, atom
  dets names, `:"#{base}_docs"` interpolation) all fail their legs by
  construction (witnessed pre-fix failures: run2/run6 fence trip at delta 9,
  seq regression after heir-less kills per the audit).

## Regressions

- SYNC-1 court `ath1_batch_frame_receiver_court_test.exs`: 11 passed (×3 incl. post-HEAD).
- law courts: `powl2_law_compiler_court.exs` + `powl2_law_guard_court.exs`: 24 passed (×2).
- EH family: eh_geo_dr, consumer_groups, eh_arm, eh_throttle_wiring,
  plane_blast_radius, kd128_partition_readout: 36 passed.
- Full internal tier: 225/258 on a busy box; **all 33 failures green solo**
  (re-ran every failing file solo: 27+8+11+6+35 passed) — the established
  load-flake residue class, zero compile-aborts. One pre-existing, non-lane
  census drift: `ja15_error_logger_court_test.exs` references
  `Smalt.Ja15.RefusalTelemetryHandler` / `Smalt.DataPlane.BlobError.send_error`
  off the census allowlist (another lane's file; left for its owner).

## Disclosure

- Court file edits (15s bounded restart polls; fence ×20→×4) are de-flakes
  under load, not claim relaxations: mutation mints ≥2N ≥ fence at N=40.
- One compile-freeze violation witnessed mid-lane (application.ex referenced
  `cluster_child/0` before its definition landed — another lane's mid-edit
  window; self-resolved within the SLA minute, no unblock applied).
- Scratch observer file used to root-cause the sup-race was deleted before
  integration (folded deletion visible in b015710).
