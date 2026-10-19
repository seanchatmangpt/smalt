# i29-ledger-txid-qualify — ledger transactionId identity law (qualified lookup)

Standing: **ALIVE** (fix verified on real concurrent runs; wire form unchanged)

Context: pair(i29-wave, ledger-writer lane; collision face observed at test/semantic_projection_test.exs:30 per i29-wire-fresh4)

## Defect

`Smalt.Security.LedgerWriter` mints the wire `transactionId` as `"#{seq}.1"`
(lib/smalt/security/ledger_writer.ex:141) — unique **per ledger only**, while
the store key is ledger-qualified (`"#{ledger}/#{tx_id}"`). Any consumer
matching the bare tx_id across the global `:smalt_ledger_transactions` table
(e.g. the semantic-projection face's `Enum.find(..., e.tx_id == ...)`) can hit
a FOREIGN ledger's entry under concurrent scheduling and read a wrong
merkle_root.

## Decision (wire/receipt compatibility)

Mint-time qualification (`"#{ledger}.#{seq}.1"`) was REJECTED: the `"N.1"`
wire form is pinned by real surface tests — `test/strata_compat_test.exs:154`
(`"2.1"`), `test/security/security_hardening_test.exs:370-372` (`"1.1"`,
`"2.1"`, `"3.1"`), `test/security/lens5_crash_class_test.exs:24`, and the
round-trip in `test/sdk-full/ledger.probe.mjs` (append → GET by tx id → list).
Qualifying the mint would be a wire-surface change. Chosen form: **keep the
display form; match lookups on the qualified pair `{sub_ledger_id, tx_id}`**
— internal, zero wire delta.

## Diff

- `test/semantic_projection_test.exs` (collision face, "reads a seeded ledger
  receipt as a LedgerEntry"): the `Enum.find` now matches
  `e.sub_ledger_id == ledger and e.tx_id == tx["transactionId"]`, with the
  identity law documented in-place.
- `lib/smalt/security/ledger_writer.ex` (mint site, `do_append_valid/3`):
  identity-law comment pinning that tx_id is a per-ledger display id, the
  store key is the qualified identity, and the wire form is deliberately not
  qualified (pinned by strata/security-hardening/probe). No code-path change.

## Verification (all with `MIX_BUILD_ROOT=_build-ft-lw1`)

- Writer + projection suites green ×2:
  `mix test test/semantic_projection_test.exs test/security/security_hardening_test.exs test/strata_compat_test.exs`
  → `94 tests, 0 failures (1 excluded)` twice.
  (No `test/ledger_chain_test.exs` exists in the tree; ledger-chain coverage
  lives in `test/security/security_hardening_test.exs` and
  `test/strata_compat_test.exs` — both included.)
- Collision face ×6 rapid CONCURRENT runs
  (`mix test test/semantic_projection_test.exs:30`, 6 processes at once):
  **6/6 exit 0** (`1 test, 0 failures` each).
- Full-file concurrent runs: first 3-way wave returned 2/3 — the one failure
  was `Smalt.Semantic.StoreRead.Lens7FieldPolicyTest` ("truthy non-binary
  Evidence status"), a PRE-EXISTING cross-process race on the shared OCEL
  default-path tmp file between concurrent `mix test` invocations (three
  full-file runs write/read/restore the same `Smalt.Ocel.DeviationAdmission.default_path()`),
  NOT the tx_id face. Subsequent 3-way full-file wave: 3/3 exit 0,
  `20 tests, 0 failures` each. The LedgerEntry collision test passed in every
  run of every wave (10/10 total).

## Residual

The cross-process default_path contention in Lens7FieldPolicyTest is
pre-existing, out of this lane's file ownership, and only manifests when two
full `mix test` processes race the same tmp file — solo and in-process
concurrent runs are unaffected.
