# L17 — Landing receipt (v26.11.6 wave finale, lane 17)

Standing: PARTIAL

## Quiescence gate (fail)

- Method: paired mtime snapshots (lib test scripts docs gates bench
  verification src config mix.exs), 120s apart, then a bounded wait-loop
  of 8 x 130s intervals — 20-minute budget.
- Result: never quiesced. Final check: repo-wide newest mtime was 2
  seconds old; actively-written files: `lib/smalt/data_plane/pubsub_grpc/`,
  `lib/smalt/egress/sqs/`, `test/integration/sqs_roundtrip_test.exs`,
  `lib/smalt/aoq/arrow/flatbuf.ex`, `verification/py/test_wf9_kafka.py`,
  `verification/ts/harness/substrate.ts`,
  `test/internal/kafka_group_court_test.exs`,
  `docs/jira/v26.11.6/receipts/kin-kinesis-rest-lane.md`,
  `bench/kafka_vs_aoq_court.{erl,beam}`, `bench/bench_bc_{lane,sink}.erl`,
  `scripts/bench/bc_bench.sh`.
- Concurrent-lane note: KD-197 row landed into
  `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` mid-window; kept, not reverted.

## Gates

- `just doctor` — RAN: exit 1. FAULT port-in-use on 8443 and 5672,
  holder PID 76420 (a peer lane's live substrate; not killed —
  never kill a shared holder). rc captured un-piped from the recipe.
- `bash scripts/aoq_egress_fence.sh` — NOT RUN (precondition failed).
- full asdf `mix test` — NOT RUN.
- `bash scripts/bin_opt_gate.sh` — NOT RUN.
- `just verify-all` — NOT RUN.
- Doctor red + tree churning => Phase 3 (commit/push) NOT executed,
  per the quiescence-gated landing law.

## Phase 1/4 artifacts landed on disk (uncommitted)

- `README.md` — three-plane Define; wire-reachable-at-protocol-version-X
  law; "Kafka-compatible" banned.
- `_LANES.md` — L59–L74 table (owned files/gates/falsifier/receipt
  pointers); charter-id to receipt-number mapping; exclusions list.
- `dmedi-define.md`, `dmedi-measure.md` — measured-only baseline table;
  UNMEASURED rows stay UNMEASURED.
- `strategy-kafka-takeover.md` — tax table, every row receipt-pinned or
  UNMEASURED.
- `KNOWN_DIVERGENCES.md` — KD-190 re-cited; KD-191 first-mint (lane 10);
  KD-192 NIF `#[no_mangle]` export law; KD-193 sh:closed OOV
  suppression; KD-194 SASL_SSL deferral; KD-195 Seal-flag gitpack-0x08;
  KD-196 kafka-wire-pack rows PROPOSE-ONLY. KD-197 landed by a
  concurrent lane (kept).
- `../v26.11.5/strata-backlog.md` — seeds S9–S14 appended (append-only;
  S1–S22 untouched).
- `receipts/final-per-repo.md` — ggen-marketplace / cgap / arcus
  per-repo receipts (in-tree, uncommitted in each repo).
- `.gitignore` riders (NIF dylib = lane 4; `priv/data/` = lane 17).
- Stray root-level junk file `0` deleted.

## Resume condition

Phase 3 re-opens when (a) the tree quiesces (paired identical mtime
snapshots + identical `git status --porcelain`), and (b) `just doctor`
is green (peer substrate down or ports free). Commit sequence A→D with
explicit paths only.
