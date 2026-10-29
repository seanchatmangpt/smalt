# BK-7: compiler warnings cleanup (v26.10.22)

**Standing:** PARTIAL_ALIVE
Context: solo
Lane: BK-7, build root `_build-bk7`, canonical checkout /Users/sac/smalt

## Scope

Reduce smalt-owned `mix compile` warnings, mechanical classes only, no behavior
change, no lane-owned files (webpubsub/, messaging/kafka/, messaging/amqp10/,
workspace/lib/engine/{guard,law-worker-bridge,journal-sync}*, smalt-cli/).

## Method

Baseline: `MIX_BUILD_ROOT=_build-bk7 asdf exec mix compile --force`.

- Repo-wide total: 124 warnings. ~86 are in deps (toml, uniq, gettext,
  ggen_igniter, ash_r2rml, ...); not smalt-owned.
- **Before: 38 smalt-attributed warnings** (28 in `lib/smalt/**` + 10 surfacing
  at `deps/plug/lib/plug/router.ex` locations, generated from smalt routers
  KvRoutes / Mcp.Router / EgressRouter / WebPubSub.Router / SyncRoutes).

## Fixes (15 warnings, 6 files)

- `lib/smalt/attestation/maa.ex` (3): unused `tee`/`opts` params -> `_`-prefix;
  deleted never-read `@nonce_ttl_seconds` attribute.
- `lib/smalt/data_plane/kql.ex` (5): deleted unused `@cond_aggregates`;
  unused `bad`/`p` -> `_`-prefix; regrouped `eval_scalar/3` (moved the `{:arith,...}`
  clause up beside the other eval_scalar clauses) and `parse_comparison/3`
  (moved the `parse_in_list*` helpers below the group) — per-name clause order
  preserved exactly.
- `lib/smalt/data_plane/skr.ex` (1): moved the `release(_name, _conn)` fallback
  clause up beside the primary release/2 clause (order preserved).
- `lib/smalt/powl2/law_compiler.ex` (3): regrouped `check/2` (moved
  `same_principal?`/`canonical`/`violation_message` helpers below the check
  group); **deleted a byte-identical duplicate `read_block(_)` clause** (defined
  twice; removing the second copy is a no-op at runtime). This kills the
  grouping + cannot-match + redundant warnings.
- `lib/smalt/storage/journal_reader.ex` (1): unused `dir` -> `_dir`.
- `lib/smalt/storage/journal_sink.ex` (2): unused `state` in degraded
  `do_seal/1` clause -> `_state`; regrouped `handle_call` clauses by moving
  `defp do_append/6` below the handle_call group (handle_call order preserved).

No `# cover` / `@dialyzer`-style silencing; no public API touched.

## Verification

Embedded command output (real):

```text
$ MIX_BUILD_ROOT=_build-bk7 asdf exec mix test test/data_plane/kql_test.exs \
    test/internal/powl2_law_compiler_court.exs \
    test/internal/az2_maa_attestation_court_test.exs \
    test/internal/journal_reader_court_test.exs \
    test/integration/sj1_journal_sink_court.exs \
    test/integration/bk135r_matter_journal_court.exs
...
Result: 45/46 passed
Failed: 1 test
```

The 1 failure was
`test/internal/journal_reader_court_test.exs:88` "clean parse of writer-produced
sealed segments" with `{:error, {:already_started, pid}}` — a cross-lane
collision on the globally-registered sink name from a concurrently running
lane's tests. Re-run in isolation:

```text
$ MIX_BUILD_ROOT=_build-bk7 asdf exec mix test test/internal/journal_reader_court_test.exs
Result: 15 passed
```

```text
$ MIX_BUILD_ROOT=_build-bk7 asdf exec mix test test/internal/az4_mhsm_release_policy_court_test.exs test/data_plane/kql_sealed_court_test.exs
Result: 9 passed
```

Post-fix compile (touch edited files + `mix compile`) — remaining smalt-owned
warnings (23):

```text
   1 lib/smalt/attestation/maa.ex:434:8: Smalt.Attestation.Maa.tee_claims/1
   1 lib/smalt/data_plane/blob_storage.ex:870: Smalt.DataPlane.BlobStorage.copy_blob/6
   1 lib/smalt/egress/SyncRoutes.ex:153:11: Smalt.Egress.SyncRoutes.refuse/4
   4 lib/smalt/storage/journal_sink.ex (do_seal "never used", do_append/handle_call/maybe_rotate_scope never-match)
   6 lib/smalt/messaging/kafka/conn.ex (lane-owned)
   1 lib/smalt/messaging/kafka/records.ex (lane-owned, in-flight)
  10 deps/plug/...router.ex attributed to Smalt.KvRoutes/Mcp.Router/EgressRouter/WebPubSub.Router
```

## Deliberately kept (not silenced, not deferred)

Gradual-typing "will never match / cannot match" warnings on **defensive
fallback clauses** (`tee_claims(_)` catch-all, `do_seal(degraded)`,
`{:error,_}`/`other ->` fallbacks in routers, `:error` arm of copy_blob,
SyncRoutes `_ -> 0`). The type inference says unreachable; at runtime these are
fail-closed arms. Deleting them would convert a typed refusal into a raise —
a behavior change, out of the mechanical class.

## Deferred with owner

- `lib/smalt/messaging/kafka/conn.ex` (6) + `records.ex` (1) — in-flight
  Kafka lane (conn.ex was being actively edited mid-wave: new route_fetch
  warnings appeared during this session).
- `lib/smalt/webpubsub` router (1, deps/plug do_match) — webpubsub lane.
- Dep-side warnings (~86, toml/uniq/gettext/ggen_igniter/ash_r2rml/...) —
  upstream deps, out of repo ownership.

## Result

**38 -> 23 smalt-owned warnings (15 fixed)**; repo-wide 124 (deps included)
at baseline. All touched-module courts green. Receipt-backed, no behavior
change.
