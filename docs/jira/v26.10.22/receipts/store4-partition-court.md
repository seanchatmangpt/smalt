# STORE-4 — 16-partition Erlang store: operator-mandated decomposition + crash court

**Standing:** **ALIVE** (court 4/4 PASS, exit 0, reproduced 3×)
Context: solo
Date: 2026-10-21
Files owned/edited: `src/smalt_store_heir.erl` (new), `src/smalt_store_partition.erl` (new), `src/smalt_store.erl` (new), `src/smalt_store_sup.erl` (new), `test/courts/court_store_partition_SUITE.erl` (new), `mix.exs` (one line: `erlc_paths` + `"src"`).

## Landed

Four real Erlang modules under `src/` (mix `erlc_paths` extended with `"src"` — same in-repo-erlc pattern as `lib/smalt/pipeline`):

- `smalt_store_heir.erl` — dedicated heir process; receives `ETS-TRANSFER` gifts unread (the transfer is the mechanism, the unread message its witness — same law as the TTV-5 `:init` heir note).
- `smalt_store_partition.erl` — gen_server partition worker owning one named PUBLIC ets table `smalt_store_p0..15`, heir = the dedicated heir process. Adoption on restart: if `ets:whereis/1` finds the table alive under heir ownership, the fresh worker keeps it and every key in it (ownership RESTS WITH the heir; no reclaim attempted — public table, all ops public). `list_to_atom` for partition names is compile-time-bounded: 16 fixed names from N∈0..15 at sup boot, never wire input — safe by construction.
- `smalt_store.erl` — facade: `get/1` bypasses all mailboxes (direct `ets:lookup` on the public named table); `put_cas/3`, `delete/1` route via `phash2(Key, 16)` to the owning partition worker for serialized CAS. Semantics: correct etag → `ok`; stale/wrong etag on an existing key → `{error, etag_mismatch}`; `any`/`undefined` accepted only on empty keys; phash2-derived etags (`phash2({key_tag, Key, unique_integer})` — a value change always yields a new etag); deterministic partition naming.
- `smalt_store_sup.erl` — heir FIRST, then 16 permanent partition workers, `one_for_one 5/10`.

## Court — `test/courts/court_store_partition_SUITE.erl`

Operator contract, verbatim commands (scratch compile dir `/tmp/store4court`, court .beam beside the four src .beams):

```
$ export PATH="$HOME/.asdf/shims:$PATH"   # OTP 29 required (asdf pin 29.1.2; bare `erl` on PATH resolves OTP 28)
$ erlc *.erl && erl -pa . -noshell -s court_store_partition_SUITE run_court; echo "EXIT=$?"
== STORE-4 partition court ==
STEP 1 boot 16 partitions + heir: ok
STEP 2 pinned keys: 2 -> partition 4, 24 -> partition 5
STEP 3 seed K4/K5: ok
STEP 4 etag accept/mismatch refusal: ok
STEP 5 mailbox-free get: ok
STEP 6+7 exit(kill) P4 witnessed DOWN, concurrent P5 CAS ok
STEP 8 partition-4 respawned as <0.100.0> (bounded yield loop)
=SUPERVISOR REPORT==== 21-Oct-2026::21:23:07.335964 ===
    supervisor: {local,smalt_store_sup}
    errorContext: child_terminated
    reason: killed
    offender: [{pid,<0.88.0>},
               {id,{smalt_store_partition,4}},
               {mfargs,{smalt_store_partition,start_link,[4]}},
               {restart_type,permanent},
               {shutdown,5000},
               {child_type,worker}]
STEP 9 zero-loss heir check (K4 survived exit(kill)): ok
STEP 10 post-recovery mutation + P5 integrity: ok
COURT RESULT: 4/4 PASS
EXIT=0
```

The supervisor report in the transcript IS the kill's witness (child_terminated reason killed, restart_type permanent). Re-run stability: 3 total runs, all EXIT=0, same 4/4 PASS. Court uses NO sleeps — bounded `erlang:yield` retry loops only (respawn await: up to 50k yields; DOWN receive bounded 5s `after`, not a sleep).

## mix integration

`mix.exs` `erlc_paths: ["lib/smalt/pipeline", "src"]`. `MIX_BUILD_ROOT=_build-store4 mix compile` → exit 0; all four beams land (`_build-store4/dev/lib/smalt/ebin/smalt_store{,_heir,_partition,_sup}.beam`); zero errors/warnings from `src/` modules (the one warning in output is `lib/smalt/store/heir.ex:76` — pre-existing, another lane's file, not session-introduced by this lane).

## Honest integration note (per dispatch)

The Elixir `Smalt.Store` (heir-to-init, TTV-5) and this Erlang partition store
currently COEXIST — no Elixir store code was removed and no data plane was rewired in this lane.
The Erlang partition store is the operator-mandated target architecture standing alongside as a
proven court-subject; the Elixir facade migration (routing the three planes onto phash2
partitions) is the follow-up WO, with STORE-2 (supervision wiring) and STORE-3 (wire regression)
lanes already dispatched against it. No commit made (per dispatch).

## Falsifier

Delete `_build-store4`, re-run the court fresh; any FAIL, nonzero exit, or a lost K4 after
`exit(kill)` flips this receipt to SUSPECT. STEP 9 is the heir falsifier specifically:
if K4 survives via anything other than heir transfer, the adopted-table check must fail.
