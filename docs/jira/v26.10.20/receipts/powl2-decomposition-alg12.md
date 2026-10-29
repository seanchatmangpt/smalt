# POWL-2: Algorithms 1 & 2 (conflict-/concurrency-hiding partition)

**Standing:** ALIVE

Lane: POWL-2 (writer). Build root: `_build-powl2`.

## Files

- `lib/smalt/powl2/decomposition.ex` (new, 274 lines) —
  `Smalt.Powl2.Decomposition`
- `test/internal/powl2_decomposition_test.exs` (new, 230 lines, 20 tests)

## What landed

- `partition_mg/1` (Algorithm 1): conflict-hiding partition over the
  XOR relation (transitions sharing an input place), union-find
  merging (union by rank, recursive find).
- `partition_sm/1` (Algorithm 2): concurrency-hiding partition over
  the AND relation (distinct input places sharing a producer
  transition, not in conflict), plus scope closures absorbing the
  delimiting AND-split (transition whose distinct output places
  immediately enable the pair) and AND-join (place whose >= 2
  producers are pairwise concurrent and not conflicting, plus its
  direct consumers).
- Validators `conflict_hiding?/2`, `concurrency_hiding?/2` (Defs 4.1 /
  4.4): relation pairs never cross groups, groups cover every
  transition, and every merged group (size >= 2) is a block — induced
  subnet has exactly one entry place (empty preset) and one exit place
  (empty postset): entry/exit place equivalence with a WF-net block.
  `block_group?/2` exported for the equivalence check itself.
- Relations exported for courts: `conflict_pairs/1`,
  `concurrent_pairs/1`.

## Definitional provenance caveat

Def-numbered semantics (4.1/4.4/4.5/4.6) are reconstructions over
`Smalt.PetriNet` as specified in the work order. The concurrency
relation is exact for sound free-choice WF-nets with
single-input-place transitions; a first-cut restricted-reachability
mutual-membership relation was REFUTED in-session (mislabels sequenced
pairs across an XOR block: xa vs pa both avoiding-reachable via the
XOR sibling) and replaced by the place-level producer relation before
landing. Paper-exact cross-check remains open.

## Test output (2 consecutive green runs)

    Finished in 0.06 seconds (0.06s async, 0.00s sync)
    20 tests, 0 failures

    Finished in 0.06 seconds (0.06s async, 0.00s sync)
    20 tests, 0 failures

Combined with POWL-1's suite:

    Finished in 0.07 seconds (0.07s async, 0.00s sync)
    38 tests, 0 failures

Commands:

    MIX_BUILD_ROOT=_build-powl2 mix test test/internal/powl2_decomposition_test.exs

## Session incidents (disclosed)

1. My files were externally deleted twice mid-session
   (`lib/smalt/powl2/decomposition.ex` zeroed, then the whole `powl2/`
   dir gone, alongside `lib/smalt/petri_net.ex`); POWL-1's dependency
   re-landed with an identical API and my module was rebuilt. Current
   on-disk state is verified.
2. Three compile-freeze windows caused by other lanes' in-flight
   syntax/compile errors (`amqp/connection.ex:1570`,
   `powl2/change_feed.ex`, `powl2/compiler.ex:81` and a spec/arity
   mismatch). All resolved by their owners; no unblock edits applied
   to foreign files.
3. Two bugs found and fixed in my own code: vacuous
   `join_place?([], ...)` guard (an empty-preset place merged its whole
   postset) and a single-element `merge_all` no-op that dropped the
   AND-join consumer from the module.
4. One wrong test expectation of mine (both-net group count 5 vs
   arithmetic 3) corrected to 3.

## Falsifiers (open)

- Nested XOR inside an AND branch deeper than the immediate-successor
  scope closure: the AND-split absorption only handles
  directly-enabled pairs.
- `partition_mg`'s singleton groups are exempt from the block check;
  an AND-split singleton (`{split}` in the parallel diamond) is not
  itself a WF-net block. Court-grade use of Def 4.1 may require the
  finer rule.
