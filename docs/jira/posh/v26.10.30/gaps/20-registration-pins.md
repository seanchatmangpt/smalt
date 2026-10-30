# Gap 20: registration pins — three-way sync (pin / KD register / coverage inventory)

Lane 20, 2026-10-30. Read-mostly. Status: **PARTIAL — drift risk mapped; gate exists and is
green; the pin is not yet mechanically cross-checked against the coverage gate.**

## Sources read on disk

- Pin: `/Users/sac/smalt/adapters/terraform-provider-smalt/internal/provider/server_test.go:87,127`
  (`expectedResources = 12`, `expectedDataSources = 7`); type-set assertions at :92-105 and
  :132-140.
- KD register: `/Users/sac/smalt/posh/KNOWN_DIVERGENCES.md` (§2/§3 prose lists, §4.1 PASS
  ledger, §5 KD table, 9 rows). Gate run 2026-10-30:
  `python3 posh/scripts/coverage.py` → `coverage: 8 registered / 12 pass / 0 missing /
  20 cells; KD rows: 9`, exit 0 (ALIVE witness).
- Inventory derivation: `/Users/sac/smalt/posh/scripts/coverage.py` (parses `var ops` in
  `posh/cmd/posh/main.go`, `resp.TypeName = ... + "_X"` in `resource_*.go` / `data_source*.go`).

## What breaks when a lane adds the 13th resource without bumping the pin

**Loud, twice, never silent.** `TestProviderResourcesAndDataSources` has two independent legs:

1. count leg — `Fatalf` at server_test.go:88-90 (`expected %d registered resources, got %d`).
2. membership leg — `Errorf` on any TypeName not in the 12-entry map (:110-111, "unexpected
   resource registered") and on any listed type never registered (:117-120).

A 13th resource without a pin bump fails both legs. A lane cannot land it silently through the
provider test suite (`posh-go.yml` runs `go test` on the adapter on every touched-path push).
The membership map also self-defends against a *blanket* pin bump: bumping to 13 without
registering the type still fails (missing-registration Errorf). This leg is the good case —
no close needed for the pin itself.

## The three places, and which are derivable

| Surface | Who updates on a type add | Derivable? |
|---|---|---|
| Coverage inventory cells | Nobody — `coverage.py` derives from `resp.TypeName` source pattern | **Mechanically derived** (no sync debt) |
| Pin consts in `server_test.go` | The lane adding the type (hand bump) | Not derivable — but drift is LOUD via the two test legs |
| KD register §2/§3 lists, §4.1 PASS ledger, §5 rows | Hand edit; coverage gate flags the missing cell loudly (MISSING → exit 1) | Coverage gate IS the mechanical cross-check registry↔KD |
| KD §2/§3 prose enumerations ("12 required sovereign resources and 7 data sources") | Hand edit; **not gated** — can silently rot | Partially derivable: counts grep-able from the pin file |
| `gaps/01-provider-azurerm-parity.md` G1/G3 rows | C1 (role_definition) closes G1/KD-01/KD-09 on landing; lane 1 owns the file | Not gated; D1's INDEX row quotes it |

## Sync graph (file → file)

    provider Resources()/DataSources() (server.go + resource_*.go, data_source*.go)
        ├─(derived)→ coverage.py inventory ──(gate)→ KD §5 rows + §4.1 PASS ledger
        ├─(asserted)→ server_test.go pin consts 12/7 + type maps   [loud on drift]
        └─(hand)→ KD §2/§3 prose counts/list ─→ (nothing)          [SILENT drift edge]
                                └─(hand)→ gaps/01 G-table

The only **silent** edge is KD §2/§3 prose: a 13th resource lands, pin bumped, KD row/PASS cell
added (gate green), and the prose still says "12 required sovereign resources" — nobody fails.

## Close condition (single recipe)

Extend `posh/scripts/coverage.py` with `--check-pin` (one mode, one gate, no new tool):

1. Regex-extract `expectedResources = (\d+)` / `expectedDataSources = (\d+)` from
   `server_test.go`.
2. Assert `expectedResources == len(resource cells)` and `expectedDataSources == len(datasource
   cells)` — pin ↔ derived inventory equality, exit 1 on mismatch.
3. Also assert the prose counts in KD §2 ("the 12 required sovereign resources and 7 data
   sources") match the derived counts — closes the silent prose edge.
4. Wire into `justfile.d/57-tf-provider.just` (e.g. `just tf-provider coverage-gate`) and the
   `posh-go.yml` workflow so it runs on the same push paths as `go test`.

Non-vacuity: extend the existing `--self-test` contract — inject a +1 delta into the pin
extraction and require exit 1 (VACUOUS-GATE flip), same pattern as the bogus-op injection.

Then every type add requires exactly two hand edits (pin bump + KD/PASS row, both enforced) and
zero silent ones; §2/§3 prose and gaps/01 become receipt-time doc updates owned by the landing
lane, verified by the gate instead of by memory.

## Lane ownership

- `server_test.go` pin: whoever adds the type (C1 for role_definition-adjacent surface changes;
  C2/C4 lanes touch behavior and registry rows respectively).
- `KNOWN_DIVERGENCES.md` rows: the lane creating/closing the divergence.
- `gaps/01` + INDEX row: lane 1 wrote both; the closing lane (C1 for G1/KD-01/KD-09) appends a
  close note; D1 owns the INDEX quote refresh.
