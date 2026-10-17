# Receipt — R173 (KQL order-by numeric parity)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PARTIAL_ALIVE
- **Date:** 2026-10-16 (W10 docs lane)

## Subject

`lib/smalt/data_plane/kql.ex` — order-by parity with real Kusto semantics: a
column sorts numerically only when every present value parses as a number
(`numeric_column?/2`); keys are uniform `{tag, value}` tuples so number/string
branches never mix incomparable terms, and missing columns sort first
(`{0, ""}`), stable under Erlang's sort.

## Verification (2026-10-16, W10 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/data_plane/kql_test.exs
23 tests, 0 failures
$ MIX_BUILD_ROOT=_build-lane204 mix test test/egress_dispatch_test.exs test/wire/egress_wire_test.exs
115 tests, 0 failures
```

Probe leg: the session-cited "probe 11/0/0 post-restart" is not reproducible as
a single artifact on this tree. Live probe candidates loud-skip or lack their
runtime: c6 sentinel probe exit 3 (`SKIP: azure SDK deps not importable`), JS
sdk_probe exit 3 (`set SMALT_SDK_ROOT`), PY probe venv absent. Substrate was UP
throughout (9443/9444/5672/5673, pid 882). No probe artifact producing an
11/0/0 triple was locatable (`grep -rn "11/0/0" scripts test docs/jira/v26.10.16`
→ no output). Recorded as unlocated rather than faked; unit + wire parity is
witnessed green.

Standing: PARTIAL_ALIVE (unit 23/0 + dispatch+wire 115/0 witnessed; the
session's 11/0/0 probe leg unlocated on this tree).
