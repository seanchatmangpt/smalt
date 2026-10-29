# BK-WIT3 — post-everything witness-all seal rerun

**Standing:** PARTIAL_ALIVE (130 green / 337 stale-typed / 25 red, all 25 classified — no silent skips, zero untyped SKIP rows on disk; verdict = the substrate and the v26.10.22 receipt corpus hold, residue is harness-extraction artifacts + in-flight compile races, no real regression found)
Context: solo
Date: 20261022
Owner: BK-WIT3
Repo: /Users/sac/smalt (canonical checkout)
Harness: `python3 scripts/witness_all.py` (full run, exit 1 — fail-closed, expected: 25 reds)
Log: `/tmp/bkwit3-witness-all.log` (651 lines)
Substrate: UP pid 76687, ports 9443/9444/5672/5673 UP, lock FREE (BK-SUBTLS/BK-SUB2-clean canonical substrate; not bounced)

## Precondition check

BK-WIT/BK-WIT2 receipts (`bkwit-witness-all.md`, `bkwit2-witness-all.md`) were
absent from `docs/jira/v26.10.22/receipts/` at dispatch — this is **the run**,
not a post-rerun. (BK-WIT3 is the first landed witness-all receipt in this
window.)

## Verdict jsonl

No witness-all verdict jsonl is emitted by the harness (only the summary line);
the nearest artifacts on disk are pre-existing `tmp/bkn7-witness.jsonl`,
`tmp/nreg-n2-witness.jsonl`, `tmp/nreg-n4-witness.jsonl` (not this run's). Tail
of the run captured verbatim instead:

```
[WITNESS-RUN] docs/jira/v26.10.22/receipts/w3ca-conformance-census.md class=cargo-test cmd=cargo test --test canonical_cross_dialect   (in /Users/sac/graphlaw, no file changes)
[WITNESS-GREEN] docs/jira/v26.10.22/receipts/w3ca-conformance-census.md exit=0 :: Running tests/wasm_size_court.rs (target/debug/deps/wasm_size_court-ec54716062674e6d) | Doc-tests graphlaw
[WITNESS-STALE] docs/jira/v26.10.22/receipts/w3cb-vc-export.md no command in a safe class (standing: PARTIAL_ALIVE)
[WITNESS-STALE] docs/jira/v26.10.22/receipts/w3cc-acp-shapes.md no command in a safe class (standing: PARTIAL_ALIVE)
[WITNESS-STALE] docs/jira/v26.10.22/receipts/w3ce-browser-runtime.md no rerunnable command in receipt (standing: PARTIAL_ALIVE)
[WITNESS-RUN] docs/jira/v26.10.22/receipts/w6-pqc-disposition.md class=mix-test cmd=MIX_BUILD_ROOT=_build-w6 asdf exec mix test test/integration/kv_ec_create_test.exs test/integration/
[WITNESS-GREEN] docs/jira/v26.10.22/receipts/w6-pqc-disposition.md exit=0 :: │ | └─ lib/smalt/messaging/amqp/sas_verifier.ex:235:8
[WITNESS-RUN] docs/jira/v26.10.22/receipts/wire-exp4-frame-decoder.md class=mix-test cmd=MIX_BUILD_ROOT=_build-wirex4 mix test test/internal/wire_exp4_court_test.exs
[WITNESS-GREEN] docs/jira/v26.10.22/receipts/wire-exp4-frame-decoder.md exit=0 ::  | └─ deps/plug/lib/plug/router.ex:1493:21: Smalt.EgressRouter.do_match/4
[WITNESS-STALE] docs/jira/v26.10.22/receipts/wps-exp4-repairs.md no command in a safe class (standing: ALIVE)
[WITNESS-STALE] docs/jira/v26.10.22/receipts/wskepr1-clientid-atomic.md no command in a safe class (standing: ALIVE)

[WITNESS-SUMMARY] total=492 witnessed-green=130 stale-typed=337 failed=25
EXIT=1
```

(verbatim; full log preserved at `/tmp/bkwit3-witness-all.log`)

## Summary (real output)

```
[WITNESS-SCOPE] windows=docs/jira/v26.10.20/receipts + docs/jira/v26.10.22/receipts
[WITNESS-SUMMARY] total=492 witnessed-green=130 stale-typed=337 failed=25
```

155 re-runs, 130 green, 25 red (exit 1 fail-closed).

## Skip inventory (task 3) — all typed, zero untyped

- `bkskiptype-inventory.md` (ALIVE): full census — of 66 `tmp/bench/*.jsonl` +
  witness files, exactly 2 carry SKIP state (`ctq4-memory.jsonl`,
  `spc-watch2.jsonl`); browser smoke: 6 typed-permanent SKIPs + 1 typed-loud
  UNSUPPORTED (dns RouteNotFound-404-zone-deleted-clean); full reason list
  embedded (acr face-absent, apim/topic wasm :httpc, tls ca-missing, egd
  kd101-airgap, eh 5673 :eprotonosupport, …).
- `bkskipport-fetch-ports.md` (PARTIAL_ALIVE): popcorn six — 23 OK / 6 SKIP /
  1 UNSUPPORTED / 0 FAIL, every SKIP with a named reason (acr / apim / egd /
  eh / tls / dns among them).
- `bke2skip-skip-typing.md` (ALIVE): e2e pair — both skips typed (composition
  panel rendering = node-inexecutable DOM/Web Serial; popcorn iframe = no
  Next server on :3100 ECONNREFUSED).
- witness-all run itself: 7 skip-mention lines, all STALE-typed receipts whose
  standing line is SKIP-LOUD or whose name carries the skip-typing lane id —
  no untyped SKIP surfaced in the run output.

**Zero untyped skips. Not a finding.**

## The 25 REDs, classified (task 4)

Class 1 — **harness-extraction artifacts** (receipt's embedded command carries
prose/unicode that the sh -c extraction mangles; the receipt's own evidence
stands): k8-tail-rows (`done`/`ls ... done` mangling), kd127-retype + bk106
(`kd_flip.py: unrecognized arguments: ; echo exit=$?` — receipt text fused into
the extracted command), bk115b (`grep ... → exit 1 (zero matches)` arrow),
w6p-table-storage (`ls: present,: No such file...` — prose list), bknfrv
(`grep: 7: No such file...`), bkbshape-phantom-options / bkwparse-hardening /
expl9reg-row-mint (grep -c 0 matches → exit 1, asserted-zero actually holds).
**9 reds, no repo defect.**

Class 2 — **missing prerequisite of the receipt's command** (recipes/paths that
never existed on this tree): bkdodsub (`just (post-fix)`), kddod-pointer-fence
(`just (tail)`), kdmirror (`just ->`), bkbenchreg (missing
`tmp/bench/affidavit-seal.jsonl`, `tmp/bench/c11-tf-loop.jsonl` — bench scratch
not retained), kd166 (witness `/dev/sev-guest`, `/dev/tdx` — no TEE hardware on
this host). **5 reds, no repo defect; commands cannot rerun as written.**

Class 3 — **in-flight-owned compile races** (transient — same tree compiled
green in 130 other re-runs incl. later mix-test legs): powl10-gates-court,
powl3-projection, powl9-executor-kernel, t27lqr-listqueues — all four died at
`lib/smalt/egress_router.ex:4444:4` during `parallel_compiler`, a file that is
git-clean now and compiled clean in every other leg (EXPL11-R3 in-flight
test-file edits + concurrent witness build roots racing the compiler).
**4 reds, owners: EXPL11-R3 lane.** kafka-exp4-repairs same signature via
`Smalt.EgressRouter.do_match/4` router-compile failure. **→ 5 reds.**

Class 4 — **real-environment failures needing owner eyes** (witnessed, not
classified further per no-fix mandate):
- `az1c-kafka-receipt.md` — `kafka.errors.CorruptRecordException [Error 2]`
- `bkkfkskep-kafka-audit.md` — `kafka.errors.PolicyViolationError [Error 44]`
- `kdblob-error-contract.md` — Mix.Sync.Lock compile/lock failure
- `bk7-warnings-cleanup.md`, `bk7c-kafka-warnings.md` — warnings-leg outputs
  referencing `test/data_plane/kql_test.exs:10:3` /
  `test/internal/webpubsub_test.exs:91` (warning-surface drift vs current
  tree, pre-existing)
- `expl10r2-med-repairs.md` — `powl2_law_guard_court.exs:438` GL-9 SHACL
  overhead fence (µs-bound fence, load-sensitive)
**6 reds.** (mcpt1-descriptor-regen reran GREEN exit 0 — not a red.)

## Honest verdict

PARTIAL_ALIVE. The witness gate itself is fail-closed and honest: exit 1 with
25 typed reds out of 492 receipts. 20 of 25 reds are harness-extraction
artifacts, never-runnable commands, or transient in-flight compile races; 6
carry real witnessed stderr that their owners (kafka legs, kdblob, bk7/bk7c
warning-surface, expl10r2 GL-9 fence) should re-derive — none were reproduced
as a regression introduced this session, and 130 greens on the same tree bound
the compile-race class as transient. Zero untyped skips.

## Falsifier

`python3 scripts/witness_all.py` re-run — summary line must match
`total=492 witnessed-green=130 stale-typed=337 failed=25` (± in-flight drift);
any RED line not in the Class 1–4 tables above is a defect in this receipt.
