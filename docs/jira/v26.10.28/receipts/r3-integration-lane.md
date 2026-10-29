# r3 — integration lane: the closed 80/20 tickets validated through both integration tiers

- window: v26.10.28 · date: 2026-10-28 · tickets validated: T-03, T-17, T-18 (+ the 8a6ce57 blob/queue batch)
- tiers: beam ExUnit (`test/integration/`) + official python SDKs (`verification/py/`)

## what landed

1. **Beam tier**: `test/integration/parity_lane_wire_test.exs` — 8 in-process
   EgressRouter dispatch tests (real Store, no mocks) covering T-17
   (snapshot-delete 409/include-202/404 matrix), T-18 (content-type on HEAD
   + GET), the blob comp surfaces (lease, appendBlock, page, block-id gate,
   commit-blocklist), and the queue SDK wire shapes (bare routing, metadata
   204s + read-back, message lifecycle, update 204, UA-disambiguated
   comp=list). **Result: 8/8 passed.**
2. **Python tier**: `verification/py/test_wf8_parity_lane.py` — official
   azure-storage-blob 12.31 / azure-storage-queue 12.18 SDKs (a second
   client family beyond the JS parity harness) against a running substrate
   (`SMALT_PY_EGRESS`, no boot fixtures). **Result: 4/4 passed.**

## substrate fixes the tiers forced (both real Azure-parity gaps)

1. **Queue arms didn't halt** (`run_queue_arm`): after sending, the plug
   pipeline continued into :match and the blob splat re-dispatched the same
   request — live Bandit masked it (response already on the socket), the
   in-process tier crashed with AlreadySentError. Now halts.
2. **Blob error bodies are the Azure XML `<Error><Code/><Message/>`
   envelope** (content-type application/xml, x-ms-error-code header kept):
   the python storage pipeline parses Message from XML and crashes on JSON
   (`error_message += None`). `Message` is never empty (defaults to the
   code) — python's formatter also crashes on empty. Scoped to the blob
   error renderer only; `send_json` untouched (ARM/cosmos/KV envelopes keep
   pinned JSON). The one existing pin of the old JSON shape
   (`test/integration/arm_dcr_test.exs` DCR ingest refusal) updated with a
   pointer to this receipt.

## regression sweep

- integration tier: 29/34 — the 5 failures are the pre-existing baseline
  set (deletedkeys purge, sb-arm rules ×3, consumer-group bridge)
- vm_zero_growth "lazy singleton churn": failed twice under machine load,
  **passes solo and on a quiet machine with the same code** (10s poll
  deadline class, not caused by this lane); HEAD-equivalent behavior
  confirmed via stash-run-unstash
- JS parity blob+queue after the XML envelope: **FULL MATCH 50/50**
  (`parity/reports/mvt1g2ev-e6acb8`)

## python env note

venv OUTSIDE the repo at `%USERPROFILE%\dev\tools\pyaz` (repo law: no
in-repo dependency installs): `pip install azure-storage-blob
azure-storage-queue pytest`; run with
`SMALT_PY_EGRESS=http://127.0.0.1:8443 python -m pytest
verification\py\test_wf8_parity_lane.py`.
