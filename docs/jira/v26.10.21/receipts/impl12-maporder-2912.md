# IMPL-12 — Deterministic map-order adjudication on pinned OTP 29.1.2

Context: solo

**Standing:** **CONFIRMED-on-pinned-release** (typed flip of AR-POWL-02 from REFUTED-as-claimed)
Date: 2026-10-21 · Lane: IMPL-12 (probe; lib/ untouched) · Repo: /Users/sac/smalt

## Subject and authority

- Adjudicated subject: the pinned release `~/.asdf/installs/erlang/29.1.2/bin`
  (invoked explicitly, not via PATH/asdf shim). `erlang:system_info(otp_release)` = `29`.
- Claim under adjudication (ARD-PRD.md:181 / VALIDATION.md AR-POWL-02): "OTP 29 map
  iteration order is deterministic across runs and processes, so Merkle digests may
  stream through `maps:fold/3` without intermediate sorting."

## What ran (receipt-grade output)

Probe: `tmp/otp29_probes/p4_maporder_2912.escript` (adapted from p4_maporder.escript;
adaptation fixes two defects in the original — see "Prior-evidence correction" below).
3 independent escript invocations on 29.1.2, each leg = 100 map builds + 20 child
processes + map comprehension + maps:to_list, sizes 8/12/16/32/64/256:

```
otp=29 escript_pid=<0.10.0>
LEG #{n => 8,stable_of_100 => 100,child_equiv => 20,comp_ok => true,to_list_ok => true}
LEG #{n => 12,stable_of_100 => 100,child_equiv => 20,comp_ok => true,to_list_ok => true}
LEG #{n => 16,stable_of_100 => 100,child_equiv => 20,comp_ok => true,to_list_explicit => true}
LEG #{n => 32,stable_of_100 => 100,child_equiv => 20,comp_ok => true,to_list_ok => true}
LEG #{n => 64,stable_of_100 => 100,child_equiv => 20,comp_of_hash => true,to_list_ok => true}
LEG #{n => 256,stable_of_100 => 100,child_equiv => 20,comp_ok => true,to_list_ok => true}
DONE   (identical across all 3 runs)
```

Cross-run/cross-release fingerprint (`erl -noshell -eval`, phash2 of
`[K || K := _ <- M]` for a 256-key map, 3 runs per release, explicit per-release
binary; every line below is verbatim, runs within a release were byte-identical):

```
MAPFP rel=26.2.1   phash2=1vfje5  first8=[65,202,50,36,158,151,191,137]
MAPFP rel=28.3     phash2=yjnri   first8=[54,18,169,96,94,84,160,4]
MAPFP rel=28.5.0.2 phash2=yjnri   first8=[54,18,169,96,94,84,160,4]
MAPFP rel=29.0.6   phash2=yjnri   first8=[54,18,169,96,94,84,160,4]
MAPFP rel=29.1.1   phash2=yjnri   first8=[54,18,169,96,94,84,160,4]
MAPFP rel=29.1.2   phash2=yjnri   first8=[54,18,169,96,94,84,160,4]
```

## Verdict (typed)

- **AR-POWL-02 flips: REFUTED-as-claimed → CONFIRMED-on-pinned-release.**
  On 29.1.2: `stable_of_100=100/100` at every size (8..256), child-process equivalence
  `20/20`, map comprehension order ≡ `maps:keys` order ≡ `maps:to_list` order, and the
  256-key fingerprint `yjnri` is byte-identical across runs AND across 28.3/28.5.0.2/
  29.0.6/29.1.1/29.1.2. Within any pinned 28+/29 release the order is deterministic.
- **Scope boundary (do not over-claim):** the order is deterministic per release, not
  a language guarantee. OTP 26.2.1 yields a different order (`1vfje5`). The claim
  "OTP 29 traverses deterministically" is true as a release-stability fact; it is NOT
  portable across major OTP generations. `maps:fold/3`-without-sorting is therefore
  admissible **only** under a pinned toolchain + fingerprint court.
- The landed `Smalt.PPlan.ReceiptEngine` (`lib/smalt/pplan/receipt_engine.ex`,
  ordered-tuple hashing with `{epoch,seq}` sort) remains correct as-is; this probe
  does not require any lib/ change. **Nothing in lib/ was modified.**

## Prior-evidence correction (load-bearing)

The prior 0/100 evidence (`receipts/val-ar-powl.md`, probe `p4_maporder.escript`) is a
harness artifact, not a stability observation:

1. `go/3` incremented its counter in BOTH the true and false branches — the reported
   `stable_of_100` was hardwired to 100/100 regardless of actual order behavior. (The
   recorded `0/100` therefore could not have been produced by the on-disk file as it
   stands; the file was evidently a later, differently-broken revision of the probe
   that ran.)
2. The child leg `spawn(fun() -> exit(keys() =:= Ref) end)` with parent
   `receive {P, true} ...` can never match — `exit(Reason)` in an unlinked process
   sends no message to the parent. The recorded `child_equiv=0/20` measured the
   receive timeout, not order divergence.

The adapted probe uses an explicit `Parent ! {self(), Result}` send and a branch-
asymmetric counter. Both prior cells were measuring the harness, not the map.

## Work-order proposal (NOT implemented — Merkle simplification)

**WO-PROPOSAL (IMPL-12): ReceiptEngine digest path may drop the `{epoch,seq}` sort
in favor of raw `maps:fold/3` streaming — gated, not unconditional.**

- Premise now witnessed: on OTP 28.3+/29.x the map iteration order is
  run-stable, process-stable, and patch-release-stable, and comprehension/`to_list`/
  `keys`/`iterator` agree, so a fold-order digest is a deterministic function of the
  map on a pinned toolchain.
- Preconditions for adoption (all mechanical, each gate must exit 1 on violation):
  1. Toolchain pin gate: digest path asserts `otp_release` major ≥ 28 AND a recorded
     order fingerprint (e.g. `erlang:phash2(maps:keys(FixMap))` on a fixed 64-key
     sentinel map) matches the pinned constant; mismatch ⇒ typed
     `{:order_fingerprint_mismatch, got, want}` refusal, no digest produced.
  2. Byte-identity court: for a fixed run, re-seal root MUST stay byte-identical
     incl. cold DETS reopen (existing 6/6 ReceiptEngine tests re-run green).
  3. Cross-release negative fixture: run the fingerprint gate against a 26.x binary
     (26.2.1 fingerprint `1vfje5` ≠ `yjnri`) and require it to REFUSE — proves the
     gate is not vacuous.
- Expected gain: removes one `lists:sort/1` per seal walk (O(n log n) → O(n)) on the
  Merkle sealing path; simplification, not a correctness fix (current code is ALIVE).
- Risk if adopted without gate 1: a future OTP release rehashing maps would mint
  run-order-dependent digests — silent audit-integrity divergence. This is exactly
  the failure the snippet-review flagged; the gate converts the premise into an
  observed invariant.

## Falsifiers

- This flip reverses if any of: (a) 29.1.2 run shows `stable_of_100 < 100` at any
  size with the corrected probe; (b) two child processes on 29.1.2 disagree; (c) the
  256-key fingerprint differs across two runs of the same 29.1.2 binary; (d) map
  comprehension order diverges from `maps:keys` order.
- The proposal (not the flip) is refuted if gate 3 (26.x refuses) cannot be made to
  fail-closed on a real 26.2.1 binary.

## Receipt fields

- Exact subject: erlang 29.1.2 (`/Users/sac/.asdf/installs/erlang/29.1.2/bin`), smalt
  repo tmp probe `p4_maporder_2912.escript` (tmp/, gitignored — the receipt carries
  the full script behavior description above).
- Commands: see "What ran"; exit 0 on all probe runs.
- Consequence: AR-POWL-02 typed flip + WO-PROPOSAL minted; VALIDATION.md cell owner
  (coordinator) may consume this receipt to update the register; this lane did not
  edit VALIDATION.md or lib/.
- **Standing:** CONFIRMED-on-pinned-release (PARTIAL_ALIVE as a portable claim — pinned
  to 28+/29 fingerprint `yjnri`).
