# i20h — C6 OAuth first per-file witness (ever-green audit closure)

Standing: PASS
Date: 2026-10-17
Lane: i20h (witness lane, no edits, no git)
Build root: `_build-ft-c6w`
Subject: `test/compliance/c6_oauth.exs` (`Smalt.Compliance.C6OauthTest`, 18 rows) — zero prior per-file receipts per the ever-green audit; previously only ever executed inside the `test/compliance_test.exs` corpus loader.

Context: solo (mix test test/compliance/c6_oauth.exs)

## Command

```bash
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-c6w mix test test/compliance/c6_oauth.exs
```

## Real output (embedded, exit 0)

```
Finished in 0.2 seconds (0.00s async, 0.2s sync)
18 tests, 0 failures
EXIT=0
```

Tail of run showing the real plug-pipeline exercise (real Joken signing, real `Smalt.ArmGateway.Router`):

```
15:28:06.648 [info] POST /oauth2/v2.0/token
15:28:06.648 [info] Sent 400 in 58µs
.
15:28:06.648 [info] POST /oauth2/v2.0/token
15:28:06.650 [info] Sent 200 in 77µs
.
Finished in 0.2 seconds (0.00s async, 0.2s sync)
18 tests, 0 failures
```

This is the FIRST per-file green witness for c6_oauth (18/18, exit 0, solo context).

## Corpus-wide residual (same code, same build root, separate invocation)

Command:

```bash
MIX_BUILD_ROOT=_build-ft-c6w mix test test/compliance_test.exs
```

Context: slice(7 compliance family files c1..c7 via test/compliance_test.exs loader, 1 invocation)

Real output (exit 0):

```
Finished in 6.5 seconds (0.00s async, 6.5s sync)
157 tests, 0 failures (16 excluded)
EXIT=0
```

- **Per-module residual failures: NONE.** All 7 families (c1..c7) green in the corpus context.
- The 16 excluded are all of c5_servicebus (`@moduletag :amqp_wire` at
  `test/compliance/c5_servicebus.exs:24`), which is the repo-wide default
  exclusion for the `:amqp_wire` tier — accounted for by the loader's own
  register math: 170 registered + 3 loader tests = 173 total = 157 run + 16 excluded.
- Corroboration of the solo claim from a different context: c6's 18 rows pass in
  the corpus loader context too (157/157 of run rows). Contexts are not
  transitive per RECEIPT_CONTEXT_LAW §1, so both contexts are named explicitly.

## Ever-green ledger update

| file | prior per-file receipts | this witness |
|---|---|---|
| c6_oauth.exs | 0 | PASS 18/18 solo, exit 0 |

## Replay

```bash
cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-c6w mix test test/compliance/c6_oauth.exs
```
