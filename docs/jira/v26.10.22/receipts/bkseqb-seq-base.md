# BK-SEQB — Journal seq base root-cause + pin (EXPL11-R1 observation)

- **Date**: 2026-10-22
- **Lane**: BK-SEQB, repo /Users/sac/smalt (canonical checkout; MIX_BUILD_ROOT=_build-seqb)
- **Standing**: ALIVE
- **Context**: solo
- **Chases**: EXPL11-R1 "Note on scope"
  (docs/jira/v26.10.22/receipts/expl11r1-ledger-range.md) — isolated
  `--no-start` boot showed 0-based JournalSink seqs vs "historical 1-based"

## Root cause

There is no 1-based path anywhere in the tree. The seq base is determined
solely by `JournalSink.init/1`, which seeds `next_seq: 0`
(`lib/smalt/storage/journal_sink.ex:266`) and assigns `seq = state.next_seq`
at append (line 413), incrementing after. Verified influences, all none:

- **Boot config**: no config key or env touches the base; the only journal
  config keys (`:journal_sink_dir`, `:acl_journal_dir`) set the dir/ceiling,
  never the seq.
- **Plane subset**: the sink child is added on the application root
  supervisor (`lib/smalt/application.ex:57`) regardless of `SMALT_PLANES`;
  the base is the same `next_seq: 0` seed on every plane shape.
- **Boot-replay path (TTV-4)**: replay lives in `Smalt.Store`
  (`lib/smalt/store.ex:137-149`) and reads sealed segments into the Store ETS
  — it does not touch the sink's `next_seq`. (Honest scope note: the sink
  itself does not adopt `next_seq` from existing on-disk frames at boot, so a
  sink restart over a dirty dir re-issues seq 0 — that is a restart-identity
  question, out of BK-SEQB's scope; recorded as an observation, not a
  BK-SEQB finding.)
- **Test-env config**: test.exs only reroutes dirs/ports, never the seq.

## Verdict: ARTIFACT OF PREMISE (the premise "historical 1-based" was wrong)

The isolated `--no-start` probe and the production mount path agree. Two
minimal boots, both on _build-seqb (elixir 1.20.4-otp-29):

**Leg A — isolated `--no-start` shape** (explorer's shape: sink started
directly over a fresh tmp dir):

```
$ MIX_BUILD_ROOT=_build-seqb MIX_ENV=test mix run --no-start -e '<start sink; append>' -- $D
LEG_A_FIRST_SEQ=0
```

**Leg B — production default-plane boot** (full `mix run` app boot, ACL
mount's dedicated sink over `SMALT_ACL_JOURNAL_DIR=$D`):

```
$ MIX_BUILD_ROOT=_build-seqb MIX_ENV=test SMALT_ACL_JOURNAL_DIR=$D mix run -e '<Service.append via mount>'
LEG_B_FIRST_TX_ID=0.1
LEG_B_STATUS=%{mode: :active, next_seq: 1, frames: 1}
```

Both shapes' first append gets seq 0. The merged-tree az3/az3b courts were
never masking a divergence: their expected `["2.1", "3.1", "4.1"]`
(az3_confidential_ledger_court_test.exs:128) follows two setup appends that
received 0.1/1.1 — 0-based all along. Nothing masks anything; the merged-tree
courts and the isolated boot agree.

Corollary pin: a future "fix" to a 1-based base would regress the wire face
(tx ids) and the receipt-chain indexing premise. That drift is now fenced.

## Pin (the anti-reopening leg)

`test/internal/bkseqb_seq_base_court_test.exs` — 3 legs, real JournalSink on
real disk + real supervised-mount-shaped Service (no mocks):

- leg 1: isolated shape, fresh named sink, first append → seq **0**,
  `status/1` = `%{frames: 1, next_seq: 1, mode: :active}`
- leg 2: production mount shape (same child opts as
  `ConfidentialLedger.Supervisor.init/1`: dedicated `Smalt.ConfidentialLedger.Sink`
  + Service), `Service.append` → **"0.1"**, second → **"1.1"** (never 1.1-on-first),
  sink `%{frames: 2, next_seq: 2}`
- leg 3: seq law (SYNC-RECEIPT-CHAIN §2): five appends → dense monotone
  `[0, 1, 2, 3, 4]`

## Court

```
$ MIX_BUILD_ROOT=_build-seqb MIX_ENV=test mix test test/internal/bkseqb_seq_base_court_test.exs
Result: 3 passed
```

Regression (az3 + az3b on the same build, since the legs lawfully
terminate/restart the ACL mount per the AZ-3b pattern):

```
$ MIX_BUILD_ROOT=_build-seqb MIX_ENV=test mix test test/integration/az3_confidential_ledger_court_test.exs test/integration/az3b_ledger_mount_court_test.exs
Result: 8 passed
```

## Concurrency disclosure

Mid-lane the shared compile broke on an in-flight concurrent edit to
`lib/smalt/mcp/router.ex` (MismatchedDelimiterError, not my file — I touched
no lib/ code). Per the compile-freeze SLA I waited; the owner's edit landed
and `mix compile` healed (COMPILE_OK) before my final green runs. My diff:
one new test file + this receipt only.
