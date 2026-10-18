# v26.10.18 rewrite WORKQUEUE — every test file reviewed and refactored

Full inventory: 153 test files. 57 covered by the master-plan drafts
(docs/jira/v26.10.18/rewrite-drafts/) + the 20 execution batch lanes.
96 files partitioned into 18 residual lanes (W1–W18), groups in
/tmp/rewrite-workqueue.json. Dispatch: coordinator, as the 20 batch-lane
slots free (5-minute loop enforces).

## Lane contract (every W lane)

- Review each assigned file against NO-SLEEP-DOCTRINE
  (docs/NO_SLEEP_DOCTRINE.md once landed; the drafts until then): fixed
  `Process.sleep` → `SmaltTest.AssertEventually.eventually/2` poll on the
  observable (or `eventually_stays/3` for absence checks); timing bounds →
  relative-ratio or authored-clock (never absolute-ms loosening without
  regression math); shared-singleton dependencies → start_supervised! per the
  foundations; env mutations → SmaltTest.Env save/restore.
- Preserve every receipted assertion/pinion verbatim — a review that changes
  what is proven is a FAIL.
- Run each touched file green ×2 (MIX_BUILD_ROOT=_build-ft-w<N>).
- Receipt: docs/jira/v26.10.18/receipts/w<N>-review.md with per-file verdicts:
  REWRITTEN / ALREADY-COMPLIANT (cited why) / PRESERVED-AS-CONTRACT (sleeps
  that model real time, e.g. rate-limit window alignment).
- Files that fail compile post-edit: fix forward within the SLA or revert.
- No git. Freeze is LIFTED for this wave (post-attempt-5 protocol superseded
  by the execution mandate): the court gate re-runs only after W1–W18 land.

## Residual groups (from /tmp/rewrite-workqueue.json)

W1: admission_projection, arm_secret_rotate, +4 more (see JSON)
W2: affidavit_ingestion_functor, arm/fr5_tf_divergence_closures, +4
W3: affidavit_ocel_emit, arm/kd87_sts_leading_empty_segment, +4
W4: affidavit_seal, azapi_actions, +4
W5: affidavit_wasm_engine, canonical_projection, +4
W6–W18: (see JSON — 6 files each)

## Non-dispatchable files (contract preserves)

- test/sdk-smoke/run.mjs, census-run.mjs, eh-run.mjs — JS batch lane's lease
- test/sdk-python/*, smalt-cli/tests/* — gates-python/JS lanes
- files in batches B0–B8 scopes — their lanes
- test_helper.exs + test/support/* — B0's lease
