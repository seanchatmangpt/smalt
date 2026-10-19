# D3 — docs/reference audit (2026-10-18)
courts.md: gate table missing isolation gate + sleep_gate_court (26 scripts not 25); budget/burn/azsim surfaces absent entirely.
NO_SLEEP_DOCTRINE: lib census stale (actual 3 sites: doctor.ex:186/:265, state.ex:169; router + wasm_engine rows removed post-redesign); B1 count 13->20; verify_all loud-skip vs AZB-21 enforce contradiction (AZB-21 section current).
kd-register.md: counts all wrong (rows 95 not 94; CLOSED 32 not 22; OPEN 63 not 72) — "as of 2026-10-16".
just-recipes.md: stale projection (29 modules not 20; imports :221-254).
ets-tables.md: source-of-truth moved to store_tables.ex; count 33 -> 53; dets-mirror section missing.
arm-gateway.md: LRO.Notifier missing; arm_port/arm_tls_port pins moved to config/config.exs; OperationRecordIncomplete pin stale.
ports-and-planes.md: SMALT_PLANES zero coverage; defaults moved to config.exs.
MISSING reference surfaces: planes/azsim courts, burn suite, validate_burn, isolation court, budget gate, RouteCites, dets open_typed + telemetry, LRO Notifier/await, WasmEngine supervisor, Event Grid engine, plane profiles.
CURRENT: ERROR_CODES.md, capabilities.json (both fence-verified).
