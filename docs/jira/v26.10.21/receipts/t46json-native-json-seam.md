# T46JSON — native `:json` seam behind config flag (AR-WIRE-01 partial adoption)

Context: solo

**Standing:** **ALIVE (as-scoped)** — seam landed, court 5/5 green, adoption opt-in (`:jason` default).

Repo: /Users/sac/smalt · lane build root `_build-t46json` · 2026-10-21

## Diff

- **NEW `lib/smalt/json_compat.ex`** — `Smalt.JsonCompat.decode!/1`: engine
  seam. `config :smalt, :json_engine` (`:jason` default, `:native` = `:json`
  when `Code.ensure_loaded?(:json)` + `function_exported?(:json, :decode, 1)`).
  Normalizes `:json`'s `null` atom to `nil` recursively (maps/lists) so the two
  engines are structurally equal.
- **`lib/smalt/cosmos_authz_plug.ex:145`** — the ONE hot decode site swapped:
  `Jason.decode!(raw)` -> `Smalt.JsonCompat.decode!(raw)` (cosmos ACL body parse).
- **NEW `test/json_compat_test.exs`** — byte-equivalence court.

## Availability (host OTP 28.3.1, stdlib-7.2)

```
erl -noshell -eval 'io:format("otp=~s json_exported=~p~n",[erlang:system_info(otp_release), erlang:function_exported(json, decode, 1)]), halt(0).'
otp=28 json_exported=false
erl -noshell -pa /tmp -eval '... json:decode(<<"{\"a\":1.0,...}">>)'
which="/Users/sac/.erlmcp/otp-28.3.1/lib/erlang/lib/stdlib-7.2/ebin/json.beam" dec=#{<<"a">> => 1.0,...}
```

(`function_exported/3` is false until the module is loaded; `code:which(json)`
resolves — hence the seam uses `Code.ensure_loaded?(:json)` first.)

## Court output (real)

```
MIX_BUILD_ROOT=_build-t46json mix test test/json_compat_test.exs
[court] raw-:json null divergence: TYPED (atom null vs nil, seam normalizes)
[court] plain object: EQUIVALENT
[court] nested arrays: EQUIVALENT
[court] big integer: EQUIVALENT
[court] exponent float: EQUIVALENT
[court] float: EQUIVALENT
[court] booleans + null: EQUIVALENT
[court] unicode string: EQUIVALENT
[court] empty containers: EQUIVALENT
[court] cosmos query body: EQUIVALENT
5 tests, 0 failures
```

## Typed divergence (the failing case, before normalization)

Raw `:json` decodes JSON `null` to the **atom `null`**; Jason decodes to `nil`:

```
json: #{<<"a">> => null,<<"big">> => 123456789012345678901234567890,<<"e">> => 100.0,<<"f">> => 1.5,<<"n">> => 1}
jason: %{"a" => nil, "big" => 123456789012345678901234567890, "e" => 100.0, "f" => 1.5, "n" => 1}
```

All other classes byte-equivalent: arbitrary-precision integers preserved,
`1e2 -> 100.0` both engines, floats, unicode, empty containers. Falsifier for
the seam claim: any payload whose normalized `:json` output differs from
Jason — court asserts equality across 9 payload classes and fails on drift.

## Honorable failures (pre-existing, not session-introduced)

`MIX_BUILD_ROOT=_build-t46json mix test test/integration/cosmos404_typed_error_test.exs`
fails at app boot: `{:options, {:ciphers, [:"ECDHE-RSA-AES256-GCM-SHA384", ...]}}`.
Reproduced identically on the **default** build root — environmental/pre-existing
(cipher list vs host OTP 28), unrelated to this diff (diff touches one decode
call site). Not repaired in this lane.

## Commands / exits

| command | exit |
|---|---|
| `MIX_BUILD_ROOT=_build-t46json mix test test/json_compat_test.exs` | 0 (5/5) |
| `MIX_BUILD_ROOT=_build-t46json mix test test/integration/cosmos404_typed_error_test.exs` | 1 (pre-existing boot error, reproduced on default root) |
