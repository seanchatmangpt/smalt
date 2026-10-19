# D8 — lib moduledoc/@doc audit (2026-10-18)
9 findings across 6 files, 8 clean:
- dets_mirror.ex:13-14 STALE ("union not snapshot" — sync_table/2 bounded-growth fence deletes absent keys; mirror IS a snapshot-tracking replica); :26 :tables default stale (@default_tables = StoreTables.persisted_tables()).
- wasm_engine.ex:12-14 STALE required-exports list (_initialize not required; affi_admit_and_seal IS required but omitted; ABI list line 17-22 likewise).
- wasm_engine_supervisor.ex:8-9 CONTRADICTED (owner start_links + traps exits; monitor additional — "never links" is wrong); :10-17 retry classes stale (engine_start_failed = 250ms spacing then supervised stop, not send_after; artifact backoff 50ms initial, cap 5s, max 5).
- lro_sweeper.ex:10-11 STALE supervision (child of Smalt.Plane.ControlSupervisor post-AZB-09, not Smalt.Supervisor); :61-67 flip_key/2 doc imprecise (read path sends {:flip_due} directly).
- canonical.ex:14-15 filename drift (docs/capability.json -> docs/capabilities.json).
- router.ex:15 minor (GraphLaw 400 pin is default/:fail_open face; :fail_closed profile = typed 503 EngineUnavailable; strict_version_validation knob unnamed).
Clean: lro.ex (one-writer doc current), lro_notifier.ex, event_grid.ex, connection.ex, atom_bridge.ex, planes.ex, egress_router.ex (Peers), bearer.ex.
