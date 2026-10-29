# JA-R3: JA-16 Defect Fixes (D1/D2/D3)

**Standing: PASS** — all three JA-16 defects fixed, compile green, targeted suites green, D1 falsifier re-run flat. `Context: solo`

Lane: JAR3 (audit-repair lane, files `lib/smalt/cosmos_sql.ex`, `lib/smalt/auth/x_arr_cert.ex`, `lib/smalt/messaging/eh_throttle.ex`). Pre-edit `git diff --stat` on all three files: clean (no BK-7 collision). Source: `docs/jira/v26.10.21/receipts/ja16-robustness-census.md` D1-D3.

## D1 — cosmos_sql.ex wire-sourced atom minting (P1)

`lex_word/2` minted `String.to_atom(String.downcase(w))` for every word of a wire-sourced query (reached via `Smalt.CosmosSql.parse/2` ← `data_plane/cosmos.ex:1906`).

**Fix**: keyword matching is now a binary comparison against `@keyword_strings` (compile-time `Enum.map(@keywords, &Atom.to_string/1)`); `String.to_existing_atom/1` is reached only for words that ARE keywords, whose atoms already exist in `@keywords`. The atom table never grows from query content.

- `lib/smalt/cosmos_sql.ex`: added `@keyword_strings` after `@keywords`; rewrote `lex_word/2` keyword branch (annotation cites JA16-D1 + frame_codec.ex:800 law).

**Falsifier re-run** (mix run --no-start, Elixir 1.20.4-otp-29, `_build-jar3`):

```
q = 50_000 distinct junk tokens ("zzz1 zzz2 ... zzz50000")
RESULT parse1=:error parse2=:error atom_before=39708 after_run1=39708 after_run2=39708 delta=0
```

Atom count flat across two parses of 50k distinct tokens (the census falsifier `parse(String.duplicate("zzz ", 50_000))` repeated-token variant also can't grow it). Keyword parse of `SELECT c.age FROM c WHERE c.age > 3 ORDER BY c.age DESC` returns `{:ok, ast}`.

## D2 — x_arr_cert.ex silent CA-load failures (P2)

Module had zero Logger references; `ca_certs/0` and `decode_ca_file/1` returned `[]` silently on stat failure, missing config, read failure, or non-PEM/non-DER content — every request 401s with no diagnostic.

**Fix**: `require Logger` added; `Logger.error` on each failure branch naming the path/reason:

- stat failure branch (missing/unreadable CA file)
- no `:ca_certfile` configured branch
- `File.read` error branch (new `{:error, reason}` clause in `decode_ca_file/1`)
- raw-DER fallback decode rescue (now logs `Exception.format(:error, e)`)

Fail-closed semantics unchanged (`[]` still returned; persistent_term caching unchanged).

## D3 — eh_throttle.ex silent quota fallback (P3)

`hub_record_quota/1` had `rescue _ -> nil` silently degrading to the default quota window.

**Fix**: `require Logger` added; rescue now logs `Logger.warning` with hub + `Exception.format(:error, e)` and emits typed telemetry `:telemetry.execute([:smalt, :event_hubs, :throttled], %{store_fault: 1}, %{hub: hub, cause: :store_lookup_failed})` — the module's existing telemetry idiom (`@telemetry`, executed at line ~132 for refused counts) — before returning nil (fallback semantics unchanged).

## Verification

- `MIX_BUILD_ROOT=_build-jar3 mix compile` → exit 0 ("Generated smalt app"; pre-existing plug/router warnings only, none in the three owned files).
- `mix test test/data_plane/cosmos_sql_raise_test.exs test/internal/eh_throttle_wiring_test.exs` → **29 tests, 0 failures**.
- No x_arr_cert-specific test file exists under `test/` (grep over `test/` — only the two suites above reference the owned modules).
- No sleeps, no mocks; falsifier is a real `mix run` over real parse calls with `:erlang.system_info(:atom_count)` observation.
