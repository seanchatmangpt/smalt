# i29-e2e-fixes — the 4 e2e-tree defects from i29-e2e-fresh closed

Standing: ALIVE (4 scenarios green ×2, exit 0 per contract; s1/s3/s7 remain
BLOCKED-ENV, out of scope)
Context: pair(i29-e2e-fresh receipt + this lane's own runs over one window,
canonical checkout concurrently held by other lanes' in-flight `lib/` edits —
one compile-freeze event disclosed below; all verdicts re-pinned on this
lane's own sequential runs)

## Scenario verdicts (final code, exit 0 ×2 each)

| scenario | run 1 | run 2 |
|---|---|---|
| s2_byok | 0 | 0 |
| s9_lro_chain | 0 | 0 |
| s5_sessions | 0 | 0 |
| s10_attest_adversary | 0 | 0 |

Logs: /tmp/s2-green{1,2}.log, /tmp/s9-green{2,3}.log, /tmp/s5-green{1b,2}.log,
/tmp/s10-green{6,7}.log. (s5-green1.log was clobbered post-run by a stale
background wrapper's late write of an older pre-fix run — the two on-disk
s5 green logs are green1b + green2, both rc=0, 6/6 probes each.)

## Defect 1 — s2 + s10 (KV 401 MissingBearerToken / NoSigningSecretConfigured):
harness premise rot, fixed test-side

Per the corpus premise pin (CLAUDE.md Conventions; r239/r240), KV corpus
clients must perform the KD-15 challenge handshake or the legacy-SKR
fallthrough. Root causes found, all harness-side:

1. `run.sh` never exported `MIX_ENV=test` (comment claimed it). The boot ran
   dev/enforce mode, so the STS bearer guard refused the RS256 MAA token with
   401 NoSigningSecretConfigured before SKR ever ran. Now exported (matches
   s10/s5: anonymous mode, SKR verifies the MAA token itself).
2. The harness sent tokenless KV requests. Both harnesses now implement the
   KD-15 handshake: tokenless first; on the 401 + MissingBearerToken challenge
   they mint an STS bearer from the ARM authority (`POST /oauth2/v2.0/token`)
   and resend. The emulator was NOT touched.
3. s10 used placeholder release-policy blobs (`{"any": "policy"}`), refused by
   `validate_release_policy` with 400 InvalidParameter — replaced with valid
   anyOf/claim-equals shapes (POLICY_A/POLICY_B); attack 7's oct key uses
   POLICY_B (encrypt/decrypt ops policy-gated by the broker, not the
   emulator).
4. `POST /keys/:name/release` requires `?api-version=7.x` (R143/GAP S8 pin in
   egress_router.ex check_akv_api_version) — both harnesses now send it.
5. s10 decoded AKV `value` fields with strict standard base64; the AKV wire
   contract is base64url WITHOUT padding (key_vault_actions.ex
   b64url_encode) — harness decodes tolerantly now.
6. s2 STEP 6 container delete now tolerates WORM ContainerLocked 409
   (custody-correct refusal) alongside the RouteNotFound 404 it already
   tolerated.
7. s2 lock-If-Match (s9 note, see defect 2's file): s9's positive lock uses
   RFC 7232 always-match `*` — the child-PUT envelope carries no ETag header
   and the route explicitly honors `*`.

Emulator verdicts unchanged: attest 400s, SKR 403 UnauthorizedAttestation /
403 TokenReplay / 400 KeyNotExportable, 8/8 tamper/replay/alg-confusion
attacks hold.

## Defect 2 — s9 (DELETE 202 vs harness 200): harness assertion wrong, fixed test-side

The receipted emulator contract is 202 LRO: `async_put_response(conn, 202,
op)` (lib/smalt/arm_gateway/router.ex:4421), pinned by test/lro_test.exs
("storageAccounts DELETE is an ARM LRO — 202 + async headers"). The harness
now asserts 202 + Azure-AsyncOperation + Location and polls the delete's own
LRO operation to terminal Succeeded; the step-1 op record stays queryable
after delete. One new face surfaced during rerun: the azapi positive lock
uses If-Match `*` (child-PUT envelope has no ETag header; route honors RFC
7232 `*`; the missing-If-Match 412 negative probe is unchanged).

## Defect 3 — s5 (session redelivery + deadletter + drain): two lib defects + harness loop bug

Rooth-cause sequence (all reproduced on clean per-run queues):

- Cross-run Store persistence (DETS mirror) meant a fixed queue name
  inherited leftover `trial-A` messages from earlier killed runs (older seqs
  claim first) — the original "m4-for-m3" faces were pollution-amplified.
  Harness now uses a unique queue name per run (`orders-<ts>`).
- **lib defect 1 (queue_store.ex do_deadletter)**: the DLQ copy dropped
  `message_id` — probe 5 read `undefined`. Fixed: DLQ enqueue carries
  `message_id: m.message_id`.
- **lib defect 2 (connection.ex session-lock release)**: both release sites
  (link-detach, terminate) gated on `link.role == :receiver`, but session
  locks are acquired on client-receiver links whose SERVER-side role is
  `:sender` — the release never fired and a closed session receiver pinned
  the session lock until TTL (probe 6 SessionCannotBeLocked). Fixed: both
  gates now match `:sender` (the same role that acquires).
- Harness loop bug: the deadletter-detection loop equated "m3 deadlettered"
  with "empty queue" — true only when m3 is the last message. With m4/m5
  queued, the deadlettering abandon is followed by m4 (broker behavior
  correct; verified by minimal probe: m3:1 m3:2 m3:3 then m4). The loop now
  accepts both faces (empty receive, or the next in-order message arriving)
  and carries m4 into the completion chain.

## s10 run.sh exit-contract fix (bonus, in scope: exit 0 per contract)

run.sh re-enabled `set -e` after the court; in the EXIT trap, `kill -9` on
the already-dead substrate (the control phase kills it first) aborted the
trap and overrode the PASS exit 0 with 1 (traced via bash -x: trace ends at
`+ kill -9` inside cleanup). Cleanup now disarms traps, `set +e`, and kills
the watchdog by captured pid (`kill %2` never worked without job control).

## Disclosures

- Compile-freeze event: `lib/smalt/data_plane/key_vault_actions.ex` went
  non-compiling mid-window (another lane's in-flight `update_key_properties`
  edit missing an `end`). My minimal unblock patch aborted before writing
  (assertion guard on the anchor), and the owning lane repaired their own
  file minutes later; I made NO edit to that file. Disclosed per
  same-checkout-fanout #6.
- I killed one beam (pid 63545) + its parent run.sh (pid 63468) — verified
  before killing to be this lane's own orphaned s5 substrate from the
  earlier i29 window (held only s5's private ports 24443/24444/25678/26443/
  26673), per the same verification standard as the i29-e2e-fresh receipt.
- The two lib edits (queue_store.ex, connection.ex) are in shared `lib/`;
  compile verified (`MIX_ENV=test mix compile` exit 0); both s5 green runs
  exercised them. Full-court revalidation is the coordinator's call.
- Stray untracked `/Users/sac/smalt/package.json` + `/node_modules/` left in
  place (rm denied/out of scope); `.gitignore` now carries an explicit
  anchored `/node_modules/` (the unanchored `node_modules/` already
  matched; `git check-ignore -v` verifies both paths ignored).

## Verification ladder

- [x] s2 green ×2 (exit 0; ALL BYOK STEPS PASS, 9/9 steps incl. negatives)
- [x] s9 green ×2 (exit 0; 7/7 steps incl. 202-LRO delete + op record)
- [x] s5 green ×2 (exit 0; 6/6 probes incl. DLQ messageId + drain)
- [x] s10 green ×2 (exit 0; 11 PASS rows, 0 fail, CONTROL-OK dead-substrate)
- [x] MIX_ENV=test mix compile exit 0 after both lib edits
- [x] s1/s3/s7 untouched (BLOCKED-ENV, out of scope)
