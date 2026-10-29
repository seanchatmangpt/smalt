# NEXT_WAVE — v26.10.29 typed backlog (post finish-wave, 2026-10-29)

State at write time: finish-wave landed and pushed `4a9f31c5..c46b844f`
(12 atomic commits; 15/15 lane courts ALIVE; compile green both envs;
lane-clean freed 20.09 GiB). Full offline census: 1269/1412 green, 143
failures classified below. This file is the dispatch surface for the next
wave; move items to receipts as they close.

## W1 — wiring (undocked milestone scope; ~130 census failures live here)

1. Mount the egress delegator family (SqlIngestRoutes, EventHubsRestRoutes,
   SyncRoutes, GraphRoutes, …). Constraints from the L11 receipt (commit
   c46b844f):
   - mount AFTER `maybe_parse_body` — delegator-first answers a flat 400
     InvalidBody because `with_valid_body/2` consumes `conn.body_params`;
   - delegator BEFORE the queue plane — `POST /{hub}/messages` shares its
     path shape with Queue Storage `/{account}/{queue}/messages`;
   - double-parse is safe: Plug.Parsers skips when body_params is already
     fetched (deps/plug/lib/plug/parsers.ex:288).
2. Wire the 4 remaining new routers into the gateway mux: AcrRouter,
   ResourceHealthRouter, ContainerGroupsRouter, ApimGateway. FunctionsRouter
   is the only mounted one (r13 receipt, landed in ba47b220).

## W2 — registers + docs

1. KD rows for the 9 new planes (acr, apim, azure_cache, container_groups,
   functions, iac_export, resource_health, sb_delivery, chaos) — zero
   coverage today; mint-worthy divergences already cited in lanes'
   r13-r17 receipts (docs/jira/v26.10.28/receipts/).
2. WIRE_PARITY rows for the same 9 planes (no GAP tokens minted yet).
3. Pre-existing `just docs-dod-check` failure: 4 missing v26.10.25 wrap
   artifacts (FINAL.md, RECEIPTS.md, court-x2 receipt, release-receipt.json).
4. Full v26.10.29 window wrap: receipts/ dir does not exist; sequence is
   WOs -> receipts -> GAP -> court-x2 -> publish-dry -> FINAL.md/RECEIPTS.md
   (docs/jira/v26.10.14 is the exemplar).

## W3 — residual census failures (143 at 1269/1412)

1. ~130 undocked scope — the same population W1 wiring fixes: SB REST x7,
   marketplace x9, throttle x5, kv_ec x5, blob/kd courts, apim-wire x4,
   eventgrid x4, cosmos x3, signins x3, tenant-fence x4, bk132 x4,
   kd-conf x4 (full log: /tmp/census_full.log, second run).
2. ~11 concurrency/sibling-lane:
   - blob_sharedkey x3 — passes standalone; suite-isolation flake;
   - graphlaw gate court x4 — fails against smalt-04's then-uncommitted
     admission_gate.ex (re-check after their lane lands);
   - ~5 run-to-run delta between census passes (148 vs 143).
3. L9 typed pre-existing pair: queue_message_ct (KD-123 urlencoded
   content-type) and amqp10_bk116 (R-116-1, Smalt.Amqp10.Connection
   transport_closed).

## W4 — separate track (decomposition censuses, done, awaiting waves)

1. graphlaw + ash_graphlaw: biggest files are GENERATED (registry.ex,
   refusal.ex) — decomposition is a pack-template change (cross-repo,
   ggen marketplaceSha bump), not a hand-split. Hand-written monoliths
   (mutation/parity/host; sql_ast/law/duckdb) have wave plans with
   mutation-court pin constraints.
2. purrdf: 251 Tier-1 src files; native X.rs + X/ idiom; extraction costs
   are the 5 hygiene gates (thread-local LEDGER rows move same-commit,
   include_str! paths, helpers-ledger, terminal-hygiene, rustdoc). Wave A
   (leaf) -> Wave B (state machines) -> Wave C (test relocation), verify
   `cargo test -p <pkg> --locked` + clippy -D warnings per step.

## Not run

`just court-x2` (needs `just quiet-check` first + free ports 9443/9444/
8443/5672/5673) — withheld by instruction at finish time.
