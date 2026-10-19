# i29 — post-HEAD 0009df3 gate verification (compile + naming-sweep + invariant-gates)

Context: solo (gate run: compile + naming-sweep + invariant-gates; no mix test invocation)
- Repo: /Users/sac/smalt
- HEAD: `0009df32aac4e7d3836d246b8852e65ca8163cb2` (fix(test): sovereign_midnight require path + typed :sovereign_gap exclusions for G1-G6)
- Standing: PARTIAL_ALIVE — compile clean, invariant-gates PASS, naming-sweep FAIL (76 pre-existing violations, none from this lane; no edits made).

## 1. Compile gate

Command (from repo root):

```
MIX_ENV=test MIX_BUILD_ROOT=_build-ft-wa mix compile --warnings-as-errors
```

Exit 0. Tail of output:

```
==> sparql
Compiling 2 files (.erl)
Compiling 43 files (.ex)
Generated sparql app
==> sparql_client
Compiling 9 files (.ex)
Generated sparql_client app
==> ash_r2rml
Compiling 137 files (.ex)
Generated ash_r2rml app
==> ash_ex4pm
Compiling 30 files (.ex)
Generated ash_ex4pm app
==> smalt
Compiling 155 files (.ex)
Generated smalt app
EXIT:0
```

Notes:
- `_build-ft-wa` build root created by the compile (pre-existing-lease style private root; left in place per "do not delete any _build dir").
- Upstream (hex dep) warning observed during dependency compilation, not fatal under `--warnings-as-errors` (exit 0):

```
1. Add the domain to your configured domain modules. The following snippet can be used.
    config :ex4pm, ash_domains: [Ex4pm.Domain]
2. Add the option `validate_config_inclusion?: false` to `use Ash.Domain`
3. Configure all domains not to warn, with `config :ash, :validate_domain_config_inclusion?, false`
  (spark 2.7.8) lib/spark/dsl.ex:670: Spark.Dsl.__verify_spark_dsl__/5
```

This originates from the hex packages `ex4pm`/`spark`/`ash` (spark 2.7.8), not the
smalt test tree. Reported as upstream; no vendored sources patched.

## 2. Naming sweep — FAIL (exit 1)

```
just naming-sweep
```

Exit 1. Final line:

```
[NAMING-SWEEP] FAIL: 76 violation(s), 41 allowed
error: recipe `naming-sweep` failed on line 158 with exit code 1
```

All 76 violations are hardcoded `/Users/sac/...` absolute-path literals. Sample
verbatim (first 40 lines of the log):

```
[NAMING-SWEEP] VIOLATIONS (76):
  docker/BUILD_RECEIPT.md:8:  --build-context ash_r2rml=/Users/sac/ash_r2rml \
  docker/BUILD_RECEIPT.md:9:  --build-context ash_graphlaw=/Users/sac/ash_graphlaw \
  docker/BUILD_RECEIPT.md:10:  --build-context ggen_igniter=/Users/sac/ggen_igniter
  docker/Dockerfile:52:#     --build-context ash_r2rml=/Users/sac/ash_r2rml \
  docker/Dockerfile:53:#     --build-context ash_graphlaw=/Users/sac/ash_graphlaw \
  docker/Dockerfile:54:#     --build-context ggen_igniter=/Users/sac/ggen_igniter
  docker/burn/burn-ring.sh:124:    -v /Users/sac/beam4pm:/beam4pm:ro \
  docker/burn/burn-ring.sh:125:    -v /Users/sac/xaas:/xaas:ro \
  docker/burn/compose.burn.yml:13:    - /Users/sac/beam4pm:/beam4pm:ro
  docker/burn/compose.burn.yml:14:    - /Users/sac/xaas:/xaas:ro
  docker/burn/parallel-matrix.sh:141:    - /Users/sac/beam4pm:/beam4pm:ro
  docker/burn/parallel-matrix.sh:142:    - /Users/sac/xaas:/xaas:ro
  docs/jira/v26.10.18/burn/kill-storm-host.jsonl:2:{"schema": "smalt-burn/v2", ... "evidence_path": "/Users/sac/smalt/docs/jira/v26.10.18/burn/kill-storm-host.jsonl", ...}
  docs/jira/v26.10.18/burn/kill-storm-host.jsonl:3:{...}
  docs/jira/v26.10.18/burn/kill-storm-host.jsonl:4:{...}
  docs/jira/v26.10.18/burn/ring-ringsmoke/boot/boot-burn.jsonl:2:{...}
  docs/jira/v26.10.18/burn/ring-ringsmoke/boot/boot-burn.jsonl:3:{...}
  docs/jira/v26.10.18/burn/ring-ringsmoke/boot/boot-burn.jsonl:4:{...}
  docs/jira/v26.10.18/burn/test/e2e/s7_worm/run.sh:21:SMALT_SDK_ROOT="${SMALT_SDK_ROOT:-/Users/sac/smalt/test/sdk-full/node_modules}"
  docs/jira/v26.10.18/burn/test/e2e/s7_worm/worm.test.cjs:11:  process.env.SMALT_SDK_ROOT || "/Users/sac/smalt/test/sdk-full/node_modules";
  docs/jira/v26.10.18/burn/test/redteam/r1_input_fuzz/receipt.txt:2:substrate: pid 55896, log /Users/sac/smalt/test/redteam/r1_input_fuzz/substrate.log
  docs/jira/v26.10.18/burn/test/redteam/r2_state/findings.md:4:Subject: smalt substrate @ /Users/sac/smalt (fresh `mix run --no-halt`, MIX_ENV=test,
  docs/jira/v26.10.18/rewrite-drafts/amqp.md:7:- `/Users/sac/smalt/test/amqp/fuzz_test.exs`
  ... (rewrite-drafts/*.md absolute paths, mods/ratchet/lib/*.js ROOT/STATE_PATH constants, mods/ratchet/test/*, scripts/have/have_11_drill.sh:19 REPO=, scripts/have/storage_probe.py:80)
  scripts/have/have_11_drill.sh:19:REPO=/Users/sac/smalt
  scripts/have/storage_probe.py:80:    for cand in ("/Users/sac/.erlmcp/otp-28.3.1/bin/escript", shutil.which("escript") or ""):
```

Classification: all violations are in burn evidence (`.jsonl` receipts with
`evidence_path` fields), rewrite-drafts docs, `mods/ratchet` (hardcoded
ROOT/STATE_PATH constants), and `docker/`/`scripts/have` helper scripts.
None of these files were touched by this lane; the failure predates this
session (no edits made — the working-tree modifications in `docker/burn/`,
`docs/jira/.../RECEIPTS.md` visible in git status at session start are
another lane's in-flight work).

Full log preserved at /tmp/i29-naming.log (76 lines of violations + summary).

## 3. Invariant gates — PASS (exit 0)

```
just invariant-gates
```

Exit 0 (204.161s). Tail:

```
test_first_run_court_tiers_are_t1_to_t4 (__main__.DocContractTest.test_first_run_court_tiers_are_t1_to_t4) ... ok
test_just_reference_tf_smoke_exit_contract (__main__.DocContractTest.test_just_reference_tf_smoke_exit_contract) ... ok
test_all_invariant_gates (__main__.InvariantGatesTest.test_all_invariant_gates)
Every gate: real substrate run -> exit 0, receipt PASS, negatives refused. ... ok

----------------------------------------------------------------------
Ran 3 tests in 204.161s

OK
```

## Summary

| Gate | Exit | Verdict |
|---|---|---|
| `mix compile --warnings-as-errors` (MIX_ENV=test, _build-ft-wa) | 0 | PASS (upstream hex warning from spark 2.7.8, non-fatal) |
| `just naming-sweep` | 1 | FAIL — 76 violations, 41 allowed; all pre-existing absolute-path literals, none introduced by this lane |
| `just invariant-gates` | 0 | PASS — 3 tests OK, negatives refused |

Receipt context: solo.
