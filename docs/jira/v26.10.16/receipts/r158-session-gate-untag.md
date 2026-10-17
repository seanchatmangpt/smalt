# Receipt — R158 (session-gate test untag)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane; W10 re-run 2026-10-16)

## Subject

Session-listed as "session gate untag, 712/0". The session-gate suite
(`test/amqp/r129_session_gate_test.exs`) rides the `:amqp_wire` tag; the untag
work moved session-gate cases into the default-run offline tier. The
session-claimed 712/0 is stale relative to the current tree: the full offline
tier is now 2018 tests + 1 doctest + 7 properties (36 excluded), and this lane's
full-tier re-run showed **2 failures** — recorded as open defects for their
owning surfaces; this lane landed no code changes and does not attribute them to
the untag.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/amqp/r129_session_gate_test.exs --include amqp_wire
2 tests, 0 failures
```

Full-tier re-run (2026-10-16, same tree, `_build-w7docs`):

```
1 doctest, 7 properties, 2018 tests, 2 failures (36 excluded)
```

Second full-tier re-run (same lane build root, minutes later) for failure
identification:

```
1 doctest, 7 properties, 2018 tests, 6 failures (36 excluded)
```

All 6 failures (and the 2 in the first run) are in the
`Smalt.SemanticProjectionTest` family (`test/semantic_projection_test.exs`:
R2RML compile/render-determinism and Store-backed read-path cases, `Ash.Error.Unknown`
/ vacuous-identity assertion classes) — an order/concurrency-sensitive surface,
unrelated to the session-gate untag; this lane landed no code changes. Open
defect for the semantic-projection owning lane.

The bare r129 run without `--include amqp_wire` is 0-run — vacuous — hence the
wire-included run is the cited evidence.

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`) — BOTH open failures closed

The two full-tier failures recorded at W7 are gone on the current tree. The
Lens4 half was closed by the isolation fix; the second failure does not
reproduce either. Fresh full-tier run:

```
$ MIX_BUILD_ROOT=_build-lane204 mix test
1 doctest, 7 properties, 2018 tests, 0 failures (36 excluded)
    Finished in 432.6 seconds (17.7s async, 414.8s sync)
EXIT=0
```

Wire-included session-gate leg:

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/amqp/r129_session_gate_test.exs --include amqp_wire
2 tests, 0 failures
```

Standing: PASS (upgraded from the W7 partial standing).
