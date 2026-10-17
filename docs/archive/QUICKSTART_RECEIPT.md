# Quickstart Verification Receipt

Lane 19 (README) — 2026-10-14, checkout `~/smalt`, tree under active
multi-lane mutation during this run (compile windows had to be awaited; see
BLOCKED rows).

## Command / transcript / verdict table

| # | Command (README step) | Actual behavior | Verdict |
|---|---|---|---|
| 1 | `mix deps.get` | Exit 0. Resolved in 0.16s, all deps already present (no downloads). Prints one Hex auth-expired warning (session-scoped, not repo drift) and pre-existing advisory notes (e.g. bandit 1.12.5 EEF-CVE-2026-105659). | PASS (no-op as claimed) |
| 2 | `just up` | Recipe runs `mix run --no-halt` in the FOREGROUND and never returns — a reader following the README verbatim would block on the first boot. Substrate itself boots correctly: ARM gateway on 9443 (plain HTTP) + 9444 (HTTPS), egress 8443, AMQP sb 5672, eh 5673. `GET /metadata/endpoints` returns 200 JSON discovery over http://127.0.0.1:9443. | DRIFT FIXED — README said nothing about foreground blocking or the HTTP/TLS split; corrected |
| 3 | `curl http://127.0.0.1:9443/metadata/endpoints` | 200 with JSON discovery (`managementEndpoint` etc.). Note: `https://` to 9443 is refused/reset — TLS lives on 9444. | PASS |
| 4 | `node test/sdk-smoke/run.mjs` (while substrate up, README order) | Exit 3 preflight: `[sdk-smoke] port 9443 is occupied` — the harness boots its own substrate, so the README's `just up` → smoke order is self-contradictory. Standalone (9443 free): harness boots substrate (~1.5s), runs real SDK clients (ARM token, blob, cosmos, AMQP sender, census). Current verdict exit 1 with 5 failing checks (blob create/download, cosmos round-trip/etag, ARM subscription list, AMQP sender round-trip, census suite) — same surfaces as the failing mix test tiers, i.e. in-flight lane rewrites, not quickstart drift. | DRIFT FIXED (order); result FAILING = BLOCKED: in-flight lanes on blob/cosmos/AMQP surfaces (transient — same modules failing in mix test) |
| 5 | `just tf-plan-smoke` | Exit 2, deterministic: `bash: -c: line 1: unexpected EOF while looking for matching '` — quoting bug in the Justfile recipe itself (line ~38); the fixture plan never runs. | BLOCKED: Justfile recipe quoting bug (not a docs fix; recipe owner must repair) |
| 6 | `mix test` (full) | Compiles, runs 410 tests + 1 doctest. Failure count moved across three runs during the window: 36 → 77 → 83 failures (exit 2). Failing surfaces concentrated in EventGrid / EventHubs / AMQP connection / store checkpoint tests — modules with visible in-flight lane edits (placeholder `test/...exs` files were observed mid-run). One earlier run aborted at compile (`eventgrid_conformance_test.exs` TokenMissingError placeholder); one run SIGKILLed mid-suite by a concurrent lane's process cleanup. | BLOCKED: in-flight lanes (transient) — 410 tests, 83 failures as-of 16:5x run; not a quickstart doc issue |
| 7 | `just down` | Exit 0. Prints "No pid file" when the substrate was not started via `just up` (my boot used `mix run --no-halt` directly because of the shared `/tmp/smalt.pid` collision across concurrent lanes — `just down` from one lane kills another lane's substrate). | PASS with caveat (pid-file collision under concurrent lanes; single-user use is fine) |
| 8 | `just doctor` | Exit 0 when ports free (all PASS, substrate-liveness NOT-RUNNING is a PASS). When 9443 is held it FAILS exit 1 with a machine remediation block — correct behavior, and it caught the smoke harness's lingering substrate. One transient false-looking state: port freed by the time `lsof` ran but doctor still saw the hold for one run. | PASS |

## Fixes applied to README.md

- Quickstart order: `just doctor` and the SDK smoke tier now run BEFORE
  `just up`, because the smoke harness spawns its own substrate and exits 3
  if 9443 is occupied.
- `just up` annotated as FOREGROUND (it never returns); TLS control surface
  9444 and HTTP 9443 called out explicitly.
- Note added that tf-plan-smoke boots its own substrate.

## Not fixed (outside owned files / in-flight)

- `just tf-plan-smoke` recipe quoting bug (Justfile line ~38) — deterministic
  breakage, needs the Justfile owner.
- `mix test` 83 failures and SDK-smoke 5 failing checks — in-flight lane
  rewrites of blob/cosmos/AMQP/EventGrid surfaces at time of writing.
- Shared `/tmp/smalt.pid` collision when multiple sessions/lanes boot the
  substrate concurrently (each `just down` kills whichever substrate wrote
  the pid file last).
