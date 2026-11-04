# D111: cors_plug removal regression — verification receipt

Standing: ALIVE (verification-only; fix attribution is V4's kv7 wire-court lane)

**Subject**: smalt main @ 4d6c20ef (`4d6c20efd003503213e97df48ca116965c28d35a`)

**Finding**: commit 9a3d0a79 removed the cors_plug hex dep while 3 call sites
(arm_gateway/router.ex:57, egress_router.ex:61, mcp/router.ex:111 ×2) still
called `CORSPlug` — UndefinedFunctionError runtime 500 before route dispatch.

**Fix attribution**: the kv7 wire-court lane (V4) landed `lib/smalt/http/cors.ex`
(`Smalt.HTTP.CORS`, byte-identical restoration of cors_plug's pinned wire law)
and rewired all 3 call sites in commit 4d6c20ef, pushed to origin/main
(`git ls-remote origin main` → `4d6c20efd003503213e97df48ca116965c28d35a`).
The FIX lane's working tree carried the same migration as an uncommitted
disclosed compile-freeze unblock; `git diff origin/main` over the four files
was empty — no duplicate landing, tree fast-forwarded clean.

**Verification at 4d6c20ef** (asdf shims, mix test):

```
mix test test/integration/kd143_rules_persistence_test.exs \
        test/internal/bk14_kd143_sqlfilter_persistence_test.exs \
        test/integration/cost_management_test.exs \
        test/integration/cost_forecast_test.exs \
        test/integration/arm_providers_test.exs \
        test/integration/cors_headers_knob_test.exs \
        test/integration/healthz_cors_test.exs
Result: 42 passed
```

Named D111 red suites all green:
- sb-rules KD-143/bk14: kd143_rules_persistence_test.exs + bk14_kd143_sqlfilter_persistence_test.exs — passed
- cost management: cost_management_test.exs + cost_forecast_test.exs — passed
- arm_providers: arm_providers_test.exs — passed
- CORS wire law: cors_headers_knob_test.exs + healthz_cors_test.exs — passed (10 tests)

`mix compile` exit 0 (only pre-existing warnings, e.g. common.ex:887).

No code change in this lane. Fix is V4's; this receipt is the D111 close-out
verification.
