# W2-1: PopcornDemo.Redact — shared receipt redaction

**Standing:** ALIVE (all suites green, host walk live=OK)

## Scope (files owned)
- `popcorn_demo/lib/popcorn_demo/redact.ex` (new): `PopcornDemo.Redact.fragment/1`
  — JWT pattern `~r/eyJ[A-Za-z0-9_-]{10,}/` → `eyJ<redacted>`, 120-char cap,
  non-binary inspect-first.
- `popcorn_demo/lib/popcorn_demo/smoke.ex`: `fail/2` detail routed through
  `PopcornDemo.Redact.fragment/1`. OK strings untouched (byte-identical).
- `popcorn_demo/lib/popcorn_demo/application.ex`: leg `fragment/1` catch-all
  now builds `"leg=FAIL(" <> PopcornDemo.Redact.fragment(other) <> ")"`.
  `composed_receipt/0` unchanged elsewhere — byte-compatible (witnessed below).
- `popcorn_demo/test/redact_test.exs` (new): 5 tests, hardcoded fake-JWT
  strings through Redact directly, the Smoke receipt line, and the leg
  catch-all composition; asserts token absence + 120-char cap.

## Diff
- smoke.ex: 1 line changed (fail/2 → Redact).
- application.ex: catch-all line changed (rest of that file's diff is other
  lanes' concurrent work in the same checkout, not W2-1's edit).

## Compile
`MIX_BUILD_ROOT=_build-w21 mix compile` → 0 errors (pre-existing warnings only).

## Test output (real)
- `mix test test/popcorn_demo/live_test.exs` → `Result: 7 passed`
  (incl. redaction test)
- `mix test test/redact_test.exs` → `Result: 5 passed`
- `mix test test/popcorn_demo_test.exs` → `Result: 1 passed`

## Host walk (real)
```
mix run -e 'r = PopcornDemo.Live.run(); IO.puts(PopcornDemo.Live.format(r))'
→ popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
mix run -e 'IO.puts(PopcornDemo.Application.composed_receipt())'
→ blob=FAIL(put-blob:http-409:ContainerLocked …); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:2-matched)
```
The blob FAIL is real substrate state (WORM-locked container, http-409) and
arrives pre-redacted/capped — hygiene holds on a real FAIL path.

## Compile-freeze disclosure (SLA)
Another lane's in-flight `lib/popcorn_demo/live_containers.ex` froze shared
compilation (`@type "Microsoft.App/containerApps"` collides with the typespec
`@type` macro → `Kernel.TypespecError`). W2-1 applied the minimal unblock
rename `@type` → `@ca_type` (3 lines: attribute + 2 use sites) and discloses
it here per the same-checkout-fanout SLA.

## Toolchain
Host OTP 28.3.1 / Elixir 1.20.3 (OTP 29 inets broken per lane R9);
`MIX_BUILD_ROOT=_build-w21`.

## Falsifier status
Not applicable (capability lane, not a claim court). Regression surface is
redact_test.exs; any future JWT leak through the three wired surfaces fails it.
