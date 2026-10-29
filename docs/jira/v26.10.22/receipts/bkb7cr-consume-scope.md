# BK-B7CR — KFKC consume probe scoped to per-run unique prefix

Standing: ALIVE · Context: solo · Lane: BK-B7CR · MIX_BUILD_ROOT=_build-bkb7cr

Repairs the typed defect from `docs/jira/v26.10.22/receipts/bkwit3r-six-reds.md`
item 5 (bk7c-kafka-warnings): the BK-KFKC real-client consume leg
(`tmp/bkkfkc_probe.py` via the :189-consume leg of
`test/internal/kafka_exp4_court_test.exs`) failed reproducibly 9/10 across
seeds. Root cause: the probe reads partition 1 from the beginning and the
test's filter prefix was a CONSTANT ("KKKK" == the value itself), so a
timed-out first consume left a straggler record that every retry also matched
— `n=1` could never hold again (state dependence retry cannot repair). The
4×20s retry ladder also exceeded the test's timeout budget.

## Fix (test file only; probe unchanged — it already accepts --filter-prefix)

`test/internal/kafka_exp4_court_test.exs`, real-client probe test:

- Per-run unique prefix: `uniq = Base.encode16(:crypto.strong_rand_bytes(6))`
  → `prefix = "K" <> uniq`; value = `prefix <> padding` keeping the 60-byte
  legacy-face pin byte-exact (bytes 57..60 of a 60-byte-value frame stay
  0x42424242 — the falsifier semantics untouched).
- Consume leg now passes `--filter-prefix <per-run prefix>` instead of the
  constant "KKKK": each run is scoped to exactly its own record; a retry on a
  shared/replayed partition observes only its own value. Retry is now
  state-repairable.
- Timeout: the 240_000 ms tag already in the file (BK-KFKC2 verify edit)
  bounds the 4×bounded-poll ladder; unchanged.

## Falsifiers (real runs, real kafka-python-ng client, substrate pid 81426)

Command per run (embedded, per receipt law):
`PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_bkb7cr mix test test/internal/kafka_exp4_court_test.exs`

```
run 1: Finished in 21.4 seconds  Result: 10 passed
run 2: Finished in 21.2 seconds  Result: 10 passed
run 3: Finished in 21.2 seconds  Result: 10 passed
run 4: Finished in 21.2 seconds  Result: 10 passed
run 5: Finished in 21.2 seconds  Result: 10 passed
```

5/5 consecutive fresh-journal runs green — falsifier of BK-WIT3R item 5 closed.
Legacy-count falsifier legs (:152/:172/:183 = count-1/hwm, corrupt-refuses,
magic-1 cross-check) all pass in every run (10 tests total per run, 0 failures).

Sibling suite (fresh):
`MIX_BUILD_ROOT=_build-bkb7cr mix test test/internal/kafka_wire_test.exs`
- run 1: 8/9 — the 1 failure is the documented KIP-183
  PolicyViolation[Error 44] downgrade face in `scripts/az1/kafka_probe.py`
  (pre-existing, typed and resolved per receipt bkkfkskep in bkwit3r-six-reds
  item 2; its red tail is an EXPECTED negative-probe stderr face). Not this
  lane's subject, no code touched by this lane.
- run 2: 9/9 passed.

## Diff scope

- `test/internal/kafka_exp4_court_test.exs` (per-run prefix + filter scoping)
- this receipt
