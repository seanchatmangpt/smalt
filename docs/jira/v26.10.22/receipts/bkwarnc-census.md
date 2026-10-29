# Receipt: bkwarnc-census

**Standing:** ALIVE
Context: solo
Lane: BK-WARNCEN, build root `_build-bkwarnc`, canonical checkout /Users/sac/smalt

## Task

Close the stale compiler-warning count. Premise check first: the coordinator
brief said VALIDATION.md carried a stale "68 warnings" row. On disk,
`docs/jira/v26.10.22/VALIDATION.md` carries **no warning row at all**, and a
grep over `docs/jira/v26.10.22/` for `68.*warn` / `warn.*68` returns **0
hits** — no doc row in this window carries the 68 figure. The stale-prose
premise is stale itself; the count is closed by measured census instead.

## Census (mechanical, embedded output)

### 1. Elixir — clean-root force compile

```text
$ export PATH="$HOME/.asdf/shims:$PATH"
$ cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-bkwarnc mix compile --force
exit=0   (log: /tmp/bkwarnc_compile.log, 2063 lines)

Total: 99 Elixir warning blocks + 27 Erlang warnings repo-wide
Smalt-owned (BK-7 methodology: lib/smalt/** + deps/plug/lib/plug/router.ex
surfacing from smalt routers): 14
  - 4 in lib/smalt/**:
      lib/smalt/messaging/amqp/sas_verifier.ex:233:8  (clause grouping)
      lib/smalt/messaging/amqp/sas_verifier.ex:235:8  (clause grouping)
      lib/smalt/messaging/kafka/records.ex:173:7      (clause grouping)
      lib/smalt/webpubsub/events.ex:30:3              (unused require Logger)
  - 10 surfacing at deps/plug/lib/plug/router.ex from smalt routers
    (Smalt.Egress.KvRoutes.do_match/4 x3, Smalt.EgressRouter.do_match/4 x1,
    Smalt.Mcp.Router.invoke/2 x6)
Additional smalt-owned, outside the BK-7 surface (disclosed separately):
  - 5 src/*.erl 'catch'-deprecation warnings:
      src/smalt_lakehouse_mount.erl x1, src/smalt_store_heir.erl x1,
      src/smalt_webpubsub_hub.erl x3
  → 19 smalt-owned warnings overall.
Dep-internal remainder (80 Elixir blocks + 22 Erlang): jose, yamerl, rdf,
ggen_igniter, ash_phoenix, ex4pm, uniq, toml, ... (third-party pins).
```

Classification method: per-warning-block parse of the compile log; a block
is smalt-owned iff its primary `└─` location is `lib/smalt/**`, or its
primary location is `deps/plug/lib/plug/router.ex` and the block's terminal
attribution names a `Smalt.*` MFA. Erlang warnings matched as
`^src/...: Warning:` with dep paths (`deps/.../src/...`) excluded by
on-disk `deps/` membership (`deps/jose`, `deps/yamerl` verified).

### 2. TypeScript

```text
$ cd /Users/sac/smalt/workspace && npx tsc --noEmit
exit=0, output: 0 bytes (0 errors, 0 warnings)
```

## Doc updates

- `docs/jira/v26.10.22/VALIDATION.md`: added "§2 addendum (compiler-warning
  census, lane BK-WARNCEN, 2026-10-22)" carrying the measured counts above
  and the 0-hit premise finding. No doc row was carrying "68"; nothing
  else to correct (grep-verified across `docs/jira/v26.10.22/`).

## Verification

- `docs-dod-check` exit 0 (run post-edit; see commit).
- No `lib/` or `workspace/` source touched — census + docs only.

## See Also

- `receipts/bk7-warnings-cleanup.md` (BK-7, 38→ methodology origin)
- `receipts/bk7b-warnings-sweep.md` (48 TS warnings → 0)
- `receipts/bk7c-kafka-warnings.md` (lane-owned Kafka/WPS residuals)
