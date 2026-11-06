# Open items — smalt, next wave (v26.11.6 closure, lane R-SMCLOSE)

Standing: ALIVE — census re-read from disk 2026-11-06, exits re-run this
session.

## Open items

1. **AAD network test failures (pre-existing, 2)** —
   `test/integration/cosmos_aad_auth_header_test.exs` and
   `test/integration/redis_wire_entra_auth_test.exs` are network-dependent
   and carry pre-existing failures. Not re-run by this lane (lane contract:
   not the cheap gate set); not fixed. Next wave: run, classify, and either
   fix or register as KD rows per the SDK-parity register law (a registered
   divergence is lawful; a silent skip is not).
2. **Dirty tree: untracked file** — `lib/smalt/aoq/e2e_clearinghouse.ex` is
   untracked (git status 2026-11-06). Present-locally-but-untracked fails
   fresh checkouts (CI red class). Next wave: review, then commit or delete
   — owner decides; this lane reports, does not fix.
3. **Cross-repo tests are fixture-gated** —
   `test/data_plane/cosmos_auth_cross_repo_test.exs` fails loudly without
   `KD_G19_FIXTURE` (0/2, flunk naming the env var). This is lawful loud
   skip, but full-suite runs without arcus on disk will show 2 reds; next
   wave may register a KD row or a skip-tag so census tooling reads it as a
   registered divergence rather than a failure.
4. **KD-A1 smalt-side re-pin** — per arcus
   `docs/jira/v26.11.6/kd-final-census.md`: smalt
   `lib/smalt/arm/dns.ex:119-123` refuses CAA records with 400 while arcus
   `internal/dialect/azure/tenancy_dns.go:215` admits CAA in closed set.
   Next wave: smalt-side re-pin (admit CAA on PUT) or an acceptance receipt
   registering the refusal as canonical.
5. **Elixir toolchain pin friction** — system elixir (1.19.5) fails the
   project's `~> 1.20` requirement; asdf 1.20.4-otp-29 required. Any lane
   or CI runner without the asdf pin gets an immediate Mix error, not a
   test result. Candidate: pin mechanically (mise/asdf install hook or CI
   setup step).
