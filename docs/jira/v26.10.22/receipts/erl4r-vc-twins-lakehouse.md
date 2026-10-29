# ERL-4r receipt: VC export + digital twins + lakehouse mount

- **Standing:** ALIVE (court 8/8 PASS, exit 0)
- **Context**: solo
- **Subject**: /Users/sac/smalt @ main, uncommitted working tree (ERL-4 relaunch; no partial files found on disk — audited `src/smalt_vc_export.erl`, `smalt_digital_twins.erl`, `smalt_lakehouse_mount.erl`, court file: all absent, minted fresh)
- **Date**: 2026-10-22
- **Exits**: erlc 0, court 0

## Landed

| File | Role |
|---|---|
| `src/smalt_vc_export.erl` (new) | W3C VC 2.0 JSON-LD export of ARM receipts. `mint_vc_jsonld/3` enforces the 40-word invariant (`erts_debug:size(Receipt) =:= 40` heap words; off-invariant → typed exit `{word_size_invariant_violation, WS}`), byteSize = 8×40 = 320; digest = sha256 over the deterministic `term_to_binary(Receipt)`; proof = hex HMAC-SHA256 over canon(VC minus proof); issuer `urn:smalt:sovereign:substrate`; type `DataIntegrityProof`, cryptosuite `blake3-sha256-rdfc-2026`, purpose `assertionMethod`. `verify_vc/3` → `ok \| {error, vc_proof_signature_tampered}` (tampered subject, tampered proofValue, wrong key, non-map garbage all refuse). |
| `src/smalt_digital_twins.erl` (new) | `upsert_twin/4` (DTMI envelope → `smalt_wasm_pool:gl_call(1, EnvBin)` → `dt:twin` put_cas + journal row), `link_twins/5` (RDF triple → Op 1 → `dt:edge` put_cas + journal row), `query_twins/2` (Op 15 dispatch through `gl_call(15, ...)`; admits decode the `<<0:8,Result>>` wire form, refusals decode the andon wire to `{refused, Reason}`). |
| `src/smalt_lakehouse_mount.erl` (new) | `discover_sealed_segments/1` — a segment counts only when BOTH `.seal` sentinel AND matching `.wal` exist; sorted. `execute_analytical_query/2` / `op15/1` — Op 15: admit `<<0:8,Result>>`, refusal andon `<<1:8,Len:32,Reason/binary>>`; pull-cord classified on the DECODED inner query (a tbinary envelope never leads `<<1:8>>`); refusal fires before any segment read; malformed bodies refuse (never crash). |
| `src/smalt_wasm_pool.erl` (edited, ERL-1 module) | `gl_call/2` extended with integer op clauses: `gl_call(1, Body)` → sieve classification; `gl_call(15, Body)` → delegates to `smalt_lakehouse_mount:op15/1`. Back-compat: `gl_call(sieve, ...)` and `{unknown_gl_op, Op}` unchanged. |
| `test/courts/court_vc_twins_lakehouse_SUITE.erl` (new) | 8-step court; no sleeps; real ets store (booted 16-partition `smalt_store_sup` + heir), real crypto, real files in a tmp mount root. |

## 40-word invariant (receipt-term law)

`erts_debug:size/1` counts heap words of the TERM (a binary of any size measures flat), so the invariant is pinned on the receipt term itself. The court's pinned shape (`court_receipt/0`):

```erlang
Dig = crypto:hash(sha256, <<"court-body">>),
#{op => put,
  resource => [<<"s1">>, <<"rg1">>],
  etag => <<0:72>>,               %% 9-byte etag binary -> 4 heap words
  wall_ms => 1_735_000_000_000,   %% small int -> 0 extra words
  sieved => {sieved, 0, Dig},     %% 32-byte digest -> 8 words
  digest => Dig}
%% erts_debug:size = 40 words exactly; byteSize = 8 * 40 = 320
```

## Court transcript (fresh clean erlc, real output)

```
$ erlc -o /tmp/erl4-ebin/ src/smalt_store.erl src/smalt_store_sup.erl \
      src/smalt_store_partition.erl src/smalt_store_heir.erl \
      src/smalt_journal_sink_compat.erl src/smalt_wasm_pool.erl \
      src/smalt_vc_export.erl src/smalt_digital_twins.erl \
      src/smalt_lakehouse_mount.erl \
      test/courts/court_vc_twins_lakehouse_SUITE.erl
erlc exit 0
$ erl -pa /tmp/erl4-ebin/ -noshell -s court_vc_twins_lakehouse_SUITE run_court
== VC / digital twins / lakehouse mount court ==
STEP 1 boot real 16-bucket smalt_store_sup: ok
PASS 2 VC mint: 40-word/320-byte invariant, sha256 digest, HMAC proof, W3C VC 2.0 shape, deterministic re-mint
PASS 3 VC verify ok; tamper/wrong-key/garbage -> vc_proof_signature_tampered
PASS 4 twins upsert: gl_call Op 1 -> dt:twin put_cas + journal row (real ets)
PASS 5 twins link: RDF triple -> Op 1 -> dt:edge store + journal row (real ets)
PASS 6 query_twins Op-15 admit: segments + deterministic rows
PASS 7 sieve refusal: pull-cord + malformed -> andon wire, zero mutation on the store
PASS 8 lakehouse: 2 sealed + 1 unsentinel'd -> exactly 2 sorted; Op-15 admit <<0:8,_>> / refusal andon wire
COURT RESULT: 8/8 PASS
court exit 0
```

Verified 8/8 PASS exit 0 across three consecutive runs (two incremental, one fresh-clean erlc).

## Laws witnessed

- **Zero dynamic atoms on wire paths**: `grep -n "list_to_atom\|binary_to_atom\|list_to_existing_atom"` over all four new/edited src modules → zero matches (grep exit 1).
- **Andon zero-mutation**: the pull-cord and malformed refusals leave the seeded twin byte-identical (step 7 re-reads the real ets row).
- **Wire-compat**: `gl_call(sieve, ...)` behavior unchanged; integer ops 1/15 are additive clauses.

## Falsifier / replay

Replay: `erlc` + `erl -pa ... -noshell -s court_vc_twins_lakehouse_SUITE run_court` per transcript above; any step badmatch or exit != 0 falsifies ALIVE.

## Notes

- Scratch erlc ebin dirs (`ebin/`, `ebin-court-erl4/`, `/tmp/erl4-ebin/`) were removed from the repo tree; `/tmp` probe remnants (`/tmp/erl4-ebin`, `/tmp/smalt-erl4-lakehouse-court`, `/tmp/ws_probe.*`, `/tmp/erl_crash.dump`) were left in place — their deletion was denied by the permission system in this session.
- Not committed, per dispatch.
