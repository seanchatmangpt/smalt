# B5 receipt — auth / wire / egress rewrite (v26.10.18)

Standing: ALIVE (all touched files green x2 + full wire tier green; one
disclosed co-batch flake, see Deviations). Slice lane B5, spec:
`docs/jira/v26.10.18/rewrite-drafts/auth-wire-egress.md` (§5 apply sequence,
falsifier §0 inventory = the batch gate).

## Context

Slice of the v26.10.18 first-principles test-rewrite wave (00-MASTER-PLAN).
Zero production-code changes (`lib/` untouched by this lane). Seeds, corpus
sizes, budgets, and every pinned status/code/message triple carried forward.

## What landed

1. **`test/support/wire_helpers.ex` (new)** — `SmaltTest.Wire`:
   `resilient_clear!/0` (50x10ms ArgumentError-narrowed i21 retry, verbatim
   from the egress_dispatch private fn), `start_wire_tree/1`
   (start_supervised!-owned {Store, Bandit(arm), Bandit(egress)}),
   `pin_ports!/3` (save-prev/on_exit-restore of the three port envs),
   `save_restore/1` macro (delegates to the B0 canonical
   `SmaltTest.Env.put_restored/1` — one implementation of the
   save/restore discipline), `stop_existing_tree/0` (superset name list
   Store+AmqpBroker), `get_free_port/0`, `http_request/4` (raw gen_tcp,
   15s recv, chunked decode). `stop_existing_tree/0` lives here rather than
   being promoted onto `SmaltTest.Lifecycle` (spec §4): test_helper.exs is a
   shared file under concurrent edit by the B0 lane — placed in the B5-owned
   support module instead; disclosed seam.
2. **`test/egress_dispatch_test.exs`** — setup hoisted to
   `SmaltTest.Wire.resilient_clear!/0`; SKR/CORS env flips moved from the
   Process.put style to `save_restore/1` (CORS default-leg keeps an explicit
   delete+prev-restore: the `["*"]` default keys on env ABSENCE, which
   save_restore cannot express — disclosed); both Bandit legs + engine-kill
   court moved onto `start_wire_tree!/pin_ports!/http_request`; local
   stop_tree/stop_existing_tree/get_free_port/wire_request/parse_response/
   decode_chunked helpers deleted (~110 lines); pinion-keyed describes
   wrapped: "CORS", "two-layer 413 boundary", "KD-15 /keys challenge" (R155
   W1-W3 + KV soft-delete describes already existed).
3. **`test/eventgrid_topics_arm_test.exs` + `test/eventgrid_conformance_test.exs`**
   — hand-rolled `Smalt.ConfWireSup` trees replaced by
   `SmaltTest.Wire.start_wire_tree/1` under `start_supervised!` (ExUnit-owned,
   unnamed); per-suite get_free_port/http_request/recv_all/parse_response/
   stop_tree/stop_existing_tree/wait_until_gone deleted; topics-arm keeps
   arm_port()/egress_port() env-read helpers (the endpoint echo reads the
   pin_ports! pin). Test bodies verbatim.
4. **`test/kd79_blob_apiversion_wire_test.exs`** — setup →
   `resilient_clear!`; parent fixtures routed through `put_parent!/3` whose
   failure message names the fixture; unused private `ensure_store/0`
   deleted; KD-COVERS comment, literal `@witnessed "2023-05-01"` pin,
   `invalid_api_version?/1` oracle, all four bodies verbatim.
5. **`test/data_plane/blob_hardening_test.exs`** — setup →
   `resilient_clear!` + unchanged receipted clear order (tables ensured
   BEFORE delete_all_objects). No other change (perf face untouched).
6. **`test/auth_enforce_test.exs` flatten** —
   - ONE setup discipline: `save_restore(auth_mode: :enforce,
     sts_signing_secret: @secret)` plus an explicit restore-only leak shield
     for `:token_audiences`/`:trusted_proxies` (load-bearing — dropping it
     leaked `token_audiences=[]` from the wave5 fail-closed court into every
     later accept-leg: 8 order-dependent failures witnessed, fixed in-batch).
   - Merged fuzz registry, redundancy-only deletions, every surviving row
     named: (a) cycle-7 www-authenticate fuzz header-grammar rows (malformed
     scheme, empty token, CRLF) moved into the merged
     `@header_grammar_rows` table (superset of the former lens-8 family-A
     table + cycle-7 rows + wave2 leading-whitespace row; exact-status-list
     style; one-challenge printable-ASCII pin asserted per refusal row;
     claim-class rows kept in the cycle-7 court); (b) former lens-6
     byte-mutation corpus folded into the class-partitioned JWS corpus as
     truncate-sig + no-dots operators, six-class message pin on every row,
     seed `@merged_fuzz_seed {20_261_015, 20_261_016, 20_261_017}` (as
     spec'd); lens-6 200-mutant test deleted (redundant corpus, law
     preserved);
     (c) four trusted-proxy styles collapsed to `save_restore/1`
     (fwd-authority test, CIDR /8 + /16, uppercase-HTTPS, byte-case, lens4
     fwd fuzz, malformed-proxies); the mid-body toggling fail-closed test
     keeps its explicit form (legitimate toggle, disclosed).
   - Section structure: describe "A. challenge matrix + sub-code corpus"
     wraps the opening matrix; existing describes renamed to section letters
     ("E+I. egress-handoff joint court…", "H+L. STS mint/verify round-trip…",
     "J. KD-94 cosmos AAD header shape"). Physical test order retained (rows
     verbatim; describe placement is labeling, ExUnit order is declaration
     order either way) — disclosed deviation from a full physical A-L
     regroup: a full reorder of ~90 blocks was rejected on row-survival risk
     (falsifier §0 outranks layout).
   - Mechanical row-inventory check (quoted strings old vs new, git HEAD
     vs working tree): 744 old rows, 746 new rows; 11 name-level diffs, all
     accounted: folded operators/labels renames (crlf in token→"crlf in
     value", leading ws→"leading whitespace", `Basic #{good}`→rebuilt
     `Basic #{t}`, `#{h}.#{p}`→`#{gh}.#{gp}`) and deliberate test/describe
     renames (no lens-generation history). Zero behavior rows dropped.
7. **`test/mix_auth_scope_test.exs`** — unchanged (per spec §3.6: it IS the
   reference implementation of the pattern).

## Validation (real output, MIX_BUILD_ROOT=_build-ft-b5)

| run | command | result |
|---|---|---|
| eventgrid pair | `mix test test/eventgrid_{topics_arm,conformance}_test.exs` | 21 tests, 0 failures |
| egress file | `mix test test/egress_dispatch_test.exs` | 107 tests, 0 failures (x2) |
| co-batch e3 | `mix test egress_dispatch eventgrid_topics_arm eventgrid_conformance` | 128 tests, 0 failures (x2, i21-observable co-batch) |
| kd79 | `mix test test/kd79_blob_apiversion_wire_test.exs` | 4 tests, 0 failures |
| blob_hardening | `mix test test/data_plane/blob_hardening_test.exs` | 116 tests, 0 failures (x2) |
| auth_enforce | `mix test test/auth_enforce_test.exs` | 128 tests, 0 failures (x2) |
| full B5 batch | 7 files co-run | 380 tests, 0 failures (x2) |
| wire tier | `mix test --include amqp_wire test/wire test/tls_test.exs test/wire_tier_refusal_sweep_test.exs test/mcp_wire_test.exs test/kd78_child_lattice_wire_test.exs` | 91 tests, 0 failures (67.9s) |

Full `mix test` (spec §5.6): started, killed at the 10-minute background
cap under concurrent-lane load (B0/B4 in-flight lib edits also forced two
compile-freeze waits, healed on retry per the compile-freeze SLA) —
NOT completed by this lane; the batch validation contract (touched files
green x2 + wire tier green) is the gate this receipt stands on.

## Deviations / disclosed seams

- `stop_existing_tree/0` in `SmaltTest.Wire` (not `SmaltTest.Lifecycle`) —
  shared-file avoidance, test_helper.exs owned by B0 this window.
- CORS default-leg explicit delete+restore (get_env-default semantics).
- The setup leak-shield for token_audiences/trusted_proxies is explicit
  (restore-only semantics save_restore cannot express).
- auth flatten: section describes are labeling-in-place, not a physical
  A-L reorder (row-survival risk rejection, above).
- Co-batch timing flake, diagnosed on the third 380-test run: the
  pre-existing `@perf_budget_ms 180` pagination perf contract
  (blob_hardening, EXPLICITLY out of rewrite scope, carried verbatim)
  flipped 321ms > 180ms under concurrent-lane CPU load. Solo runs green
  x2 (116/0 twice); the budget test is the documented degraded-host
  timing-sensitive class (test_helper SMALT_MAX_CASES law). Pre-existing
  environmental sensitivity, not session-introduced; the rewrite gate is
  the two consecutive green full-batch runs plus the solo greens.

## Falsifier check (§0 inventory)

No §0 row dropped (mechanical inventory above); KD-15 challenge params
unchanged (assert_challenge + grammar pins verbatim); no bearer sub-code
genericized (all `error.message ==` exact pins carried); typed
InvalidQueryParameterValue envelopes unchanged (R155 W1 + comp whitelist
courts untouched, mutation check (d) satisfied: the pinned header+XML+message
assertions are intact in both egress and blob_hardening files).
