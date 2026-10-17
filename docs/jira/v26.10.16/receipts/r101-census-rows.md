# R101: SB census rows

Standing: PARTIAL_ALIVE
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `docs/CENSUS.md` (+3 probe rows), `test/sdk-smoke/census.test.cjs`

## Claim

Three new census probe rows (lock-duration, deferred-receive, dlq-properties) documented
against real probes in census.test.cjs.

## Re-run evidence

```
$ grep -c "lockDurationCase\|deferredReceiveCase\|dlqPropertiesCase" test/sdk-smoke/census.test.cjs
6
$ grep -n "async function lockDurationCase\|async function deferredReceiveCase\|async function dlqPropertiesCase" test/sdk-smoke/census.test.cjs
226:async function lockDurationCase() {
247:async function deferredReceiveCase() {
272:async function dlqPropertiesCase() {
```

## Verdict

PARTIAL_ALIVE. All three named probes exist in the census source (doc row ↔ probe referent
verified). Full census replay (`scripts/sb_census_replay.sh`) NOT run in this lane — it
boots its own MIX_ENV=test substrate and would collide with the live substrate holding the
canonical ports. Execution witness deferred to the next court-x2/census window.
