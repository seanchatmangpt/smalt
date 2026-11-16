# SDK Coverage Gate Triage (scripts/sdk_coverage.py, GATE: FAIL 40)

Standing: UNVERIFIED

Derived by reading `scripts/sdk_coverage.py` and its inputs. The script was not run by this
lane; per-class counts are derived, not observed. The gating window is the newest
`docs/jira/v*/KNOWN_DIVERGENCES.md`, which is `v26.11.6`.

## Coordinator listing command

```
cd /Users/sac/smalt && python3 scripts/sdk_coverage.py | grep '^FINDING:' | sort | uniq -c
```

The window render also lands in `docs/jira/v26.11.6/SDK_MATRIX.md` under "## Findings".

## Finding classes (derived)

| class | source in script | derived count | owner of fix |
|---|---|---|---|
| A. `<surface>/<lang>: MISSING probe cell` | `compile_window` SURFACES loop | 23 | script or probe layout |
| B. `servicebus/census: CRC FAIL` | `census_crc` | 1 | coordinator (receipt) |
| C. kd-cell findings (`kd-cell: ... no cited receipt` or `unhandled KD statuses`) | `KD_CELLS` loop | 7 cells, finding count UNVERIFIED | script (column skew) |
| D. cap-cell findings | `compile_cap_cells` | remainder to 40, UNVERIFIED | mixed, see below |

A (23) + B (1) = 24 derived; C + D must total 16 for the gate to read 40. The split is
UNVERIFIED until the listing command above is run.

### A. MISSING probe cell (23)

`find_probe` globs `verification/ts/*.probe.mjs` and `verification/py/py_*.py`. On disk the
TS `*.probe.mjs` files are `newcaps`, `appconfig`, `diagnostics`, `wf9-kafka`; no
`verification/py/py_*.py` exists (landed suites are `test_wf*.py`). Substring patterns in
SURFACES match only `appconfig` (TS). So:

- TS MISSING (11): arm, blob, cosmos, keyvault, skr, eventgrid, eventhubs, sentinel,
  resource-graph, purview-atlas, ledger.
- PY MISSING (12): the same 11 plus appconfig.
- gcp and aws cells are `MISSING-REGISTERED` (KD-GCP-05, KD-AWS-03), not findings.

`verification/workflows.json` notes[1] already records this as "finder-script pattern skew,
not absence of probes". Register rows would be wrong here: a KD row cannot cover a
`probe is None` cell (only `missing_kd` in the SURFACES dict can). Not a divergence; not
minted. Close by either (a) script patterns learning `verification/py/test_wf*.py` and
`verification/ts/wf*/index.ts`, or (b) adding `missing_kd=` entries to SURFACES. Both edit
the script, which this lane does not own. Loudly MISSING.

### B. Service Bus census CRC (1)

`window_paths("v26.11.6")["census_rcpt"]` is `docs/jira/v26.11.6/receipts/08-servicebus-census.md`.
That file does not exist (copies exist under `v26.10.14`, `v26.10.16`, `v26.10.19`
receipts). `claimed` is None so `ok` is False. Close: land a receipt at that path that
contains the line `registers N probes` with N equal to the `probe("...")` count in
`verification/ts/census.test.cjs`. Cannot be grounded by a KD row. Loudly MISSING.

Count command: `grep -c 'probe("' verification/ts/census.test.cjs` (raw; the script counts
distinct names via regex `probe\("([\w-]+)"`).

### C. kd-cell findings (7 cells, 9 KD ids)

KD_CELLS ids: KD-45, KD-53, KD-76, KD-70, KD-71, KD-77, KD-91, KD-92, KD-93.

Derived cause (column skew in `load_kd`): the v26.10.14 and v26.11.6 registers have 7
columns (`KD | Dialect | Surface | Divergence | Evidence receipt | Close condition | Status`).
`load_kd` indexes `evidence = parts[3]` and `status_full = parts[5]`, which is the 6-column
layout. On 7-column rows it reads Divergence as evidence and Close condition as status, so:

- `status` becomes the first alphabetic run of the Close condition text (for example
  "witness", "sign"), never `OPEN` or `CLOSED-SIMULATED`;
- `kd_receipt_paths` scans only Divergence and Close cells, missing the Evidence and Status
  cells where the witness paths live.

Result: each cell ends `MISSING` through "no cited receipt exists on disk" or "unhandled KD
statuses". The v26.10.19 register is 6-column (KD-117 row is script-compatible), which is
why cap cells citing 6-column rows behave. Evidence read: header at
`docs/jira/v26.11.6/KNOWN_DIVERGENCES.md:12`; rows KD-91/92/93 at
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:276-278` carry Dialect `AZURE-#1` and status
`CLOSED-SIMULATED` / `CLOSED-WITH-EVIDENCE` in column 7.

Per-KD witness receipt (from the Status cell, all existing on the register as written):

| KD | status cell | witness cited |
|---|---|---|
| KD-91 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/kd91-head-checknameexists-witness.md` |
| KD-92 | CLOSED-SIMULATED | `docs/jira/v26.10.21/receipts/bk25-kd92-93-cosmos.md` |
| KD-93 | CLOSED-WITH-EVIDENCE | `bk19-kv-cosmos-queue-conformance.md`, `bk43-kd93-close.md` (v26.10.21) |
| KD-70 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/r200a-kd70-delivery-annotations.md` |
| KD-71 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md` |
| KD-77 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/lane9-reference-rewrite.md` |
| KD-76 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md` |
| KD-53 | CLOSED-SIMULATED | `docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md` |
| KD-45 | CLOSED-SIMULATED | `docs/jira/v26.10.16/receipts/r178e-census-replay-repair.md` |

Disk existence of each path is UNVERIFIED except those seen in the v26.10.16 receipts glob
(kd91, r200a, r200b, lane9, r178e). Register-side fix options: (a) script reads the Dialect
column (preferred; script not owned here), or (b) coordinator-owned register edit that
repeats the receipt path inside the Divergence cell of each row. Neither is a new KD row.
Loudly MISSING.

### D. cap-cell findings

Rules (`compile_cap_cells`): ground keywords must appear case-sensitively in `lib/smalt/<file>`;
a receipt must exist; a receipt containing the token `FAIL` (or no Standing) needs a KD row
whose Divergence or Close-condition cell (parts[3], parts[5]; 7-column layout) or
`status_full` contains the receipt path or basename.

| cell | derived state | disposition |
|---|---|---|
| lro-namespace-put | MISSING: ground keyword `lro` (case-sensitive) absent from `lib/smalt/arm_gateway/router.ex`; the file has `LRO` (line 14) and `CanonicalRouter` only | no KD row can fix it; script keyword should be `LRO`, or router needs a lowercase `lro` token. Loudly MISSING |
| appconfig-snapshots | UNREGISTERED-GAP: receipt `v261019-capability-wave3.md` contains `FAIL` tokens; no register row cites it in a cell the script reads | KD-213 minted (see below) |
| kv-deletedkeys-lifecycle | receipt `kd117-kv-deletedkeys-plane-tbd.md` has `FAIL` lines (20, 22) | UNVERIFIED whether covered: v26.10.19 register KD-117 (6-column) cites that basename in evidence, so likely covered; confirm via listing |
| sb-schedule | receipt `kd118-...-tbd.md` has `FAIL scheduleMessage` (lines 34, 51) | same as above via v26.10.19 KD-118 evidence cell |
| cosmos-throughput | receipt path `docs/jira/v26.10.16/receipts/r118-cosmos-put-replace.md` exists | not examined for `FAIL`; UNVERIFIED |
| others (appconfig-kv, monitor-metrics, eh-consumergroups, eventgrid-topics-arm, blob-snapshot-*, sb-eh-2024-children, policy-exemption-armcase, tags-at-scope) | receipts exist; `FAIL` token presence not read | UNVERIFIED; the listing command decides |

#### KD-213 and its honesty bound

KD-213 (appended to `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`) registers the only
open, receipt-grounded divergence in `v261019-capability-wave3.md` that I could not show
fixed at HEAD: section B2, blob container delete on a policy-less container answering
`409 ContainerLocked`. It cites the wave3 receipt path in its Divergence cell, which is
what clears the `appconfig-snapshots` UNREGISTERED-GAP mechanically.

Limits stated plainly:
- The cover is receipt-granular, not snapshot-specific. No evidence in repo shows an
  appconfig-snapshots divergence. The honest permanent fix is a dedicated capability
  receipt for `appconfig-snapshots` (the surface at
  `lib/smalt/data_plane/appconfig_snapshots.ex`, error code `SnapshotExists` line 91
  per wave3 line 473) with a Standing line and no `FAIL` token.
- KD-213 is UNVERIFIED at current HEAD; `worm.ex:445` carries a comment about
  "ContainerLocked with no hold set, where real Azure allows both", suggesting a partial
  fix already landed. A re-probe may close it.

## Wave3 FAIL tokens deliberately NOT minted as rows

Re-read against HEAD, these are stale or probe-defects, so minting OPEN rows would be false:

| wave3 FAIL | HEAD evidence |
|---|---|
| blob default `list_blobs()` 500 (line 304, `blob_metadata_xml(_, nil)` missing) | `lib/smalt/data_plane/blob/core.ex:1552` now has `defp blob_metadata_xml(_b, nil), do: ""` |
| `workspaces/tables` ARM stub `200 {"value": []}` (lines 516-527) | `lib/smalt/arm_gateway/plug/resource_providers.ex:5280` and `:5324` now route `.../workspaces/:ws_name/tables` |
| pkranges `If-None-Match` FAIL rows (lines 596-597) | receipt line 602 itself says probe bug, not engine defect |
| run-all 5 FAIL (blob auth channel, SB receiver delivery, DLQ, kv-recover) | receipt line 390 attributes the SB ones to a shared-substrate artifact; not re-witnessed; UNVERIFIED |

Not checked: KQL bare `| summarize count()` not table-scoped (wave3 lines 541-544). `kql.ex`
has 16 `summarize` occurrences; whether the table-scoping bug persists is UNVERIFIED. If the
coordinator wants a row, first run the probe in wave3 lines 535-538.

## Summary of dispositions

| class | findings | minted | residual |
|---|---|---|---|
| A MISSING probe cell | 23 | none (not a divergence) | script patterns or `missing_kd=` |
| B census CRC | 1 | none | land `docs/jira/v26.11.6/receipts/08-servicebus-census.md` |
| C kd-cells | UNVERIFIED | none | script reads Dialect column |
| D cap cells | UNVERIFIED | KD-213 | `lro` keyword case; dedicated snapshots receipt |

## See Also

- `scripts/sdk_coverage.py`
- `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`
- `verification/workflows.json` (notes on finder-pattern skew)
