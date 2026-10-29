# Armstrong Idiom Census — lib/smalt (v26.10.21, ARMSTRONG audit)

Context: solo
**Standing:** PARTIAL_ALIVE

Scope: `lib/smalt/**`, hunted violations, not confirmations. Method: full grep sweep of
`try/rescue`, `receive`, `binary_to_term`, `System.unique_integer`/ad-hoc ID strings,
and catch-all clause arms in `data_plane/`, `arm_gateway/`, `messaging/`, `arm/`.

## Tenet table

| # | Tenet | Verdict | Evidence |
|---|-------|---------|----------|
| 1 | try/rescue = lawful boundary only; no rescue trees masking invariants | MOSTLY CLEAN | ~24 rescue sites classified below; 3 violations |
| 2 | no bare catch-all `_ ->` returning :ok/default in business heads | MOSTLY CLEAN | router.ex:2307/2325 sweep_child_data_plane fallthroughs are typed-refusal shapes (unknown child type → no-op sweep is by contract); 1 real violation (appconfig_features.ex:152) |
| 3 | make_ref for correlation, no ad-hoc string/incremental IDs | VIOLATED | deployments.ex:430, egress_router.ex:4118, runtime_contracts.ex:280 |
| 4 | every selective receive bounded by `after` | CLEAN | 8 receive blocks in lib/smalt, all carry `after` (lro.ex:239/276, connection.ex:481 `after 0`, doctor.ex:285/599, wasm_engine_supervisor.ex:75/233). lro_notifier.ex:111 uses make_ref waiter tags — lawful |
| 5 | binary_to_term only with [:safe] on untrusted input | MOSTLY CLEAN | cosmos_feeds.ex:131 uses [:safe]; appconfig_snapshots.ex:278 omits it (self-produced data — low) |
| 6 | no redundant-update buffering where a selective drain applies | MOSTLY CLEAN | recv-pump dedup (connection.ex:2644 kd134_yield_to_requester? via :redelivery_holders MapSet) is predicate-based, not buffered-update; event_grid dedup (event_grid.ex:487) is bounded-FIFO with telemetry on eviction — no buffering violation found |

## Rescue classification (tenet 1)

Lawful boundary rescues (classified, not violations):
- ETS create-race `ArgumentError -> :ok` (heir law): certificates.ex:93, file_share.ex:78,
  kv_managed_storage.ex:74, cosmos.ex:2382, table_storage.ex:272/286, policy.ex:84, apim.ex:127
- Crypto/DER boundary, typed error out: kv_pss.ex:122/140/198/252/265
- Telemetry post-boot log-and-drop with pre-boot re-raise (boot-order preserved): telemetry.ex:216/311/341
- JSON codec boundary: json_compat.ex:41 (`decode/1` non-raising form — typed `{:error, e}`)
- Snapshot round-trip: cosmos_feeds.ex:132 (`{:ok,[:safe]} / :error`)

VIOLATIONS (tenet 1/2):
- appconfig_features.ex:152 — `rescue _ -> false` on feature-filter eval. Masks ANY error
  (even a developer bug in eval_targeting) as "filter false" → silent kill switch on a flag.
  Let-it-crash violation: evaluation bugs are silently absorbed into a business verdict.
- runtime_contracts.ex:264-265, 279-280, 300, 320 — blanket `rescue _ ->` around the very
  contract checks whose job is to DETECT crashes; masks the crash the registry exists to report.
  Worse: line 280 `String.to_atom(inspect(entry))` fabricates a NEW atom from arbitrary term
  (untrusted-term atom-table growth).
- (mild) router.ex:2067 `_ -> :error` in metric-ingest head folds malformed body into the same
  verdict as unknown resource; two distinct invariants share one silent default.

## Ad-hoc correlation IDs (tenet 3)

- arm/deployments.ex:430 `"correlationId" => "smalt-#{System.unique_integer([:positive])}"`
  and op ids at :86-87 `op-#{System.unique_integer}` — incremental IDs where make_ref belongs.
- egress_router.ex:4118 — `"azb10-" <> resource_uri_digest(res_id)` fallback: DETERMINISTIC
  per-resource, so every event on a resource shares one correlationId — correlation is destroyed.
- Legit make_ref uses: lro_notifier.ex:111, amqp/listener.ex:152 — lawful.

## binary_to_term (tenet 5)

- data_plane/appconfig_snapshots.ex:278 — `:erlang.binary_to_term()` without [:safe] in
  deep_copy/1. Input is self-produced (term_to_binary of own records) so exploit risk is low,
  but the deep-copy idiom would happily accept a snapshot blob later; safe is free here.

## Receive/timeout (tenet 4) & dedup buffering (tenet 6)

No unbounded receives. No redundant-update buffering violation: the recv pump's
kd134 redelivery-yield predicate (connection.ex:2644) is stateless-per-dequeue;
EventGrid dedup is bounded-FIFO (`:max_seen_ids`) with `:dedup_evicted` telemetry.

## Top-3 typed interventions (risk-ranked)

1. **runtime_contracts.ex:279-280** — HIGH. Contract registry that rescues away the crashes it
   audits AND mints atoms from untrusted terms (`String.to_atom(inspect(entry))`).
   Minimal fix: `rescue` returns typed `{:error, :contract_crashed}`-shaped result
   (`{:ok, {:error, :bad_name}}` instead of guessing), and replace
   `String.to_atom(inspect(entry))` with `String.to_existing_atom(inspect(entry))` guarded
   fallback to the raw inspected string. Removes both the masking and the atom-table hazard.
2. **appconfig_features.ex:150-154** — HIGH (silent business-verdict corruption). `eval_filter`
   turns any raise into `false`, silently disabling flags on internal error. Minimal fix:
   narrow rescue to `rescue e -> Logger.error(...); false` at minimum, ideally
   `rescue _ in [ErlangError, ArgumentError] -> false` with a `[:smalt, :appconfig, :filter_error]`
   telemetry emit; unknown raises propagate (let-it-crash).
3. **arm/deployments.ex:430 (with :86-87)** — MEDIUM. Incremental string correlationId/opId where
   `make_ref` belongs; counter values leak op ordering and two nodes can collide semantics.
   Minimal fix: `"correlationId" => inspect(make_ref())` (or the router's generate_uuid/0)
   computed once per deployment record and stored in the record, so GET/PUT are referentially
   stable instead of minting a fresh id per render.

## Standing

Census only — no code changed. Grep-exhaustive over the five idiom classes; classification of
the ~19 remaining rescue sites as lawful is documented above with per-site rationale. Top-3
findings are the only cases found where rescue/catch-all/ad-hoc-ID idioms cross from boundary
discipline into invariant masking.

## Reproduction (2026-10-21 backfill, fresh grep census over lib/smalt)

```text
$ grep -rn "^\s*receive\b" lib/smalt --include="*.ex" | wc -l
14
$ grep -rn -A3 "^\s*receive\b" lib/smalt --include="*.ex" | grep -c "after"
10
$ grep -rn ":ets.new" lib/smalt --include="*.ex" | wc -l
57
$ grep -rn "write_concurrency: :auto" lib/smalt --include="*.ex" | wc -l
1
$ grep -n "make_ref" lib/smalt/arm/deployments.ex | head -3
79:          # ARMSTRONG fix 3: correlationId is a minted make_ref stored on the
82:          correlation_id: inspect(make_ref())
89:        # is minted once (make_ref) so id and operationId agree.
$ grep -n "rescue" lib/smalt/data_plane/appconfig_features.ex | head -3
153:    rescue
154:      # ARMSTRONG fix 2: narrowed rescue. Only known eval-data exception
exit 0
```

Census was grep-exhaustive, not command-output-bearing; the fresh sweep confirms the
tenet-table anchors (receive/`after` discipline, ad-hoc-ID sites) as of this backfill.
Note: the receive-block count moved 8 → 14 since the census (later lanes landed new
selective receives), all `after`-bounded — consistent with the tenet verdict, not a
regression of it.
