# FIN-19 — WIRE_PARITY row 150 restated (Event Hubs SDK smoke)

- Date: 2026-10-15
- Lane: fin-19 (F-3 fix), repo `/Users/sac/smalt`, no commits
- Subject: `docs/WIRE_PARITY.md` row 150 ("Event Hubs SDK smoke")

## Finding (F-3, confirmed)

Row 150 carried standing `ALIVE` while its own cited smoke exits 1.
`docs/jira/v26.10.14/sdk-results/ts-event-hubs.md` records the run at
`ts-event-hubs.md:82`: **smoke 0/4, exit 1** (fail-closed as designed), on the
mgmt-ops class registered as KD-18/KD-19/KD-20 in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:34-36`. The receipt itself flags the
stale pin at `ts-event-hubs.md:94` ("ALIVE" is stale on the SDK tier).

## Edit (single row)

`ALIVE` -> `PARTIAL (wire lane; SDK smoke FAILING on KD-18/19/20)`.

New row 150 (verbatim, on disk):

> | Event Hubs SDK smoke | `test/sdk-smoke/eventhubs.test.cjs` + `eh-run.mjs`: real `@azure/event-hubs` 6.0.4 over the 5673 lane, fail-closed, zero skips (exits 3 when `SMALT_SDK_ROOT` is missing rather than silently passing). Wire tier unaffected (see row above); the SDK smoke itself currently **exits 1** (0/4, fail-closed as designed) on the registered mgmt-ops divergence class — `sdk-results/ts-event-hubs.md`, KD-18/KD-19/KD-20 in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (`GAP(eventhubs-partition-metadata-absent)` overlaps KD-19) | PARTIAL (wire lane; SDK smoke FAILING on KD-18/19/20) | `test/sdk-smoke/eventhubs.test.cjs`, `docs/jira/v26.10.14/sdk-results/ts-event-hubs.md` |

GAP-token grammar kept (`GAP(eventhubs-partition-metadata-absent)` cross-ref,
same convention as WIRE_PARITY preamble line 6). Row 149 (wire lane) was
already honest — untouched.

## Verification

- `grep -n "eventhubs.test.cjs" docs/WIRE_PARITY.md` -> rows 149 and 150 only;
  row 149 already states "not a currently-green pin" and was left as-is.
- Repo-wide sweep for other green citations of that smoke: `docs/DEV_ENV.md:18-19`
  (mechanism/env-var wiring, no standing claim), `docs/CHEAT_SCAN.md:207`
  (cheat-class scan, no standing claim). No row anywhere cites the EH SDK
  smoke as green besides the corrected row 150.
- Re-read of row 150 on disk after edit confirms the new text byte-for-byte.

## Standing

Row 150: PARTIAL (wire lane; SDK smoke FAILING on KD-18/19/20). Falsifier for
the underlying divergences: KD-18/19/20 remediation receipts flipping the
smoke to 4/4 exit 0.
