# EXPL5-R1 — T1/T2 repairs (MHSM non-list constraint fail-open, DTDL cyclic extends)

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: EXPL5-R1
- **Files owned**: `lib/smalt/data_plane/mhsm.ex`, `lib/smalt/dtdl/converter.ex`, `test/internal/expl5r1_court_test.exs`
- **Closes**: EXPL5-T1, EXPL5-T2 (from `docs/jira/v26.10.22/receipts/expl5-dataplane-errc.md`)

## Changes

- **EXPL5-T1** (`lib/smalt/data_plane/mhsm.ex`): `policy_groups/1` gains a
  `%{"anyOf" => other}` clause (non-list anyOf) and explicit type fences for
  non-list `allOf`/`assertions` in the fallthrough clause (extracted to
  `policy_groups_list/3`). All malformed constraint types now refuse with the
  typed 403 `KeyReleasePolicyViolation` envelope (fail-closed) instead of
  falling through to `:ops_only` → unconstrained release. Moduledoc law line
  added.
- **EXPL5-T2** (`lib/smalt/dtdl/converter.ex`): `resolve_iface/2` →
  `resolve_iface/3` with a threaded `MapSet` visited-set; a revisit raises
  `ConvertError` with `reason: :circular_extends` → `{:error, {:circular_extends, ref}}`
  via the existing `to_reason/1` path (consistent with `:unknown_extends`).
  Moduledoc Returns list updated.

## Embedded probe output (real, this session, MIX_BUILD_ROOT=_build-expl5r1)

T1 (`mix run --no-start` against the real compiled module):

```
T1a: {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => "Secure Key Release refused: release policy anyOf must be a list, got: \"oops\""}}}
T1b: {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => "... release policy anyOf must be a list, got: %{}"}}}
T1c: {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => "... release policy allOf must be a list, got: \"oops\""}}}
T1d: {:error, 403, %{"error" => %{"code" => "KeyReleasePolicyViolation", "message" => "... release policy assertions must be a list, got: 42"}}}
ctrl-list-mismatch: {:error, 403, ...KeyReleasePolicyViolation...}
ctrl-list-match: :ok
ctrl-ops-only: :ok
```

T2 (`mix run --no-start`, Task-bounded like the EXPL-5 witness):

```
cyclic: {:error, {:circular_extends, "dtmi:a;1"}}
self:   {:error, {:circular_extends, "dtmi:s;1"}}
acyclic: ok shapes=2 interfaces=["dtmi:p;1", "dtmi:c;1"]
```

(Both cyclic forms previously hung >2s non-terminating per the EXPL-5 witness.)

## Court

`mix test test/internal/expl5r1_court_test.exs test/internal/expl3_dataplane_repairs_court_test.exs test/internal/w2_dtdl_converter_court_test.exs test/internal/az4_mhsm_release_policy_court_test.exs` (MIX_BUILD_ROOT=_build-expl5r1):

```
Result: 26 passed
```

7 new legs (4 malformed-type refusals + controls; cyclic + self-extends typed
prompt return + acyclic control); 19 regression legs across the EXPL-3 and
KD-167 (az4/w2) courts stay green.

## Falsifier status

- T1: `{"anyOf": "oops"}` refuses typed (was `:ok` allow-all) — falsified and closed.
- T2: cyclic A↔B and self-extends return `{:circular_extends, _}` promptly
  (was non-terminating) — falsified and closed.
