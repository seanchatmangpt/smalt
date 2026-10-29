# JA-16: Joe-Armstrong Robustness Census over `lib/smalt`

**Standing: PARTIAL** — principles 1/2/3 PASS; principle 4 (observability of every failure) PARTIAL with 2 new defects and 3 minors. Context: solo.

Scope: 223 `.ex` files under `/Users/sac/smalt/lib/smalt`; 131 `rescue` sites + 3 `catch` sites swept by script (`rescue` + 4-line body dump, full-corpus, not sampled). JA-2's five sites (planes.ex:63-66, egress_router.ex:880-884, arm_gateway/router.ex:3291, affidavit/seal.ex:113, security/ledger_writer.ex:166) excluded — not re-derived.

## P1. Fail-fast on bad data — PASS (1 new defect)

Boundary pattern is sound: hostile-input modules (`data_plane/*`, `egress/*`, `security/*`, `auth/*`) consistently convert raises to typed refusals (`{:error, :invalid}`, `{:refuse, 401, ...}`, `{:error, 400, bad_request(...)}`), e.g. `security/attestation.ex:143-147`, `security/receipt_signer.ex:84/205/214`, `data_plane/partition_key.ex:41`, `data_plane/cosmos_feeds.ex:128-132` (binary_to_term [:safe], typed invalid), `key_vault_actions.ex:1517/1557/1649` (typed 400s). Bang-JSON (`Jason.decode!`) confined to internal contract/replay paths (`runtime_contracts/*`, `ocel/deviation_admission.ex:88` fixture replay), not hostile-request boundaries.

**NEW defect JA16-D1 (P1 — highest rank)**: `lib/smalt/cosmos_sql.ex:766` — `lw = String.to_atom(String.downcase(w))` mints an atom for EVERY word of a wire-sourced Cosmos SQL query (reached from clients via `data_plane/cosmos.ex:1906` `Smalt.CosmosSql.parse(q, ...)`). Unbounded atom-table growth = DoS vector, and the atom table is never GC'd for node lifetime (crash-only does not recover it). This directly violates the codebase's own law, documented at `lib/smalt/messaging/amqp/frame_codec.ex:800`: "Wire-sourced keys are never minted into atoms". Falsifier: `parse(String.duplicate("zzz ", 50_000))` grows `:erlang.system_info(:atom_count)` monotonically per distinct token. Fix shape: compare case-insensitively as binaries against the @keywords list (`String.downcase(w) in @keyword_strings`), or `String.to_existing_atom` inside a rescue returning `{:ident, w}`.

## P2. One obvious error path — PASS

No deep nested rescue ladders: egress_router has 3 rescues in 3400 lines, arm_gateway/router 10 in 7000; each is a flat, typed conversion with a rationale comment (ARMSTRONG fix 1/2, lens-5, KD-124 annotations throughout). `graphlaw/sql_row_gate.ex:56/260` narrowed typed rescues to refusal structs — the model pattern.

## P3. Crash-only design — PASS

- Supervision: plane supervisors (Data/Control/Integration/Identity) under `Smalt.Supervisor` (application.ex:301-312); restartable ETS via idempotent `ensure_table` (`ArgumentError -> :ok` race-safe recreation) across 10+ data_plane modules; `{:heir, ...}` ownership transfer (policy.ex:80, cosmos.ex:2384).
- Post-boot table-loss law documented and followed (`monitor/metrics.ex:219` "Post-boot table loss must never kill a request process").
- WASM engine crash → typed `:engine_unavailable` with compensation (ledger_writer.ex:119-170), never a wedged connection.

## P4. Observability of every failure — PARTIAL (new sites)

Of 131 rescue sites, the overwhelming majority carry a Logger call, telemetry emission, or a typed error that the caller logs/renders. Silent-swallow sites found (excluding JA-2's):

- **JA16-D2 (P2)**: `lib/smalt/auth/x_arr_cert.ex` — whole module has ZERO Logger/telemetry references. `ca_certs/0` (~line 130-147) and `decode_ca_file/1` (~line 153-172) return `[]` silently on File.stat failure, missing file, or unparseable PEM. With `require: true`, a bad `:ca_certfile` path yields every request 401 "ClientCertificateFailed" with no diagnostic anywhere — a silent security misconfiguration. Fail-closed but unobservable. Fix shape: single `Logger.error("x_arr_cert: CA file unloadable: #{f}")` at the decode-failure branches.
- **JA16-D3 (P3)**: `lib/smalt/messaging/eh_throttle.ex:243` — `rescue _ -> nil` in `hub_record_quota/1` silently falls back to the default quota window with no log; a corrupted resources store degrades throttling invisibly.
- Minor (accepted, not defects): `messaging/amqp/connection.ex:300` and `wasm/worker.ex:247` rescue/catch `:exit -> :ok` are best-effort cleanup paths (release/close after failure) where silence is idiomatic; `data_plane/cosmos_feeds.ex:132` typed-invalid in an auth refusal path (silence correct); `powl2/law_compiler.ex:235` `String.to_atom(path)` mints from the trusted admin-authored shapes file (bounded, not wire-sourced).

## Ranked defect list (NEW sites only)

1. **JA16-D1 (P1)** cosmos_sql.ex:766 wire-sourced unbounded atom minting — violates stated codebase law (frame_codec.ex:800); DoS + non-recoverable-until-restart state.
2. **JA16-D2 (P2)** x_arr_cert.ex CA-load silent `[]` — fail-closed but zero observability on a security-critical misconfig.
3. **JA16-D3 (P3)** eh_throttle.ex:243 silent quota fallback, no log.
4. Minor: sas_verifier.ex:322/346, hsm_signer.ex:50, key_vault_actions.ex:1701/1732 silent-false rescues — all fail-closed and semantics-correct (verify-false IS the API contract for key_vault); noted, no action.

Verification method: full-corpus scripted sweep (python3 rescue-body dump over 223 files), targeted Read of every suspicious silent-catch-all, source-tracing of atom-mint and decode! sites to their callers to classify wire-sourced vs internal. No files modified.
