# I25 — rewrite-drafts/sleeps.md §A: poll-replaceable sync-waits

Standing: **ALIVE** (7 sites converted, green x2; 3 sites skipped with typed reasons)
Context: slice(4 files x pass1/pass2 per table below)

Scope: §A conversions in `/Users/sac/smalt/docs/jira/v26.10.18/rewrite-drafts/sleeps.md`
(12 sites/7 drafts). Helper contract is the LIVE `SmaltTest.AssertEventually.eventually/2`
(`test/support/assert_eventually.ex`): fun returns `{:ok, v}` | `:retry` |
`{:retry, detail}` — NOT the draft's truthy-poll signature; drafts were adapted
to the real contract.

## Converted (7 sites)

- `test/lro_test.exs` (4): :144→~155, :338→~361, :402→~436, :1147→~1206.
  Store-level terminality polls (`Store.get(:smalt_operations, id)` →
  `%{"status" => "Succeeded"}`, deadline 5_000) at :155/:436/:1206; wire-GET
  poll (200 + Succeeded body, asserts verbatim below the poll) at :361.
- `test/store_dets_test.exs:35` — poll of the closed dets read
  (`probe_rows/1` over both mirrored files until both rows present), then the
  original asserts verbatim.
- `test/tls_test.exs:474` — tracer round-trip poll until publish-op log
  non-empty (was `Process.sleep(200)` + single receive with `after 5_000 -> []`,
  which silently produced `ops = []` and could vacuously pass downstream).
- `test/security/security_hardening_test.exs:1124` — poll until
  `GenServer.whereis(Smalt.Security.LedgerWriter)` is no longer the killed pid
  (nil ACCEPTED as Down-propagated: the writer restarts lazily on the next
  append, per the test's own comment — an eager-restart-only poll flunked and
  was corrected).

## Skipped (3 sites, typed)

- `smalt_ets_{composite,baseline}_identity` (:245/:106): converted per draft
  (eviction_pass + snapshot()==baseline poll). The composite run FAILED — and
  continued to fail identically AFTER full revert to the original
  sleep+pass code. Root cause is NOT this conversion: AZB-10's resource-write
  fan-out (commit de0c471) now enqueues `resourcewritesuccess` Service Bus
  rows (:smalt_sb_messages/:smalt_sb_queues) during the composite lifecycle,
  leaving identity residue. The old 10ms sleep was masking this (fence
  snapshotted before the async fan-out landed). Pre-existing failure on HEAD,
  not session-introduced by §A; both files restored byte-equal to HEAD
  (`git diff` empty). Needs a seam decision (exclude the azsim fan-out rows
  from the identity fence, or fix fan-out cleanup) before the draft's §A2
  conversion can land.
- `enclave_testbed.exs:835(/850)`: current file already re-classes the sleep
  `# SLEEP-CLASS: TIME-ADVANCE — ... no pollable observable` and is a dev-env
  `mix run` script where the test-env-only helper is unavailable (per the
  file's own comment). Skipped as already-classified B1.

## Validation (real output, MIX_BUILD_ROOT=_build-ft-sa)

```
== test/lro_test.exs pass1      37 tests, 0 failures
== test/store_dets_test.exs p1  5 tests, 0 failures (1 excluded)
== test/tls_test.exs pass1      20 tests, 0 failures
== test/security/hardening p1   65 tests, 0 failures
== test/lro_test.exs pass2      37 tests, 0 failures
== test/store_dets_test.exs p2  5 tests, 0 failures (1 excluded)
== test/tls_test.exs pass2      20 tests, 0 failures
== test/security/hardening p2   65 tests, 0 failures
```

Two fixups during landing (both corrected before the x2 gate):
- tls: `{:ok, ops} = eventually(...)` — helper returns the bare value, not a
  tagged tuple → MatchError; fixed to bare binding.
- security: whereis-poll required nil-as-success (lazy restart), else 5s flunk.

sleep-gate:

```
[SLEEP-GATE] PASS — 325 files, 0 unclassified sleep primitives
```

Delta: 7 fixed sync-wait sleeps retired (4 lro + 1 dets + 1 tls + 1 security);
0 new sleep sites; sleep-gate 0 unclassified. B1 sites in lro were separately
parameterized by the lrob lane (`SmaltTest.SleepWindows`) — out of §A scope.

## Handoffs

- Composite-ETS identity fence vs AZB-10 fan-out residue: seam decision needed
  (see above) — the §A2 draft conversion is blocked by it, not by the poll.
- Post-landing supersession (recorded 2026-10-18): a later lane commit
  d32129c ("LRO elapsed-delay backdating — 8 sites onto backdate_op/2")
  replaced the three store-level lro polls (:155/:436/:1206 above) with
  direct `backdate_op/2` backdating; the wire-GET poll (former :361, now
  ~:353) survives. The x2 gate above was witnessed on my landing as-of
  commit 4af0553-lineage; the superseding commit owns those sites now.
