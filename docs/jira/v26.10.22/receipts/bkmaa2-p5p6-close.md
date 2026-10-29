# Receipt: BK-MAA2 — MAA P5/P6 close (adversarial re-verification + F1 repair)

- **Lane**: BK-MAA2
- **Date**: 2026-10-22
- **Subject**: `lib/smalt/attestation/maa.ex` sha256 `7455f8cdcaf06a2549f0ac2d3be1e76cdf094ff2a76bdbc0a998fe598e9370e0`
  (post-F1-fix); court `tmp/bkmaa2_probe_test.exs` (scratch probe, not committed);
  audit receipt `docs/jira/v26.10.22/receipts/bkmaaskep-maa-audit.md` (P5/P6 resolution pointers — this lane's edits)
- **Standing**: **ALIVE** — P5 and P6 both RESOLVED and adversarially verified;
  one new defect (F1) found and fixed by this lane.
- **Context**: solo

## Landing timeline (honest, as-of-statement)

BK-MAAP6's receipt was in-flight at lane start (bounded-poll ~60 s, not landed);
verification began against the working tree (BK-MAAP6's maa.ex + court were on
disk). BK-MAAP6's receipt `bkmaap6-nonce-bounds.md` landed mid-lane and shows it
covered **both P5 (owner-ref) and P6 (bounds)** — so this lane is
**verify-only on P5/P6 + one repair (F1)**; the P5 latent was addressed by
BK-MAAP6, no additional owner-ref work needed.

## (1) Adversarial re-verification of BK-MAAP6's fixes

Scratch ExUnit probe `tmp/bkmaa2_probe_test.exs` — real `Maa.attest/3`, real
ETS, real spawned processes/Task concurrency. No mocks, no sleeps. Final run:

```
$ MIX_BUILD_ROOT=_build-maa2 mix test tmp/bkmaa2_probe_test.exs
Result: 5 passed          (0 failed)
```

Legs (all PASS post-F1):

| Leg | Adversarial angle beyond BK-MAAP6's court | Witness |
|---|---|---|
| A1 | 300 distinct-nonce attests → row count must equal 300; sweep with far-future real timestamp deletes exactly 300 → size 0 | `Result: 5 passed` leg A1 |
| A2 | Oversized nonce (257 B) refused typed **with the table never created**; boundary nonce at exactly 256 B accepted | witnessed the F1 crash pre-fix (see below); typed refusal + table-absent post-fix |
| A3 | Stale `:pending` swept (ts − 100 000), live `:pending` survives sweep AND survives entry-cap eviction under a full table (65 536 consumed rows + 1 pending, attest evicts oldest consumed, pending intact) | leg A3 |
| A4 | Owner-ref 3 ways: (a) failed attest (measurement mismatch) releases its OWN reservation → nonce re-usable; (b) consumed row survives the owner's own nonceReplay retry (release_nonce can never match a consumed row); (c) third process cannot re-reserve a consumed nonce | leg A4 |
| A5 | 100 concurrent attests (20 nonces × 5) → exactly 20 issues, exactly one `:consumed` row per nonce, table size 20 | leg A5 |

Two probe-authoring defects were caught and fixed during development
(duplicated assertion block in A4; 257-byte boundary nonce in A2) — both were
test bugs, not product behavior; recorded for honesty.

## (2) F1 — NEW defect found and fixed (release_nonce crash on absent table)

**Witnessed failure (pre-fix)**: on a fresh VM (`:smalt_maa_nonces` never
created), `Maa.attest/3` with an oversized nonce refuses typed BEFORE the
nonce table exists, but the attest/3 else-path then calls `release_nonce/1`
→ unguarded `:ets.match_delete/2` → **ArgumentError crash out of attest/3**
instead of the typed 400 refusal:

```
** (ArgumentError) errors were found at the given arguments:
  * 1st argument: the table identifier does not refer to an existing ETS table
  code: attest(String.duplicate("z", Maa.nonce_max_key_bytes() + 1))
  (smalt 26.10.19) lib/smalt/attestation/maa.ex:485: Smalt.Attestation.Maa.release_nonce/1
  (smalt 26.10.19) lib/smalt/attestation/maa.ex:216: anonymous fn/4 in Smalt.Attestation.Maa.attest/3
```

**Fix (BK-MAA2, maa.ex `release_nonce/1`)**: `:ets.whereis(@nonce_table) !=
:undefined` guard — closed/absent table is an idempotent no-op, same idiom as
`sweep_expired_nonces/1` and `evict_oldest_consumed/0`'s rescue. Comment tag
`BK-MAA2 (F1)`. Post-fix leg A2 passes: typed refusal, table still absent,
boundary nonce at cap accepted.

## (3) Full MAA suite fresh (this session, this tree, post-fix)

```
$ MIX_BUILD_ROOT=_build-maa2 mix test test/internal/az2_maa_attestation_court_test.exs \
    test/internal/bkmaap6_nonce_bounds_court_test.exs test/internal/expl8r_court_test.exs \
    test/internal/expl3_dataplane_repairs_court_test.exs test/internal/az4_mhsm_release_policy_court_test.exs \
    test/internal/expl5r1_court_test.exs
Result: 47 passed          (0 failed)

$ bash scripts/shim_court/az2_maa_court.sh
[PASS] az2_maa_court: non-vacuous (landed attests, shimmed ATTESTS-tampered, restore byte-exact)
  baseline sha256(lib/smalt/attestation/maa.ex) = 7455f8cd…70e0; RESTORE verified byte-exact
```

## Verdict

- **P6 RESOLVED, ALIVE** — bounded three ways (key cap / TTL sweep / entry
  cap), adversarially confirmed incl. table-absent intake and pending-row
  protection.
- **P5 RESOLVED, ALIVE** — owner-ref'd reservations; self-release, no
  cross-delete, single burn under 100-way concurrency, consumed row immune to
  release.
- **F1 fixed by this lane** (unguarded release_nonce on absent table → typed
  refusal preserved). Standing **ALIVE**.
