# VAL-POWL — AR-POWL-01..03 validator receipt

**Standing:** **PARTIAL_ALIVE** (3/3 cells verdict-command-backed; 2 typed as dispatched, 1 inverts the dispatch's premise on evidence)
Context: solo
Date: 2026-10-21
Toolchains (re-read at use time):
- OTP 28.3.1 (erts 16.2), `~/.erlmcp/otp-28.3.1/bin` — host toolchain
- OTP 29.1.1 (erts 17.1), `~/.asdf/installs/erlang/29.1.1/bin`
- Elixir 1.19.5 (OTP 28 build) — host mix; probes are toolchain-free escripts

## Method

Every cell below is settled by a re-run of the landed probe escripts in
`tmp/otp29_probes/` (`p3_eep79.escript`, `p4_maporder.escript`) executed at
receipt time — 2026-10-21T19:31:27Z — plus one NEW probe (`p8_functional_graph.escript`,
landed in the same dir) for AR-POWL-03. Command outputs are embedded verbatim.
The prior receipt `docs/jira/v26.10.20/receipts/otp29-capability-probes.md`
(claims 3 and 4) is cited and its numbers were re-read and re-produced on disk,
not recalled.

## Verdict table

| # | Requirement (ARD-PRD §2.5) | Probe evidence (this machine, 2026-10-21) | Cell |
|---|---|---|---|
| AR-POWL-01 | EEP-79 native records for compiler ASTs | `p3_eep79.escript` re-run on both toolchains: `EEP79 otp=28 forms_rejected=illegal_or_badarg` + `EEP79 nodecl_compiles=no`; `EEP79 otp=29 forms_rejected=illegal_or_badarg` + `EEP79 nodecl_compiles=no`. Records still require `-record` declarations on 28.3.1 AND 29.1.1. | **UNSUPPORTED** — EEP-79 native records are not shipped in OTP 29.x on any pinned toolchain (OTP29PROBE = UNAVAILABLE). ALIVE requires an OTP release that ships EEP-79. |
| AR-POWL-02 | Deterministic Merkle hashing via "OTP 29 deterministic map iteration" | `p4_maporder.escript` re-run, verbatim: `MAPORDER otp=29 stable_of_100=0/100 child_equiv=0/20` and `MAPORDER otp=28 stable_of_100=0/100 child_equiv=0/20` (29.0.6 identical per the 2026-10-20 receipt). Map iteration order is unstable on every pinned toolchain. | **REFUTED-as-claimed, ALIVE-as-implemented** — the claimed mechanism ("OTP 29 deterministic map iteration", `maps:fold/3` without sorting) does not exist; the landed `Smalt.PPlan.ReceiptEngine` (`lib/smalt/pplan/receipt_engine.ex`) achieves byte-identical receipts WITHOUT it: hashes over the ordered tuple `{epoch, seq, act_iri, entity_iri, delta_hash, prev_hashes}` (ts excluded by hash law), seal walk sorts by `{epoch, seq}`. |
| AR-POWL-03 | Functional graph module in OTP 29 STDLIB | NEW probe `p8_functional_graph.escript`: OTP 29.1.1 `code:which(graph)` → `.../stdlib-8.1/ebin/graph.beam`, runtime legs all pass (transcript below); OTP 28.3.1 → `which(graph)=non_existing`, runtime = `undef`. | **CONFIRMED on 29 / UNAVAILABLE on 28** — this cell INVERTS the dispatch's "likely REFUTED" expectation: OTP 29.1.1 stdlib-8.1 ships a purely functional `graph` module (Apache-2.0, Ericsson, `-doc since "OTP 29.0"`), modeled on `digraph` but immutable and table-free. |

## AR-POWL-02 implementable-side witness (real module, real run)

`Smalt.PPlan.ReceiptEngine` compiled from the landed file and exercised
standalone (module has zero intra-repo deps):

```
$ elixir /tmp/powl6_reseal.exs
RESEAL seals=3 root_identical=true ntriples_identical=true root_sha256=a0139386f33c7038f7b2e470235a3201167c0ebad320cbc9683b9b6df0682374
```

Three seals — two in-process, one after cold DETS close/re-open — over a
40-step run: byte-identical `merkle_root` and `ntriples`. Insertion-order
shuffle is NOT a determinism axis (prev_hashes chain insertion order by
design); the determinism claim under test is re-seal stability for a fixed
run, which holds. Corroborated by the in-repo suite (run in the lane build
root after the owner of `lib/smalt/apim.ex` cleared its in-flight compile
break under the compile-freeze SLA):

```
$ MIX_BUILD_ROOT=_build-lane-val mix test test/internal/pplan_receipt_engine_test.exs
Finished in 0.1 seconds (0.00s async, 0.1s sync)
6 tests, 0 failures
```

(includes POWL-6 "deterministic re-seal: same steps, same receipt" —
asserts resealed == receipt).

## AR-POWL-03 probe transcript (verbatim)

```
$ PATH="$HOME/.asdf/installs/erlang/29.1.1/bin:$PATH" escript p8_functional_graph.escript
GRAPH verts=4 edges=4 immut_original={[],0}
GRAPH dag_acyclic=true cyc_acyclic=false
$ PATH="$HOME/.erlmcp/otp-28.3.1/bin:$PATH" escript p8_functional_graph.escript
escript: exception error: undef — module `graph` non_existing (code:which(graph) = non_existing)
```

Immutability leg: after building a 4-vertex/4-edge graph from `G0`,
`graph:vertices(G0)` is still `[]` and `out_degree(G0, a) = 0` — the original
term is untouched. `graph:is_acyclic/1` discriminates DAG (`true`) from
1-edge cycle (`false`). The module exposes `topsort/1`, `is_acyclic/1`,
`components/1`, `strong_components/1`, `condensation/1`, `subgraph/2` — the
exact surface AR-POWL-03 names for immutable compiler passes.

## Provenance notes

- `lib/smalt/petri_net.ex` is already pure-functional regardless of the probe
  outcome: pure struct module (227 lines, `defstruct` + derived adjacency
  maps, zero `GenServer`/`Agent`/`:ets`/`Process.sleep` references; moduledoc
  "Pure struct functions, no process"). AR-POWL-03's "eliminate ETS-based
  digraph" problem statement is already satisfied in-tree; the OTP-29
  `graph` module is a native-stdlib replacement option, CONFIRMED available.
- One transient cross-lane event: `lib/smalt/apim.ex` (another lane's
  untracked in-flight file) failed to compile during my first suite attempt
  (`type policy/0 undefined`); its owner cleared it within minutes per the
  compile-freeze SLA, and the quoted suite run is the post-clear green run.
  I made no edit to `apim.ex`.
- Probe files are scratch (`tmp/otp29_probes/`, gitignored); the landed
  versions are the green ones whose outputs are quoted.

## Falsifiers

- AR-POWL-01 flips to CONFIRMED when `escript p3_eep79.escript` prints
  `nodecl_compiles=yes` on a pinned toolchain (i.e., an OTP release ships
  EEP-79).
- AR-POWL-02 flips to CONFIRMED-as-claimed when `escript p4_maporder.escript`
  prints `stable_of_100=100/100`; flips to NOT-ALIVE-as-implemented if any
  re-seal of a fixed run yields a different root (`elixir /tmp/powl6_reseal.exs`).
- AR-POWL-03 flips to REFUTED if `code:which(graph)` is `non_existing` on a
  future 29.x pin, or `is_acyclic/1` returns `true` on a 1-cycle graph.

## See Also

- `docs/jira/v26.10.20/receipts/otp29-capability-probes.md` — claims 3/4/6 prior receipts (re-read at use time)
- `docs/jira/v26.10.21/ARD-PRD.md` §2.5 — the three requirements validated here
- `lib/smalt/pplan/receipt_engine.ex`, `lib/smalt/petri_net.ex` — landed implementations
- `test/internal/pplan_receipt_engine_test.exs` — POWL-6 re-seal court
