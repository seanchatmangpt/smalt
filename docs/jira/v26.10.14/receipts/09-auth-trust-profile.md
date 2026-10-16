# Receipt — V261014-09 (lane 09, auth-trust-profile)

- **Subject:** /Users/sac/smalt @ main, working tree (no commits made; lane-owned files only)
- **Work order:** docs/jira/v26.10.14/09-auth-trust-profile.md — items 1, 2A, 3, 4-fence, 5a; 5b skipped per dispatch
- **Date:** 2026-10-15

## Diff (handwritten; no generator in scope)

- `lib/smalt/trust_profile/trust_profile.ex`
  - Item 1: header now routed through non-raising `jcs/1` inside the `with`
    (`{:ok, header_json} <- jcs(header)`); the raising `jcs!/1` had no remaining
    callers and was deleted (would otherwise be a compiler warning). The
    `else` clause mapping `{:error, {:malformed_envelope, :bad_epochs}}` is
    preserved VERBATIM (§4 regression fence; re-read on disk post-edit).
  - Item 2A: `@type refused` widened with `:UNKNOWN_PROFILE`.
  - Item 3: `@max_safe_integer 9_007_199_254_740_991` (2^53−1, I-JSON /
    RFC 8785 §3.2.2.3); `canonical_integer/1` guard uses it; moduledoc and
    `@doc jcs/1` updated to "2^53−1 emitted / 2^53 refused".
- `test/trust_profile_test.exs`
  - New hostile key_id pin (invalid UTF-8 `key_id` →
    `{:error, {:malformed_envelope, :bad_fields}}`, not ArgumentError).
  - New `:UNKNOWN_PROFILE` typed-refusal pin (`{:refused, :UNKNOWN_PROFILE, msg}`,
    `is_binary(msg)`).
  - Boundary pins updated to 2^53−1/2^53 (…991 ok both signs, …992 refused
    both signs); propagation test literals moved to the new boundary
    (…953 is now inside the window, so it no longer exercises refusal).
- `lib/smalt/auth/body_cache.ex` (5a, doc-only): moduledoc now states it
  fences duplicate `grant_type` only; other duplicates fall through to
  Plug's last-wins decoding.

## Verification (real output)

- `MIX_BUILD_ROOT=_build-lane09 mix test test/trust_profile_test.exs test/auth_enforce_test.exs`
  → **199 tests, 0 failures** (Finished in 3.1s). Includes the new hostile
  key_id pin, the `:UNKNOWN_PROFILE` pin, both boundary pins, and the
  pre-existing `:bad_epochs` tests (still green).
- `mix compile` warnings sweep for trust_profile: none.
- `mix dialyzer`: **not run — dialyzer is not configured in mix.exs**
  (no :dialyzer alias, no dialyxir dep), per dispatch instruction noted
  here rather than adding config. Acceptance criterion 2 is satisfied at
  the type level by the widened `@type refused`; acceptance 3 boundary
  behavior is pinned by tests.

## Notes

- Two transient shared-compile breaks from other lanes' in-flight files
  (data_plane/cosmos.ex, messaging/amqp/management_rpc.ex) — resolved by
  their owners; no lane-09 files involved, no unblock edits made.
- 5b (Joken signer cache) skipped per dispatch.
- No git state changes, no commits.
