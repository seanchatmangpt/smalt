# BK-SKIPFIX — appconfig/rg leg substrate-down classifiers (BK-TESTBED-F1 close)

**Standing:** **ALIVE** (both ways executed on real runs; DOWN via shim-court on a
pinned dead port, restore byte-exact; substrate never bounced — other lanes
ride it)

Context: solo

## Change

`popcorn_demo/lib/popcorn_demo/live_appconfig.ex` and `live_rg.ex` run/0 else
clauses now classify a refused/blocked loopback hop with the same regex the
main live leg uses (`PopcornDemo.Live.format/1`,
`~r/econnrefused|failed to fetch/i`): matching errors return
`{:skip, "appconfig=SKIP(substrate-down:<step>:<reason>)"}` /
`{"rg=SKIP(substrate-down:<step>:<reason>)"}` instead of `FAIL`. Any other
step fault is still a typed FAIL. Exit contract unchanged — the smoke gate
stays keyed on the `live=` fragment.

`live_rg.ex` moduledoc receipt list updated (the old "skip is a test-tier
face, not produced by the walk itself" note is stale now).

## Witness, substrate UP (2026-10-22, ports 8443/9443 listening)

```
$ cd popcorn_demo && mix run -e 'IO.inspect(PopcornDemo.LiveAppConfig.run()); IO.inspect(PopcornDemo.LiveRg.run())'
{:ok, "appconfig=OK(popcorn-ac-4482:kv+flag-lifecycle)"}
{:ok, "rg=OK(5-rows)"}
```

(post-fix UP re-witness on restored files: `popcorn-ac-5638:kv+flag-lifecycle`,
`rg=OK(5-rows)`; leg tests `8 passed`)

## Witness, substrate DOWN (shim-court: @base/@sts/@arm pinned to dead port 1)

```
{:skip,
 "appconfig=SKIP(substrate-down:health:{:httpc, {:failed_connect, [{:to_address, {~c\"127.0.0.1\", 1}}, {:inet, [:inet], :econnrefused}]}})"}
{:skip,
 "rg=SKIP(substrate-down:token:{:httpc, {:failed_connect, [{:to_address, {~c\"127.0.0.1\", 1}}, {:inet, [:inet], :econnrefused}]}})"}
```

RESTORE: `sha256sum -c` on both files OK (byte-exact). Shared substrate was
never touched (nc 8443/9443 succeeded before and after). No FAIL
misclassification observed: the old shape `appconfig=FAIL(fetch)` /
`rg=FAIL(fetch)` is gone on the down path.

## Non-vacuity

The BEFORE behavior (FAIL on substrate-down) is witnessed in
`docs/jira/v26.10.22/receipts/bk-popcorn-live.md`; the AFTER behavior (SKIP)
is witnessed above on the same error shape (`:econnrefused` from Httpc). The
flip is the proof.

## Falsifier status

- Leg emits `=FAIL` on a refused loopback hop: REFUTED (witnessed SKIP on
  port-1 econnrefused for both legs).
- Leg emits SKIP on a real step fault (non-refused error): REFUTED by
  construction — the classifier only matches the refused/fetch family; other
  `{step, reason}` errors keep the FAIL path (8/8 leg tests pass UP).
