# GLD-7 — ingest -> governance -> execution loop court

**Standing**: ALIVE
Context: solo
- **Date**: 2026-10-21
- **Lane**: GLD-7 (court, OTP-29), MIX_BUILD_ROOT=_build-gld7
- **Court file**: `/Users/sac/smalt/test/integration/gld7_ingest_to_settlement_court.exs`
- **Run**:
  `MIX_BUILD_ROOT=_build-gld7 asdf exec mix run --no-start test/integration/gld7 **COURT FAIL**`
- **Run**:
  `MIX_BUILD_ROOT=_build-gld7 asdf exec mix run --no-start test/integration/gld7_ingest_to_settlement_court.exs`
  (toolchain: asdf elixir 1.20.4-otp-29 / erlang 29.1.2 per `.tool-versions`; `--no-start`
  because the shared substrate holds port 8443 and `mix run` without it boots the full
  smalt app)
- **Exit**: 0 (PASS), 112 `ok` assertions, 0 failures

## Embedded command output (abridged head of run; full log `/tmp/gld7_final.log`)

```
GLD-7 INGEST->GOVERN->EXECUTE COURT
  ok  parsed 2 CREATE TABLEs from dump bytes
  ok  orders DDL: 5 columns
  ok  parsed 10 order rows from COPY
  ok  parsed 3 customer rows from COPY
  ok  COPY row values tab-parsed
  ok  OCEL envelope: 13 ingest events
  ok  OCEL envelope: 13 objects
  ok  Ocel.validate_envelope/2: no dangling relationships
  ok  object_trace/2 for O-05 returns exactly its ingest event
  ok  SqlShapeGen emitted SqlOrdersShape from parsed DDL
  ok  schema admission: O-01 .. O-10 conform SqlOrdersShape   (10 lines)
  ok  schema non-vacuity: unknown column refuses (closed shape)
  ok  schema non-vacuity: string amount refuses (datatype)
  ok  GL-2 LawCompiler compiled HighValueOrderShape guard
  ok  law partitions exactly 2 orders over-threshold
  ok  over-threshold set == [O-01, O-05] (law-predicted)
  ok  law partitions 8 conforming orders
  ok  tightened law (5000) refuses 6 orders - partition is law-derived, not fixture-asserted
  ok  executed ANDON set == law-predicted over-threshold set [O-01, O-05]
  ok  executed settled set == law-predicted conforming set
  ok  O-01: ANDON fired at validate / refusal names the compiled law rule / commit never fired
  ok  O-05: ANDON fired at validate / refusal names the compiled law rule / commit never fired
  ok  O-02..O-10 (8): commit CAS 201, ChangeFeed document present,
      settlement chain [:validate, :commit, :settle, :exit]
  ok  ChangeFeed holds exactly the 8 settled documents
  ok  sealed receipt holds 47 leaves (13 ingest + all executor steps)
  ok  sealed Merkle root is 32 bytes and HSM-signed
  ok  phi_lease_final == max epoch
  ok  every order's ingest + settlement leaves present in the sealed ledger (delta-hash membership)
  ok  receipt carries exactly 8 commit acts / 8 settle acts / 2 ANDON orders
  ok  non-vacuity: dropping a leaf changes the Merkle root
  ok  ANDON and settled sets disjoint; partition exhaustive over all 10 ingested orders
GLD-7 COURT: PASS
orders: 10 | andon: O-01,O-05 | settled: 8
sealed leaves: 47  merkle_root: 6fccaafea1d0a388192520e63b853725e81ebe0554a4669285131643eda066dc
signature: ECDSA (raw 32-byte binary, HSM-signed via Smalt.Powl2.HsmSigner)
```

## The full loop

1. **SQL dump**: deterministic 10-order pg_dump fixture (SQLD-2 pattern; fixed corpus,
   no randomness). A real text parser (`Gld7.Parser`) re-reads the dump BYTES —
   CREATE TABLE DDL + COPY rows; the generator's in-memory rows are never consulted.
2. **OCEL**: rows project to OCEL 2.0 events/objects; `Smalt.Ocel.validate_envelope/2`
   proves referential integrity; `object_trace/2` per order.
3. **Laws over the ingested schema**: SQLD-5 `SqlShapeGen.generate/1` over the PARSED
   DDL (schema non-vacuity: closed-shape + datatype refusals witnessed); hand-authored
   `HighValueOrderShape` (`sh:maxInclusive 10000` on `totalAmount`) compiled by the
   GL-2 `LawCompiler.compile_shape/2` into a guard predicate.
4. **POWL execution**: GL-4 settlement business net per ingested order through
   `Smalt.POWL2.Executor.execute_admitted/5` with real ChangeFeed CAS commits
   (201 + etag). O-01 (48000) and O-05 (12500) ANDON at validate; the refusal names
   the compiled rule `HighValueOrderShape/maxInclusive/totalAmount`; commit never fires;
   ChangeFeed untouched for both. 8 conforming orders commit + settle.
5. **Seal**: ONE `Smalt.PPlan.ReceiptEngine` run seals 13 ingest events + every
   executor step = 47 leaves; Merkle root 32 bytes; HSM ECDSA signature; leaf-drop
   changes the root (non-vacuity); per-order leaf membership proven by delta-hash.

## Partition exactness vs the law

- law-predicted over-threshold set == executed ANDON set == `["O-01", "O-05"]`
- law-predicted conforming set == executed settled set (8)
- ANDON ∩ settled = ∅; union = all 10 ingested orders
- tightened law (5000) refuses 6 — the partition is law-derived, not fixture-asserted

## Compile-freeze disclosure (SLA)

`lib/smalt/storage/journal_sink.ex` — UNTRACKED, in-flight from another lane (SqlIngest
work) — did not compile on Elixir 1.20.4 and froze the shared tree. Minimal unblock fix
applied per the compile-freeze SLA, preserving the author's apparent intent:

- line 266: `:file.position(state.io, :eof) == {:ok, _} || :ok` →
  `match?({:ok, _}, :file.position(state.io, :eof)) || :ok` (invalid `_` in expression)
- line 148: `key::binary` at non-final binary position →
  `key::binary-size(key_len)-unit(8)` (+ `payload::binary-size(payload_len)-unit(8)`;
  sizes are pinned by the guard above it)

Disclosed in BOTH this lane's receipt and journal_sink's owning lane's next receipt.

## Honest failures during bring-up (all fixed, final run clean)

- fixture bug: O-10 at 12_000 was a third over-threshold order; lowered to 9_200
- tightened-law expectation corrected 5 → 6 (O-04 9950 also > 5000)
- executor sync return on ANDON is `{:error, {:transition_failed, ...}}`, not `:ok`
- `Validator.validate_shape` returns `{:ok}` (1-tuple), normalized to `:ok` at the seam
- pipe-precedence bug in event assembly; unused-var cleanups; binary-root printing

## Notes

- `signature` in the receipt is an ECDSA signature over the merkle root (raw binary).
- The executor's `start`/`exit` are SESE delimiters; step paths assert
  `[:validate, :commit, :settle, :exit]` per settled order, matching GL-4 semantics.
- Exit code 0 with an at-exit `noproc` noise line (System.stop racing mix at_exit);
  the court itself is deterministic and sleep-free (bounded receive windows only).

## Replay

Second run 2026-10-21 (post dep-recompile): `GLD-7 COURT: PASS`, exit 0, same 47
leaves, all 112 assertions. Merkle root DIFFERS between runs
(`6fccaafe...` vs `79b510a4...`) — executor step deltas embed wall-clock
(`:settled_at = System.system_time(:millisecond)`), so the seal is
run-unique by design, not byte-replayable across runs. Within-run determinism
(fixed corpus, law-derived partition, sleep-free) is unaffected; cross-run
byte-replay of the seal is an open property of the executor's step deltas, not
of this court.

Court exit codes: PASS runs exit 0; a failed assert raises and exits 1 (typed
`GLD-7 COURT FAIL:` message naming the assertion).
