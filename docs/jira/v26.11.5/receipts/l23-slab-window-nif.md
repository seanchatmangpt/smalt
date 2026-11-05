# L23r — aq_slab_window NIF surface 2 (window views over slab frames)

Standing: ALIVE

## Subject
/Users/sac/cgap @ HEAD; crates/cgap-beam only (aq_slab.rs + tests/aq_slab_contract.rs).
L23 died on 429; L19 landed the slab foundation at dfd9ae4f, including the
committed aq_slab_window NIF, window_bounds law + env mutation
AQ_MUTATE_WINDOW_OOB_SKIP, and Rust unit tests. Resume built ON L19's
machinery, adding only what was missing:

1. **Lease-respect** (src/aq_slab.rs:633-639): aq_slab_window now loads the
   free-list bitmask and refuses a leased slot (typed SlabErr::SlotLeased →
   the `error` atom), reusing L19's AqLease machinery and the existing
   SlotLeased variant.
2. **BEAM court legs** (tests/aq_slab_contract.rs):
   - `t_window_lease_respect`: stamp frame → in-bounds window succeeds →
     child process leases slot → window refuses (`error`) while held →
     release → bounded poll on the window observable (garbage_collect loop,
     no sleep) until the dtor clears the bit → window succeeds. Real
     collaborator: real BEAM via escript, real segment files, no mocks.
   - `t_window_oob_mutant` + main/1 env dispatch: under
     AQ_MUTATE_WINDOW_OOB_SKIP=1 only the mutant leg runs; it asserts the
     over-reading window (3,7) past plen=5 is ACCEPTED — flip witnessed as
     exit 0, because an exit-nonzero mutant leg is indistinguishable
     from an unapplied mutation = vacuous. Baseline leg asserts
     `error = aq_slab_window(Slab, 0, 4, 2)` etc. in t_stamp_frame_window.
3. run_court now selects the mutation via an argument; #[test]
   aq_slab_be_court now runs 3 legs: baseline (exit 0), crc mutation (must
   flip, exit nonzero), window-OOB mutation (must PASS, exit 0).

## Mutation verdict (anti-vacuity)
- Mutation AQ_MUTATE_WINDOW_OOB_SKIP=1 (aq_slab.rs:585-592 window_bounds):
  baseline `error = aq_slab_window(Slab,0,4,2)` vs mutant ACCEPT of (3,7).
  Court flips both directions: baseline exit 0, mutant exit 0 under a leg
  that REFUSES if the mutation has no effect (error ->
  {window_oob_mutation_did_not_flip, oob_window_still_refused}).
- Mutation AQ_MUTATE_CRC_SKIP=1: unchanged, still flips (exit nonzero).

## Gates (this session, exact commands + exits)
- cargo build -p cgap-beam → exit 0 (twice)
- cargo test -p cgap-beam → exit 0 ×2 (rerun for stability): 16 unit tests
  + 3 integration test targets (aq_slab_be_court 3-leg, bridge_contract,
  kill_stress) all green.

## Files changed (session diff)
- crates/cgap-beam/src/aq_slab.rs (+7: lease-respect in aq_slab_window)
- crates/cgap-beam/tests/aq_slab_contract.rs (+70: t_window_lease_respect,
  wait_window_ok, t_window_oob_mutant, env dispatch in main/1, 3-leg court)

## Notes
- cgap-beam was clean before this lane; L23's in-flight edits were already
  swept into wip commits; no conflict reconciliation needed (L19's committed
  version kept, only window additions appended).
- Unleased-scope discipline: cgap-crypto untouched; no other crates touched.
