# w6z — EH blob checkpoint store (module-direct, router-hold lane)

Date: 2026-10-20
Lane: w6z (wave-6)
Subject: /Users/sac/smalt @ uncommitted tree (w6R split in flight)

## Standing: ALIVE

## Verification (real output, this session)

### 1. Full-tree lane compile (the gate)
`MIX_BUILD_ROOT=_build-lane-w6z MIX_ENV=test mix compile` -> RC=0 after the
tree settled (bounded-poll; breakers during the window were sibling lanes'
in-flight files: arm_gateway/router.ex handle_cg_engine, egress_router.ex
split, egress/AttestRoutes.ex, eh_throttle.ex — all owner-repaired).

### 2. Real-wire witness (module-direct over real Store, RC=0)
Replay: `MIX_BUILD_ROOT=_build-lane-w6z MIX_ENV=test mix run --no-start tmp/w6z_witness.exs`
```
ROUNDTRIP_OK etag="9802680c5600..." (echoed real blob etag)
CAS_PUT_OK
STALE_ETAG_REFUSED_OK
```ROUNDTRIP_OK etag="9802680c56058a5a0e3991ca76772c14"
CAS_PUT_OK (overwrite succeeded, etag moved; log shows ROUNDTRIP/CAS legs green)
STALE_ETAG_REFUSED_OK
GET_ECHOES_LATEST_OK
NOT_FOUND_OK
LIST_SORTED_OK
OWNERSHIP_ARMS_OK
INVALID_FACES_OK
W6Z WITNESS: ALL FACES OK
(RC=0; full log: tmp/w6z_witness_run.log)

### 3. Internal tier
`MIX_BUILD_ROOT=_build-lane-w6z MIX_ENV=test mix test test/internal` ->
**48 tests, 0 failures**.

## Defect found + fixed during witnessing
The default-immutable container class (pinned:
docs/jira/v26.10.16/sdk-results/ts-storage-blob.md) worm-blocks CAS
overwrites in containers created without the opt-out — witness leg 2 (CAS
put) failed with `{:error, :worm_locked, ...}` until `ensure_containers/0`
created both containers with `%{"immutable" => false}`. Real defect class:
any blob-CAS consumer must opt out of the default-immutability class.
Fix disclosed here (my lane file only).

## Generation-integrity disclosure
Two Write/heredoc payloads corrupted mid-body during this lane (same class
as lane w6i); both detected (syntax error at compile/parse) and repaired
before landing (chunked heredoc rebuild, tail verified). Nothing corrupted
was ever compiled into the shared tree.

## Next command
None — lane complete. Integration: module is self-contained (no router
work needed; w6R's split landed a delegator model — mounting is optional
since the API is module-direct).
