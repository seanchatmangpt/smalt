# EXPL-3R: data_plane fail-open repairs (T1/T2/T3) — repair lane receipt

**Standing**: ALIVE — all three repairs landed with real court legs (12/12
green) plus per-fix shim non-vacuity (each revert flips the court red) and
targeted regressions green (az4 + queue suites, 9/9).
**Context: solo**

Repairs the three code-read findings from
`expl3-dataplane-errc.md` (F1/F2/F3 = T1/T2/T3 here). No commit (per lane
contract — coordinator owns git).

## T1 — blob service-properties three-case parse (F1)

File: `lib/smalt/data_plane/blob_soft_delete.ex`
(`set_delete_retention_policy/2`, `set_versioning_enabled/2`).

Diff shape: both setters now discriminate three cases instead of the
fail-open `_ ->` fallback:

- empty body = legal clear → store disabled, `{:ok, disabled}` (200);
- envelope-parseable body = parse + apply (Days 1..365 rules unchanged);
- non-empty non-envelope body = typed
  `{:error, 400, "InvalidXmlDocument", "Missing required XML element ..."}`,
  prior ETS policy state UNTOUCHED (the old code stored `enabled:false` and
  returned 200 — silent disable of an active policy).

Court legs (T1a–T1e in
`test/internal/expl3_dataplane_repairs_court_test.exs`): garbage `<foo/>` PUT
→ 400 + prior policy `{"enabled"=>true,"days"=>7}` UNCHANGED (asserted by
re-reading the real ETS); empty body → 200 disabled; valid envelope → applied;
same for the versioning face.

Court transcript:

```
MIX_BUILD_ROOT=_build-expl3r mix test test/internal/expl3_dataplane_repairs_court_test.exs
Result: 12 passed
```

Shim non-vacuity (T1): revert the garbage-body branch to the old fail-open
clear — court flips 11/12, Failed: 1 (T1a). Restore sha256 byte-exact
(before = restored = `03b1b61793d6bf6ed79227bc8d1c6de4f3e27d8c7a0a5f8f432e6f3a90c353db`).

## T2 — queue `x-ms-ttl` typed refusal (F2)

File: `lib/smalt/data_plane/queue_storage.ex` (`parse_ttl/1` + `put_message/4`).

Diff shape: `parse_ttl` re-aligned with its siblings
(`parse_numofmessages`/`parse_visibility_timeout`) — returns `{:ok, ttl}` or
`{:error, 400, "InvalidHeaderValue", ...}` instead of silently substituting
`@default_ttl_ms`; `put_message/4` now plumbs it through the `with` (the
existing `{:error, _, _, _}` else clause carries it). Legal forms preserved:
absent header → 7-day default; `-1` → explicit never-expire (far-future
absolute expiry, year 9999, real Azure parity — previously `-1` also fell into
the silent default, which the receipt flagged).

Court legs (T2a–T2c): `x-ms-ttl=abc` → 400 InvalidHeaderValue AND the dequeue
finds NO message (state assertion); `-5` → 400; `-1` → 201 with
`ExpirationTime ... 9999`, retrievable; `60` → applies; absent → default.

Shim non-vacuity (T2): revert the malformed branch to `{:ok, @default_ttl_ms}`
— court flips 10/12, Failed: 2 (T2a, T2b). Restore sha256 byte-exact
(`3bcdf2727ff6d95ba55ae0f3f2300e108d3c4db51a4ae952a40346812b3bd98c`).

## T3 — MHSM degenerate empty constraint sets refuse (F3)

File: `lib/smalt/data_plane/mhsm.ex` (`evaluate_policy/2`, `policy_groups/1`).

Diff shape: `policy_groups/1` now returns `:ops_only | {:refuse, reason} |
{:groups, list}` — a policy that carries `anyOf`/`allOf`/`assertions` keys
with an EMPTY list is a degenerate constraint set and refuses with typed 403
KeyReleasePolicyViolation ("empty anyOf (no assertion can match — vacuous
allow-all refused)" / "empty constraint set"); ops-only policies (no
claim-constraint keys at all, e.g. `allowed_operations` only) keep `:ok`.
Moduledoc law line added. Non-empty matching assertions admit unchanged.

Court legs (T3a–T3d): `anyOf: []` with fully satisfying claims → 403;
`allOf: []` and `assertions: []` → 403; matching non-empty anyOf/assertions
(incl. nested x-ms-isolation-tee resolution) → :ok; mismatched non-empty →
403 (unchanged). The in-flight AZ4 court's leg 4 negative fixture
("empty anyOf refuses") — which could not have passed against the pre-fix
module — now genuinely passes on the real TLS-twin wire (leg 4 green).

Shim non-vacuity (T3): `{:refuse, _} -> :ok` — court flips 10/12, Failed: 2
(T3a, T3b). Restore sha256 byte-exact
(`deaac28dca147abdab52f47876f84792beef5d4987d5a03f8d58375db9a34ade`).

## Verification ladder run

| run | command | exit | result |
|---|---|---|---|
| 1 | `mix compile` (MIX_BUILD_ROOT=_build-expl3r, asdf elixir 1.20.4-otp-29) | 0 | warnings only |
| 2 | repairs court | 0 | 12 passed |
| 3 | shim T1 (fail-open revert) | 1 | 11/12 — court red, T1a fails |
| 4 | restore T1 (sha byte-exact) + green re-run | 0 | 12 passed |
| 5 | shim T2 | 1 | 10/12 — T2a/T2b fail |
| 6 | restore T2 (sha byte-exact) + green re-run | 0 | 12 passed |
| 7 | shim T3 | 1 | 10/12 — T3a/T3b fail |
| 8 | restore T3 (sha byte-exact) + green re-run | 0 | 12 passed |
| 9 | regression: `mix test test/internal/az4_mhsm_release_policy_court_test.exs test/integration/queue_message_ct_test.exs test/integration/cross_surface_determinism_test.exs` | 0 | 9 passed |

## Disclosure

- One compile-freeze event: the concurrent kafka lane's in-flight
  `lib/smalt/messaging/kafka/{records,conn}.ex` broke the shared compile for
  ~3.5 min during my runs; I waited out the owner's fix (poll loop, ~40s
  intervals, resolved at attempt 5) — no unblock edit applied by this lane.
- Test files touched by other lanes mid-run (`az4_mhsm_release_policy_court_test.exs`
  is untracked in-flight from the AZ wave) — my T3 fix is what makes its leg-4
  negative fixture real; regression run confirms 4/4 az4 legs green.
- NOT committed (lane contract). Files owned by this lane:
  `lib/smalt/data_plane/blob_soft_delete.ex`, `queue_storage.ex` (parse_ttl +
  put_message only), `mhsm.ex`, `test/internal/expl3_dataplane_repairs_court_test.exs`
  (new), this receipt.
