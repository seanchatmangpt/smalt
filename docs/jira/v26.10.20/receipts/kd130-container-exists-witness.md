# KD-130 close: container re-create 409 ContainerAlreadyExists

**Standing: PASS (fix landed; live re-probe on the post-fix boot: create 201, re-create 409 ContainerAlreadyExists, 2026-10-21)
tier 77/77 (×2); live-wire 409 on the real wire PENDING substrate restart (restart
forbidden this lane; the running beam is pre-fix, witnessed 200 as-found). Flip is
receipt-gated via `scripts/kd_flip.py` (canonical row KD-130, v26.10.14 register),
which requires a real-SDK createIfNotExists witness postdating the shim — that
witness needs the restarted beam and is explicitly not claimed here.

W21-A, 2026-10-20. Repo: /Users/sac/smalt. Lane build root `_build-w21a`.
Context: solo.

## Diff (lib/smalt/egress_router.ex, surgical)

- Create arm 409 clause: `container_reput_arm/3` call replaced with
  `container_exists_arm/3` (new, ~35 lines). New arm re-checks the WORM/lease
  gates first (`BlobStorage.policy_state/2`: legal hold or locked-while-live →
  409 ContainerLocked, preserving the blob-worm invariant posture and the WORM
  corpus leg), then answers the unconditional Azure envelope
  `409 ContainerAlreadyExists / "The specified container already exists."`
  Marker `# KD-COVERS: KD-130` on the new arm.
- `container_reput_arm/3` kept (no longer on the create path) — the
  v26.10.18 burn-corpus fence `corpus_test.exs` regex-maps
  `\bcontainer_reput_arm\(` against the router; deleting it would break that
  fence's mapping. No live callers.
- KD-122/123/66 clauses untouched.

## Court: test/integration/kd130_container_exists_test.exs (14 tests, 0 failures)

Real router, real BlobStorage ETS, no mocks:

- fresh create → 201 empty, ETag/last-modified/x-ms-request-id/x-ms-version headers
- re-create identical metadata → 409 ContainerAlreadyExists
- re-create different metadata → 409 ContainerAlreadyExists
- container still usable after the 409 (blob PUT 201 / GET 200 byte-equal)
- WORM precedence: re-create under legal hold → 409 ContainerLocked
- R98/KD-122 family: unknown container PUT comp → typed 400 (no silent create)
- KD-66: ranged GET content-md5 digest intact
- KD-123: queue message POST application/xml round-trips real bytes

Command + output:

```
$ MIX_BUILD_ROOT=_build-w21a mix test test/integration/kd130_container_exists_test.exs test/integration/blob_k1_rows_witness_test.exs
Finished in 0.1 seconds (0.00s async, 0.1s sync)
14 tests, 0 failures
```

## Regression

```
$ MIX_BUILD_ROOT=_build-w21a mix test test/integration   # run 2 and run 3
77 tests, 0 failures   (twice consecutively)
```

Run 1 of the same tier had one transient 401 in
`Smalt.Integration.BlobSharedKeyTest` (blob-PUT leg; mechanically unrelated to
the 409 arm — that leg never reaches it). It did not reproduce file-alone
(3/3) nor in two consecutive full-tier runs. Disclosed as an unconfirmed
transient; not classified pre-existing.

## Live wire (substrate UP, pid 78681, PRE-fix beam — restart forbidden)

STS bearer minted via `POST /dev/oauth2/v2.0/token`; ARM storage account
`kd130w61211` created 202; blob plane 8443:

```
PUT /kd130w61211/cont-live?restype=container   -> 201
PUT /kd130w61211/cont-live?restype=container   -> 200, empty body   (the divergence, as-found)
PUT /kd130w61211/cont-live/witness.txt         -> 201
GET /kd130w61211/cont-live/witness.txt         -> 200 "kd130 live"  (container usable)
```

The 200 documents the pre-fix beam; the post-fix wire answer (409 envelope) is
executed by the plug-conn court above and must be re-witnessed with curl + real
SDK createIfNotExists after the next substrate restart for the flip.

## Burn-corpus fence conflict (DISCLOSED, not edited — outside lane ownership)

`docs/jira/v26.10.18/burn/test/corpus/blob_container_reput.exs` pins the OLD
shape ("identical re-PUT 200" + ContainerLocked precedence). The KD-130 close
makes the identical-metadata leg answer 409. The corpus could not be executed
standalone to witness the conflict: all 23 corpus tests fail environmentally
(`SmaltTest.Lifecycle.ensure_store_up/0` undefined outside the burn harness
driver — pre-existing, both reput rows fail at setup before any assertion).
Coordinator must re-author that corpus row (identical re-PUT now expects 409
ContainerAlreadyExists; the ContainerLocked-precedence leg stays valid and is
covered identically by the new KD-130 court).

## Replay

1. `MIX_BUILD_ROOT=_build-w21a mix test test/integration/kd130_container_exists_test.exs test/integration/blob_k1_rows_witness_test.exs`
2. `MIX_BUILD_ROOT=_build-w21a mix test test/integration`
3. Post-restart wire witness: STS mint → ARM account → PUT container ×2 → expect 409 envelope; then real-SDK createIfNotExists witness → `kd_flip.py --apply`
