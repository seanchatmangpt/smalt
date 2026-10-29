# BK-BMIR4 — b10-system-topics anchor typed: original in-place artifact, not a lost tmp mirror

- **Standing**: ALIVE (classification is grep-witnessed and harness-source-witnessed; original artifact byte-verified unchanged)
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-BMIR4
- **Closes the one NO-SRC row in**: BK-BMIR3 (docs/jira/v26.10.22/receipts/bkbmir3-mirror-wave3.md §2) — the last open row of the tmp-anchor class

## 1. Trace: nothing cites it; nothing anchors on it

```
$ grep -rn 'b10-system-topics' docs/ | grep -v 'bench/b10-system-topics.jsonl'
docs/jira/v26.10.22/receipts/bkbmir3-mirror-wave3.md:48:$ shasum -a 256 docs/jira/v26.10.2{0,1}/bench/*.jsonl   # wave-3 rows below; full run: 45 MATCH, 1 NO-SRC (pre-existing b10-system-topics.jsonl, source already gone from tmp/bench, not this lane's)
```

The ONLY reference to the filename in all of docs/ is BK-BMIR3's own census
note. Zero receipts, zero milestone docs, zero GAP/KD rows cite
`b10-system-topics.jsonl` as evidence; no numbers anywhere anchor on it. The
v26.10.17 verify-ledger `w0-b10.md`/`w1-b10.md` files are unrelated (lane b10
adversarial re-derivations of KD rows, not this jsonl).

## 2. Classification: original in-place artifact, never a tmp mirror

scripts/bench/b10_system_topics.sh:14-19 (verbatim from disk):

```bash
BENCH_RESULTS_DIR="$REPO/docs/jira/v26.10.20/bench"
mkdir -p "$BENCH_RESULTS_DIR"
RESULT_FILE="$REPO/docs/jira/v26.10.20/bench/b10-system-topics.jsonl"
```

The harness writes the tracked file directly — the tracked file IS the
original run output. There was never a `tmp/bench/b10-system-topics.jsonl`
source to mirror. The BK-BMIR3 census "1 NO-SRC" was a classification
artifact, not a provenance gap. The file is a crud-witness row (n=1,
ops_per_sec=0, all-zero latency metrics — a witness that the systemTopics
ARM face answers PUT 201 / GET 200 / LIST 1 / DELETE 200 / 404, plus the
eventSubscriptions child face incl. the KD-101 WebHook typed-refusal), not a
performance claim.

## 3. Recoverability: harness intact; re-measurement typed-refused at boot (3 attempts, recorded honestly)

Harness present and executable: `scripts/bench/b10_system_topics.sh` (6515 B,
mtime Oct 20 05:17), lane b10 port block 39100..39105 per the bench port law,
private lane build root `_build-lane-w4j`. All three attempts preserved the
original bytes (sha256 verified identical before/after every attempt):

```
e9f62865b51f58a58e27fde25e13d80131b6365c3e0e217fc4e5dddbcf8e46c9  docs/jira/v26.10.20/bench/b10-system-topics.jsonl  (before == after, all attempts)
```

1. **Attempt 1 — TYPED-TIMEOUT(124)**: cold lane build root
   (`_build-lane-w4j` empty of smalt beams); boot readiness poll exhausted its
   120 s budget mid-compile. Fix attempted: warmed the lane root
   (`MIX_BUILD_ROOT=_build-lane-w4j mix compile`, rc=0).
2. **Attempt 2 — substrate died, rc=2, `:eaddrinuse`**: boot log
   `tmp/bench-substrate-b10.log`: `Running Smalt.Messaging.WsAmqpRelay ...
   port 5675 already in use`. Root cause: the b10 harness boots in `:enforce`
   dev-config mode by design (no MIX_ENV=test), and dev config carries no
   ephemeral-port fallback for `ws_amqp_relay_port`
   (`lib/smalt/plane/data_supervisor.ex:72` defaults to 5675). Port 5675 (and
   5676) is held by the live shared substrate (beam pid 76687, LISTEN on
   9443/9444/8443/5675/5676, up ~1 h). Per lane law, a holder with LISTEN
   sockets is live, not an orphan — not stopped by this lane.
3. **Attempt 3 — same typed refusal** (`port 5675 already in use`), after
   confirming the b10 block itself was fully free and resolving the mystery of
   attempt 2 (my earlier MIX_ENV=test probe resolved ws relay to ephemeral
   64545 — the ephemeral fallback lives only in `config/test.exs`, which the
   enforce-mode harness intentionally does not load).

Also witnessed during the window: a concurrent lane's in-flight parse-broken
`lib/smalt/egress_router.ex` (TokenMissingError) cleared itself within one
30 s poll — compile-freeze SLA held; no cross-lane action taken.

## 4. Verdict

- `b10-system-topics.jsonl` is typed **original-artifact (harness-written
  in place)** — the BK-BMIR3 NO-SRC row is closed as a classification
  artifact, not a provenance gap. The tmp-anchor class now has zero open rows.
- Zero fabrication: no addendum was appended to any citing receipt because
  zero citing receipts exist; the original file was never overwritten
  (byte-verified across all three failed re-measurement attempts); no fake
  PASS emitted.
- Future re-measurement precondition (recorded, not acted on): free the
  5675/5676 holds (stop the shared substrate) or extend the b10 harness to
  pass `SMALT_TEST_WS_RELAY_PORT`/`SMALT_TEST_WPS_PORT` into its
  dev-config boot — harness edit owned by the bench-lane owners, not this lane.
- PROVENANCE for the owning bench dir updated:
  `docs/jira/v26.10.20/bench/PROVENANCE.md` (BK-BMIR4 classification block).
