# IMPL-11 — AR-WIRE-02 adoption on the OTP-29 pinned tree

Context: pair(concurrent IMPL lanes collapsed shared-file comment stacks mid-run; coordinator tick commit swept shared deltas)

- Date: 2026-10-21
- Lane: IMPL-11 (writer, OTP-29), canonical checkout /Users/sac/smalt
- Toolchain: erlang 29.1.2 + elixir 1.20.4-otp-29 (asdf), MIX_BUILD_ROOT=_build-impl11
**Standing:** ALIVE (all four court faces green; two defects caught and fixed mid-court)

## Task vs. tree state (premise corrections)

1. **Dedupe premise stale.** The dispatch claimed duplicate
   `defguardp int_in/3` copies in file_share.ex at ~6 and ~388. Ground
   truth at lane start: exactly ONE defguardp per module (file_share.ex:13),
   no intra-file duplicate ever existed. What the unblock passes DID leave
   was (a) a stacked duplicate comment block in cosmos.ex (IMPL-4 + 2x
   IMPL-2 re-pin comments) and (b) a stale orphan comment in file_share.ex
   ("blob_storage.ex:1485 — Elixir 1.20 does not import is_integer/3 …"),
   superseded by the direct-BIF delegate. Concurrent IMPL lanes collapsed
   the cosmos comment stack and re-pinned all four int_in delegates to
   `:erlang.is_integer(x, lo, hi)` during this lane's run (coordinator
   tick commit 4326bd6 swept the blob_storage.ex + file_share.ex deltas
   into that checkpoint). This lane removed the stale file_share.ex
   orphan comment (dedupe residue) — that is the full extent of its
   dedupe delta.
2. **`is_integer/3` is not usable bare in Elixir 1.20.4 guards.**
   Witnessed twice: `cannot find or invoke local is_integer/3 inside a
   guard` and `cannot invoke remote function :erlang.is_integer/3 inside
   a guard` — a defguard DELEGATING to `:erlang.is_integer/3` compiles
   and is behaviorally exact (probe: 5 in, 500/-1/"x" out). The `int_in`
   delegate is therefore the adopted compiled form; conversions below
   route through it.

## Conversions (3 sites; dispatch's 3-5 estimate)

- `blob_storage.ex:1194` `validate_period_days`: `is_integer(days) and
  days >= 0 and days <= @max_retention_days` → `int_in(days, 0,
  @max_retention_days)` (both bounds live in the head; no fallback arm
  needed).
- `cosmos.ex` both `analyticalStorageTtl` heads (create ~234, replace
  ~363): bounded head `int_in(ttl, 0, @max_cosmos_ru_guard)` + bignum arm
  `is_integer(ttl) and ttl >= 0` (the `>= 0` in the arm is load-bearing —
  see defect 1).
- `cosmos_query_metrics.ex` `request_charge/1`: bounded head
  `int_in(scanned_bytes, 0, @max_charge_guard_int)` + bignum arm
  `is_integer(scanned_bytes) and scanned_bytes >= 0` (same load-bearing
  bound), body hoisted to `charge_body/1`.

Not converted (disclosed): `event_hubs.ex:341 receive_events` and
`key_vault_actions.ex` `paging_int` — half-bounded public faces whose
conversion would require duplicating whole multi-clause bodies or
inventing bounds that change admission; zero semantic gain.

## Defects caught by the court (this lane's own first drafts were wrong)

- **cosmos ttl bignum arm admitted -1** (witnessed: first
  `cosmos_analytical_ttl_test.exs` run 3/4, `analyticalStorageTtl: -1`
  returned 201 with the value stored instead of typed 400). Root cause:
  bare `is_integer(ttl)` fallback arm is broader than
  `is_integer(ttl) and ttl >= 0`. Fixed to carry `ttl >= 0`.
- **request_charge bignum arm admitted -1** (witnessed by direct probe:
  -1 returned 2.5 instead of FunctionClauseError). Same root cause;
  fixed identically. There is NO ExUnit covering request_charge's
  negative refusal — the probe is the standing negative witness for it.

## Chicago court (real faces, real refusals; all on _build-impl11 / OTP 29)

- `mix test test/internal/cosmos_analytical_ttl_test.exs
  test/integration/blob_parity_test.exs
  test/integration/cosmos404_typed_error_test.exs` → **exit 0, 11 passed,
  0 failed** (includes the typed-400 negative ttl cases at create AND
  replace).
- Transient immutability court (real BlobStorage engine, removed after
  the run; script at /tmp/impl11_blob2.exs lineage):
  `neg=-1 → :error/400`, `huge=10^13 → :error/400`, `ok=30 → :ok`,
  `max=146000 → :ok`, `over=146001 → :error/400` — witnessed line:
  `IMPL11 neg=:error/400 huge=:error/400 ok=:ok max=:ok over=:error/400`.
- request_charge probe (`mix run --no-start`): `0→2.5, 1024→2.6,
  bignum→879609302223.3, -1→FunctionClauseError (refused)`.
- `mix compile` exit 0 on _build-impl11 (pre-existing warnings only,
  e.g. plug router disjoint-compare, hw/frame pin warning — none from
  the converted sites).

## Environment notes (honest failures)

- Port 8443 was held by the shared substrate during probes; probes that
  needed a full app boot failed with :eaddrinuse and were re-run as
  self-booting mix test / --no-start forms. No other lane's process was
  touched.
- lib/smalt/json_compat.ex (another lane's in-flight edit) broke compile
  twice mid-session (syntax error, then undefined functions); this lane
  polled for green windows and ran courts inside them. No unblock fix
  applied to it (compile-freeze SLA disclosure: none needed; it went
  green on its own both times).

## Diff (this lane's authorship; 4326bd6 carries the first two files)

- lib/smalt/data_plane/blob_storage.ex — validate_period_days head
  (committed in coordinator tick 4326bd6)
- lib/smalt/data_plane/file_share.ex — stale orphan comment removed
  (committed in coordinator tick 4326bd6)
- lib/smalt/data_plane/cosmos.ex — two ttl heads + load-bearing bignum
  arms (working tree)
- lib/smalt/data_plane/cosmos_query_metrics.ex — request_charge
  conversion (working tree)

## Replay

```
export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-impl11 mix compile
MIX_BUILD_ROOT=_build-impl11 mix test test/internal/cosmos_analytical_ttl_test.exs \
  test/integration/blob_parity_test.exs test/integration/cosmos404_typed_error_test.exs
```
