# EXPL-5 — data_plane ERRC read-only sweep (kql/skr/mhsm/dtdl/eventgrid/receipt)

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Scope**: `lib/smalt/data_plane/{kql,skr,mhsm}.ex`, `lib/smalt/dtdl/converter.ex`, `lib/smalt/eventgrid/push_router.ex`, `lib/smalt/receipt/vc_export.ex`, `lib/smalt/security/attestation.ex` (v26.10.22 surfaces). Read-only: no `lib/` or `test/` edits; probes ran as scratch scripts in /tmp against the real compiled modules (`mix run --no-start`, elixir 1.20.4-otp-29, OTP 29).
- **Excluded already-receipted work**: KD register (v26.10.22) rows checked (KD-106/167/169/170 etc.); none of the findings below are already registered.

## Embedded probe output (real, run this session)

Probe 1 — `mix run --no-start` against `Smalt.DataPlane.MHSM.evaluate_policy/2`:

```
== F1: non-list anyOf ==
F1-CONFIRMED: {"anyOf": "oops"} (string) → :ok (release ALLOWED, zero claim constraints)
F1b-CONFIRMED: {"anyOf": {...map...}} → :ok (ALLOWED)
control: list anyOf mismatch → 403 KeyReleasePolicyViolation (refused, as documented)
```

Probe 2 — `Smalt.DTDL.convert/1` under a 2s-bounded Task:

```
cyclic A<->B: STILL RUNNING AFTER 2000ms -> NON-TERMINATING (hang confirmed; killed probe)
self-extends: STILL RUNNING AFTER 2000ms -> NON-TERMINATING (hang confirmed; killed probe)
control acyclic: {:ok, ttl/shapes=2} returned
```

Probe 3 — compiled `Smalt.POWL2.LawCompiler.compile_shape/2` guard applied to non-map payloads:

```
guard.(%{"amount" => 1}) -> :ok
guard.([]) -> :ok
guard.("str") -> :ok
guard.(42) -> :ok
```

## Findings (ranked, with repair tickets)

### EXPL5-F1 (HIGH, W1 fail-open + premise rot) — MHSM: non-list `anyOf` bypasses all claim constraints
- **Where**: `lib/smalt/data_plane/mhsm.ex:91-123` — `policy_groups/1`.
- **Defect**: first clause guards `is_list(any_of)`; a policy carrying `anyOf` with a
  non-list type (string/map/number) falls to the second clause, where
  `has_all?`/`has_assertions?` are false → `:ops_only` → `:ok`. The release path
  (`SKR.policy_admits/2`) then derives and releases material with **zero claim
  constraints**. The moduledoc explicitly claims fail-closed ("Unknown conditions
  refuse (fail-closed, never allow)"); malformed-type anyOf is an allow-all —
  documented law contradicted by behavior.
- **Witness**: probe 1 above. Control (list anyOf mismatch) refuses 403.
- **Repair ticket EXPL5-T1**: in `policy_groups/1` add a clause
  `%{"anyOf" => other}` → `{:refuse, "anyOf must be a list"}` (typed
  KeyReleasePolicyViolation, consistent with the degenerate-empty-set refusal);
  fence with a mutation test asserting `{"anyOf": "oops"}` refuses.

### EXPL5-F2 (HIGH, F2-class DoS) — DTDL: cyclic `extends` never terminates
- **Where**: `lib/smalt/dtdl/converter.ex:149-164` — `resolve_iface/2` recurses
  into parents with no visited-set and no memoization; `convert/1` rescues only
  `ConvertError`, so `A extends B extends A` (or self-extends) recurses forever
  on **remote JSON input**.
- **Witness**: probe 2 above (cyclic + self-extends both >2s non-terminating on
  remote-shaped docs; acyclic control returns `{:ok, ...}` promptly).
- **Repair ticket EXPL5-T2**: thread a visited-set through `resolve_iface/2`
  (on revisit → `{:error, {:circular_extends, ref}}`, a new typed refusal
  consistent with `:unknown_extends`); fence with cyclic + self-ref doc tests
  asserting return within one scheduler window.

### EXPL5-F3 (MEDIUM, F4-class wrong-answer) — LawCompiler guard admits non-map `data`
- **Where**: consumed at `lib/smalt/eventgrid/push_router.ex:266`
  (`sub.guard.(ev["data"] || %{}) == :ok`); root cause in
  `Smalt.POWL2.LawCompiler` guard emission (non-map input matches vacuously).
- **Defect**: an event whose `data` is a JSON array/string/number passes the
  SHACL guard with `:ok` and is delivered to subscribers (WAL frame / SB
  message) as if shape-conformant. The sieve's documented contract ("shape
  match: guard.(event["data"] || %{}) == :ok (conformance)") is satisfied
  vacuously — a wrong success answer on malformed input.
- **Witness**: probe 3 above (compiled guard returns `:ok` for `[]`, `"str"`, `42`).
- **Repair ticket EXPL5-T3**: two options — (a) PushRouter pre-gate
  `is_map(ev["data"] || %{})` before guard, bumping a typed
  `:malformed_data` counter; or (b) fix guard emission in LawCompiler to refuse
  non-map targets (preferred: fixes every consumer); fence with
  `guard.([]) != :ok` court.

### EXPL5-F4 (LOW) — PushRouter `ingest/1` returns success on non-list/non-event input
- **Where**: `lib/smalt/eventgrid/push_router.ex:123` — `ingest(_other)` →
  `{:ok, %{matched: 0, ...}}`.
- **Defect**: a malformed batch (binary/integer/keyword-list-ish term) gets a
  200-shaped success with zero counters — silent best-effort drop (F3/F4
  class). Witnessed by code reading only (not probed).
- **Severity rationale**: low because the Plug face decodes JSON before calling ingest, so
  only direct callers hit it.
- **Repair ticket EXPL5-T4**: return a typed `{:error, {:malformed_batch, term}}`
  (or `:router_down`-style typed refusal) instead of a zero-count success.

### EXPL5-F5 (LOW) — KQL `run/2` off-contract error shape for non-string query
- **Where**: `lib/smalt/data_plane/kql.ex:82` — `run(_rows, _query)` returns
  bare `{:error, "query must be a string, rows a list"}` while the moduledoc
  and @spec pin `{:error, {:parse | :limit, msg}}`.
- **Chartox**: caller-shaped only (spec guard rejects first); type-shape drift,
  not exploitable. Witnessed by code reading.
- **Severity rationale**: caller-shaped only (spec guard rejects first); type-shape drift,
- **Repair ticket EXPL5-T5**: return `{:error, {:limit, "query must be a string, rows a list"}}`
  (or `{:parse, ...}`) to match the documented contract.

## Clean surfaces (audited, no defect found)

- `kql.ex` lexer/parser/eval: fuzz fences (invalid UTF-8, catch-all clauses),
  typed SYN- errors, null semantics — holds under the sweep classes.
- `skr.ex`: typed refusals throughout, try-wrapped RSA wrap, jti burn after
  wrap success (no nonce burn on failure), crash-class law on key name.
- `mhsm.ex` beyond F1: degenerate empty sets refuse; unknown conditions refuse.
- `attestation.ex`: typed `{:error, 400, ...}` refusals, rescue-wrapped payload
  hashing; no fail-open path found.
- `vc_export.ex`: term-authoritative field law, raises only on caller-shaped
  direct misuse; round-trip verify pins digest and cryptosuite.

## Verification commands

```bash
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
mix run --no-start /tmp/expl5_probe1.exs   # F1 witness (embedded above)
mix run --no-start /tmp/expl5_probe2.exs   # F2 witness (embedded above)
mix run --no-start /tmp/expl5_probe3.exs   # F3 witness (embedded above)
```
