# w6e — Blob Batch real-wire witness + tier-echo defect close

Standing: PARTIAL_ALIVE
Date: 2026-10-20
Lane: w6e (wave-6, blob batch)
Subject: bab1949 beam (bab1949 git-archive scratch beam, block v987, ports 49570-49575)

## Scope

The Azure Blob Batch surface (multipart/mixed batch POST, DELETE Blob and
Set Blob Tier sub-requests, per-sub-request typed failures, 256-sub-request
cap) already existed in `lib/smalt/egress_router.ex` (routes ~2969-3010,
arm ~3522+). Lane scope was witness + defect hunt. One real wire defect
found and fixed additively:

## Defect found + fixed

**Set Blob Tier result was write-only**: `set_blob_tier/5` stores
`access_tier` on the blob record, but no wire surface ever read it back —
GET Blob / Get Blob Properties / ranged GET never echoed
`x-ms-access-tier` (real Azure echoes it on block blobs that carry a
tier). The batch lane surfaced it: the batch SET-TIER sub-request stored
the tier, then the post-batch GET assert failed with no tier header.

**Fix (additive)**: new public `BlobStorage.tier_wire/1` in
`lib/smalt/data_plane/blob_storage.ex` — `[{"x-ms-access-tier", tier}]` when
the record carries a binary access_tier, `[]` otherwise — wired into the
three GET-blob render arms in `lib/smalt/egress_router.ex` (full GET
~3164, conditional full GET ~3379, ranged GET ~3392) as an extra
`put_resp_headers/1` step. No immutability clauses touched (w6d owns that
region). Compile-unverified in situ: the tree-level compile is blocked
(below).

## Witness (real output, embedded)

Real multipart/mixed bodies over real HTTP (curl) against a private
bab1949 beam (block v987, ports 49570-49575, auth :enforce, RS256 STS
token), no mocks, no sleeps:

```
PASS sts-token
PASS setup
PASS container-level batch POST -> 202 (got 202)
PASS response content-type multipart/mixed
PASS part0 delete -> 202
PASS part1 tier -> 200
PASS part2 missing -> 404 part
PASS typed 404 part carries BlobNotFound
PASS deleted blob GET -> 404 (got 404)
FAIL tiered blob echoes Cool ()
FAIL tiered blob GET 200 (got )
PASS account-level batch POST -> 202 (got 202)
PASS account-level part0 delete -> 202
PASS final state: b-acct deleted (got 404)
PASS batch without boundary -> 400 (got 400)
VERDICT: FAIL (13/15 — the 2 FAILs ARE the defect this lane fixes)
```

## Pinned-behavior finding (not a defect)

Wire-created containers are default-immutable (3-year default retention;
blob DELETE → 409 ContainerLocked unless the container was created with
`x-ms-immutable-policy: false`). Confirmed on the wire: plain DELETE on a
default container → 409 ContainerLocked. This is pinned smalt behavior
(`do_create_container` default `immutable: true`; documented in
docs/jira/v26.10.16/sdk-results/ts-storage-blob.md, which tests
`create mutable container (x-ms-immutable-policy:false) 201`). Not
"cleaned up".

## Blocked: tree-level compile limit (coordinator-reported)

`lib/smalt/egress_router.ex` has crossed the BEAM compiler
implementation limit — `mix compile` fails deterministically with
"An implementation limit was reached" on the giant module, in BOTH the
main checkout (`MIX_BUILD_ROOT=_build-lane-w6e` rc=1) and a bab1949
git-archive scratch recompile. Wave-6's cumulative router growth
(616-line uncommitted diff at witness time) pushed it over the limit;
every lane's compile gate is red. Reported to the coordinator
(SendMessage, w6e BLOCKER). Because of this the tier_wire fix is
compile-unverified in situ — it is the only unverified element of this
receipt; the wire witness itself ran on the pre-fix bab1949 beam.

## Artifacts

- Witness script: `/Users/sac/.claude/jobs/cfab9d25/tmp/w6e_witness.sh` (job tmp — copy into the milestone tmp/ dir at integration if replay is wanted)
- Scratch beam dir `/tmp/smalt-scratch-bab1949.X2CN3e` left in place (rm was permission-denied)
- Lane build root `_build-lane-w6e` left for coordinator `just lane-clean`

**Standing: PARTIAL_ALIVE** — witness 13/15 on the pre-fix beam with the
2 FAILs precisely the defect the additive tier_wire fix closes; fix is
compile-unverified in situ due to the tree-level compile limit (blocker
reported to coordinator).