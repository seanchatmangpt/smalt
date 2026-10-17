# The Chatman Invariant

Understanding-oriented. The invariant names the operator's standing
law: a state transition is admissible only when the invariant that
makes it meaningful holds, and an invariant that cannot refuse is not
an invariant. The machinery: the affidavit seal path on the ARM
gateway, the invariant gates in `gates/`, and the SPC band gate over
the invariant metrics.

## Statement

Every state delta that crosses the admission boundary carries a
verifiable invariant — and the system must be able to REFUSE the delta
when the invariant does not hold. Three corollaries:

1. **Refusal is typed.** A violating delta gets
   `{"ok":false,"error":{...}}` from the engine, never a crash, never
   a plausible-looking witness under degraded conditions.
2. **The gate must be able to exit 1.** A gate that cannot refuse is
   decoration. Each gate in `gates/` carries a negative-fixture
   non-vacuity contract: the verdict must REFUSE a mutated observation.
3. **Absence is named, never faked.** A missing witness, missing
   history (SPC SEED mode), or absent b3sum is a named outcome, not a
   synthesized pass.

## Where it lives: the affidavit seal path

The seal path mounts the invariant on every ARM resource PUT/DELETE:
the state delta is admitted through the WASM engine
(`affi_admit_and_seal/1`), and an in-variant-violating delta is refused
by the engine rather than sealed — witnessed by the fail-closed tier of
the operator test. Register of record:
`docs/jira/v26.10.16/receipts/cap-affidavit-wasm.md` (real-run output
embedded: `3 tests, 0 failures` via `scripts/fast_test.sh`); the seal
court: `docs/jira/v26.10.16/receipts/r215-affidavit-seal-court.md`.
Code: `lib/smalt/affidavit/seal.ex`,
`lib/smalt/affidavit/wasm_engine.ex` (typed-error contract at :127,
layout gate at :135-141).

## Where it lives: the invariant gates

`gates/` carries the fail-closed gates (cosmos-etag-cas, blob-worm,
ledger-chain, queue-capacity, lock-clamp), each with a negative fixture
proving the gate can refuse — non-vacuity by construction. Run via
`just invariant-gates`. These are the B4 class in the window's
docs inventory (`docs/jira/v26.10.16/DOCS-INVENTORY.md`).

## Where it lives: SPC over the invariant metrics

`scripts/spc_gate.py` + `config/bands.yaml` bind the operator's SPC
tiers (1σ EVENT / 2σ DISPATCH / 3σ FAIL-CLOSED) to the Chatman
invariant metrics (nfr3 RSS delta, nfr4 residue tables, native stage
timings). A metric with too little history runs in SEED mode — bands
established, no verdict, never a faked z-score. Zero-centered metrics
(NFR-4: any nonzero residue is a breach by definition) are a stronger
law than stdev allows. Receipt: `docs/jira/v26.10.16/sdk-results/spc-bands.md`;
identity proof: `docs/jira/v26.10.16/sdk-results/nfr4-identity-proof.md`.

## Why an affidavit

The seal converts each admissible transition into a tamper-evident
record (352-byte CTRT binding blake3(delta), tariff basis, deontic
modality). That is the invariant's *memory*: once transitions are
sealed, "the invariant held" is a checkable claim about the past, not a
per-run assertion. The full mechanism-by-mechanism register, including
the honest zeroed/absent set, is
`docs/explanation/affidavit-evidentiary-design.md`.

## See Also

- `docs/explanation/two-green-court-law.md` — the same fail-closed
  posture at the release gate
- `docs/explanation/emulation-stance.md` — the same loud-absence
  posture at the wire layer
- `test/smalt_affidavit_wasm_test.exs` — the operator test
- `docs/jira/v26.10.16/WRAP_LEDGER.md` — KD-89 (PQC witness) section
