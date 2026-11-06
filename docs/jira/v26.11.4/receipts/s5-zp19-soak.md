# S-5 — ZP-19 slab/TLS WindowBuffer integration soak (CTQ-03-sidecar B/op row)

Standing: ALIVE

## Subject
`/Users/sac/smalt` bench lane (no lib/ edits, no commit). Real cgap-beam NIF
dylib `priv/aoq/aq_beam_nif` (staged 2026-11-05, contains the aq_slab surface),
driven through a bench-local `bench/cgap_beam.erl` loader (the dylib's
ErlNifEntry.name law requires module `cgap_beam` + one Erlang stub per
ErlNifFunc entry — bad_lib "Function not found" otherwise).

Note on the seed: PLANS.md does not exist in this checkout (no PLANS.md at any
path; ZP-19/G7 rows were re-derived from
`docs/jira/v26.11.5/aq-nif-boundary-spec.md` — "BEAM side: 0 payload B/op"
charter scoped to egress + windows — plus the v26.11.5 L18/L19/L23r receipts
(`docs/jira/v26.11.5/receipts/l23-slab-window-nif.md`), and the dispatch's
CTQ-03-sidecar falsifier: the 0 B/op row must be able to flip under a
payload-proportional twin on a real soak.

## Files owned (all NEW; SM-1's in-flight files untouched)
- `bench/bench_zp19_slab_window.erl` — the soak harness (fresh wire-shm-layout
  segment fixture per size written directly per ring.rs law: 4096 B bookkeeping
  [u64 BE next_ordinal | u32 BE capacity=64], 64 slots x 4096 B; NIF stamps via
  aq_slab_stamp, reads via aq_slab_window(Ord, 0, S)).
- `bench/cgap_beam.erl` + compiled beams in `bench/` (build artifacts).
- This receipt.

## Command + output (exit 0, this session)
    erlc -o bench bench/cgap_beam.erl bench/bench_zp19_slab_window.erl   # exit 0
    timeout 300 erl -pa bench -noshell -s bench_zp19_slab_window run -s init stop
Output (verbatim, /tmp/zp19_soak_final.txt):
== ZP-19 slab/TLS WindowBuffer soak (aq_slab_window) ==
dylib: priv/aoq/aq_beam_nif (SMALT_ROOT=false)
S=1 words/op=14 B/op=112 twin_words_per_op=4.0 verdict={floor,...4.0}
S=256 words/op=14 B/op=112 twin_words_per_op=514.0 verdict={ratio_pass,0.0272}
S=4080 words/op=14 B/op=112 twin_words_per_op=8162.0 verdict={ratio_pass,0.00172}
F1 size-invariance: words(4080)-words(1)=0 (fence <= 4) -> 'PASS'
F3 anti-vacuity: oob=error badrange=error unstamped=error
CTQ-03-sidecar row (measured, this run):
  S=1 B/op=112 words/op=14 verdict={floor,{twin_words_per_op,4.0}}
  S=256 B/op=112 words/op=14 verdict={ratio_pass,0.027237354085603113}
  S=4080 B/op=112 words/op=14 verdict={ratio_pass,0.0017152658662092624}
F1 size-invariance -> 'PASS';  F3 refusal paths -> 'PASS'
SOAK GATE: 'PASS'

## Measured CTQ-03-sidecar row (the ZP-19 integration number)
**aq_slab_window: 14 words/op = 112 B/op CONSTANT across payload sizes
1 / 256 / 4080 B** — 0 payload B/op witnessed: allocation does not scale with
the window length (delta 0 words from 1 B to 4080 B, fence <= 4). The constant
112 B/op is term-box overhead (the sub-binary + resource ref), declared
constant in the spec's court law ("constant term overhead excluded").

## Fences (this soak, all real)
- F1 size-invariance PASS: words(4080)-words(1) = 0 <= 4.
- F2 ratio fence: payload-proportional twin (lists:seq) outruns the real op at
  S=256 (514 words/op vs 14) and S=4080 (8162 vs 14), ratios 2.7e-2 / 1.7e-3
  <= 0.05 band. S=1 typed FLOOR (twin 4 words/op is below the 20-word floor —
  a constant-twin cannot outrun a constant op; F1 carries the claim there).
  Disclosed, never silently passed.
- F3 anti-vacuity (real slab, real error atoms): OOB window (len 5000 > 4080),
  out-of-range window (off 10 len 100 over plen 16), and unstamped-slot
  aq_slab_frame all answer `error`.

## Falsifier status
The G7 falsifier ("0 B/op CTQ-03-sidecar row flips on a real soak") is
SATISFIED by construction: the harness's flip channel is armed and
witnessed — the twin OUTRUNS the real op at S=256/4080 (a payload-proportional
regression in aq_slab_window would push W into the twin's magnitude and flip
F2/F1 red). ZP-19's UNVERIFIED standing flips to ALIVE for the egress+window
surface with this measured row.

## Standing
ALIVE for the egress + window surface (aq_slab_window over the staged cgap dylib).
NOT claimed: full substrate boot soak (the app-level WindowBuffer/TLS integration
was not exercised end-to-end; the bench-level soak was the contracted fallback),
and S=1's ratio row is FLOOR, claim carried by F1 there.
