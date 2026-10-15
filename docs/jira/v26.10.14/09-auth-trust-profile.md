# V261014-09 — Trust Profile: hostile key_id typed refusal, @type refusal vocabulary, 2^53-1 boundary reconciliation

- **Release:** v26.10.14
- **Priority:** P1 (crash) / P2 (spec contract) / P3 (boundary off-by-two) / minor (docs, optional perf)
- **Owned files:** `lib/smalt/trust_profile/trust_profile.ex`, `test/trust_profile_test.exs`, `lib/smalt/auth/bearer.ex` (optional 5b), `lib/smalt/auth/body_cache.ex` (moduledoc only, 5a)
- **Regression fence:** item 4 is already fixed on this branch — do NOT undo it.

## 1. P1 — `sign/1` crashes on hostile `key_id` (ArgumentError leak)

**Finding (verified):**
- `do_sign/1` (:232) canonicalizes the JWS **header** with the raising helper: `header_json = jcs!(header)` where `header = %{"alg" => "RS256", "typ" => @envelope_version, "kid" => envelope.key_id}`.
- `jcs!/1` (:334-339) raises `ArgumentError` on any `jcs/1` refusal.
- A hand-built struct with invalid-UTF-8 `key_id` therefore escapes `sign/1`'s `@spec` as a raw `ArgumentError`.
- The payload path is correctly fenced (`{:ok, payload_jcs} <- jcs(payload)` + `else` :237-246 mapping `{:bad_json_value,_}`/`{:non_canonical_number,_}` → `{:error, {:malformed_envelope, :bad_fields}}`).
- `validate_envelope/1` (:527) only checks `is_binary(e.key_id)` — invalid UTF-8 passes.
- The `else` comment (:237-243) claims "audience/**key_id**" coverage; for key_id it is currently false (audience goes through the payload; key_id only through the header). The fix makes the comment true.

**Fix:** route the header through the non-raising `jcs/1` inside the existing `with`:

```elixir
with :ok <- epoch_sanity(envelope),
     {:ok, payload_jcs} <- jcs(payload),
     {:ok, header_json} <- jcs(header) do
  ...
end
```

No new `else` clause needed (`{:error, {:bad_json_value, _}}` is already mapped).

**Test pin** (immediately after the hostile-audience test at `trust_profile_test.exs:142-144`):

```elixir
test "sign/1: hostile key_id (invalid UTF-8) refuses in-spec as bad_fields, not a crash" do
  {:ok, env} = TrustProfile.new(subject: "utf8-key-id")
  assert {:error, {:malformed_envelope, :bad_fields}} =
           TrustProfile.sign(%{env | key_id: "k" <> <<0xFF>>})
end
```

Pre-fix: ArgumentError (crash). Post-fix: typed refusal.

## 2. P2 — `:UNKNOWN_PROFILE` refusal is outside `@type refused`

**Finding:** `@type refused` (:53-54) admits only `:PQC_NOT_PROVISIONED | :HYBRID_NOT_PROVISIONED`; `sign/1`'s profile case (:206-207) returns `{:refused, :UNKNOWN_PROFILE, ...}`. The published type is a false contract for consumers matching on `refused()`.

**Fix (recommend A):** widen the type:

```elixir
@type refused ::
        {:refused, :PQC_NOT_PROVISIONED | :HYBRID_NOT_PROVISIONED | :UNKNOWN_PROFILE, String.t()}
```

(Option B — remap to `{:error, {:malformed_envelope, :bad_profile}}` — changes observable shape; rejected.)

**Pin:** `{:refused, :UNKNOWN_PROFILE, msg} = TrustProfile.sign(<env with profile: :bogus>)`, `is_binary(msg)` — freezes the widened type against silent remapping.

## 3. P3 — canonical-integer bound is neither 2^53 nor 2^53-1

**Finding:** `canonical_integer/1` (:368): `abs(n) <= 9_007_199_254_740_952`. 2^53 = …992; I-JSON max = 2^53−1 = …991. The literal matches neither (digit slip, 952 vs 991/992): legal integers **…953..…991 are refused today**. Moduledoc (:39) and `@doc jcs/1` (:287) say 2^53; tests pin the wrong literal (`trust_profile_test.exs:561-566`, `:650-654`). Code+tests agree with each other, both disagree with the documented contract.

**Fix — reconcile everything to 2^53−1 (I-JSON / RFC 8785 §3.2.2.3):**

```elixir
@max_safe_integer 9_007_199_254_740_991  # 2^53 - 1, I-JSON / RFC 8785 §3.2.2.3
defp canonical_integer(n) when abs(n) <= @max_safe_integer, do: {:ok, Integer.to_string(n)}
```

1. Code: guard uses `@max_safe_integer`.
2. Moduledoc (~:39): "|n| <= 2^53 - 1 emitted; |n| >= 2^53 REFUSED".
3. `@doc jcs/1` (~:287): same.
4. Tests: boundary pins:

```elixir
assert {:ok, "9007199254740991"} = TrustProfile.jcs(9_007_199_254_740_991)
assert {:ok, "-9007199254740991"} = TrustProfile.jcs(-9_007_199_254_740_991)
assert {:error, {:non_canonical_number, 9_007_199_254_740_992}} = TrustProfile.jcs(9_007_199_254_740_992)
assert {:error, {:non_canonical_number, -9_007_199_254_740_992}} = TrustProfile.jcs(-9_007_199_254_740_992)
```

(Update the :650-654 propagation test literals to the new boundary; `…953` remains refused either way.)

## 4. Regression fence — do NOT undo the `bad_epochs` else-clause

`do_sign/1`'s `else` (:246) maps `{:error, {:malformed_envelope, :bad_epochs}}` explicitly — verified present and load-bearing (before it existed, `sign/1` on `not_before == expires_at` or reversed epochs raised CaseClauseError instead of returning typed; pinned by `trust_profile_test.exs:241-257` and `:427-443`, matching `@spec sign/1` :185-188). Any edit to the `with`/`else` in item 1 must preserve this clause verbatim.

## 5. Minor items

**5a. BodyCache moduledoc overstates the duplicate-key contract** (`body_cache.ex:5-9` implies general duplicate form-parameter refusal; the STS consumer, `router.ex` ~:189-215, checks `grant_type` only). Doc-only edit: reword to "detects duplicate `grant_type` parameters (the one key it fences); other duplicated parameters fall through to Plug's last-wins decoding."

**5b. (Optional) Joken signer rebuilt per request** (`bearer.ex:237-252` constructs a fresh `%Joken.Signer{}` per invocation). Cache keyed on the secret value in `:persistent_term`. Low priority — skip if the cache-key invalidation story is unclear; do not block the release.

## Acceptance criteria

1. Hostile key_id pin green (pre-fix it crashes).
2. `mix dialyzer` clean for `Smalt.TrustProfile`; `:UNKNOWN_PROFILE` a legal `refused` reason.
3. `jcs(9_007_199_254_740_991)` → ok; `jcs(9_007_199_254_740_992)` → typed refusal; code, moduledoc, @doc, tests all state 2^53−1 consistently.
4. The `:bad_epochs` else-clause intact; its existing tests still pass.
5. `mix test test/trust_profile_test.exs test/auth_enforce_test.exs` green.

Order: items 1→3 (code+tests together) → suites → `mix dialyzer` → 5a docs → optional 5b.
