# T-R1 — Restore the EgressRouter undocked surface (multiplier repair)

- window: v26.10.29 · status: QUEUED (first repair action) · source:
  receipts/r4-baseline-triage.md defect class (d), ~100+ failures

## Root cause shape

The v26.10.29 "undock" refactor of `Smalt.EgressRouter` deleted
`safe_dispatch/2`, `Peers.build_event/2`, the `Plug.ErrorHandler` fence,
and whole route families (`/saas/subscriptions/resolve`,
`/sync/journal/batch`, KV crypto face, `/sbns`) — the router source itself
notes the undock's rule-CORS variants were "NOT restored here — next-wave
scope".

## Fix (one action, biggest yield)

`git log`/`git show` the undock commit; re-land the deleted dispatch paths
verbatim from history. Verify with the named failing tests
(bk101_g3_seam_probe, armstrong_idiom_court, marketplace_saas,
ath1_batch, kv_crypto_face, servicebus_rest_dataplane) BEFORE anything
else — it is the multiplier. The deterministic same-file:line failure
signature (r4) means every rerun after this lands gives clean signal.

## Follows

- Tenant fence (check undock casualty first — may ride the same restore).
- APIM plug ordering (independent, 12 failures).
- Long tail: per-file fan-out only after the multipliers land.
