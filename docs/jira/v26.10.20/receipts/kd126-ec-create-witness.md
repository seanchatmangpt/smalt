# KD-126 EC create seam — W10-A receipt

**Standing:** PARTIAL_ALIVE (fix landed + court green x2; live wire witness + kd_flip BLOCKED by host ENOSPC)
Date: 2026-10-20 (~19:40 PDT)
Lane: W10-A — repo /Users/sac/smalt (MIX_BUILD_ROOT=_build-w10a)

## Landed

- `lib/smalt/egress/KvRoutes.ex` — EC/EC-HSM arm in `jwk_for_kty/4`
  (`# KD-COVERS: KD-126`): crv/x/y public JWK (real JsonWebKey EC form,
  base64url fixed-width unsigned) + private DER cached under
  `"key_material"`; unknown crv -> typed 400 InvalidParameter via the
  policy_error channel. The create route extracts `crv` (default P-256)
  and calls the 4-arity seam; RSA/oct arms unchanged apart from `_crv`.
- `test/integration/kv_ec_create_test.exs` (new): Chicago court — real
  curl over the test boot's TLS twin listener, KD-15 disjunctive auth
  (tokenless probe -> 401 -> STS dance -> bearer), no mocks.
- KD-126 registered OPEN in BOTH registers: canonical
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (row appended after KD-124)
  + pointer `docs/jira/v26.10.20/KNOWN_DIVERGENCES.md`.

## Verification (real outputs)

```
MIX_BUILD_ROOT=_build-w10a mix test test/integration/kv_ec_create_test.exs
run 1: 4 tests, 0 failures
run 2: 4 tests, 0 failures   (green x2)
```

Covered: EC create 200 with crv/x/y JWK + sign/verify key_ops; ES256 sign
200 with raw JWS signature; verify true digest -> 200 value:true; tampered
digest -> 200 value:false (typed KeyVerifyResult negative); P-384 create +
ES384 sign round-trip (sha384 digest); unknown crv -> 400 InvalidParameter;
RSA + oct create regression legs.

Neighbor regression (same build root): deletedkeys_purge_route +
queue_message_ct -> `4 tests, 0 failures`.

Compile: KvRoutes clean; sole warning (`Smalt.DataPlane.Cosmos.effective_ttl/2
undefined or private` at deps/plug router invoke in Mcp.Router) is a
concurrent lane's in-flight cosmos.ex edit, not this diff.

## Wire witness — BLOCKED (honest disclosure)

Close condition (popcorn keyops walk flips to OK(ES256:verified) with no
leg edit) NOT yet witnessed on a live substrate:

- Shared substrate (pid 8253, 9443/9444/8443/5672/5673) left UP and
  untouched per "never restart" — it still runs pre-fix code, so
  `LiveKeyops.run/0` still answers SKIP until the coordinator recycles it
  onto a post-fix build. No curl probe against it can witness the EC face.
- Lane-local substrate boot on private ports 19443/18443/19444 (ports
  pre-flighted clear with lsof) crashed mid-boot: host filesystem hit 100%
  (ENOSPC; df showed 117 Mi free, 926Gi disk, 100% capacity). Process dead;
  shared substrate unaffected. Curl legs, the keyops walk and
  `python3 scripts/kd_flip.py --dry-run` were then unrunnable — the agent
  harness itself intermittently failed output capture with ENOSPC.

Expected post-recycle: with the EC arm compiled in, `ec_create/1` sees 200
`{"key":{"kty":"EC","crv":"P-256","x":...,"y":...}}` and `LiveKeyops.run/0`
returns `{:ok, "keyops=OK(ES256:verified)"}` unchanged (the OK branch was
wired by W4-4; no leg edit). kd_flip mtime gate applies (receipt must
postdate shim); run the dry-run after substrate recycle -> expect
KD-126 FLIP-PENDING-WITNESS, then flip.

## Incident disclosure (session-introduced, resolved)

I overwrote the then-untracked `lib/smalt/egress/KvRoutes.ex` with a
partial Write (tool misuse: Write replaces the whole file); my in-context
reconstruction attempt degraded and was abandoned. The file was restored
externally to its original state (sha256 9e0667d6f4acd08f, 971 lines);
this lane's diff is the surgical EC patch applied on top of that restored
base via exact-substring replaces, compile-fenced. No other lane's files
touched.

## Session-introduced failures: none open. Pre-existing/concurrent

- Cosmos/MCP compile warning (another lane's in-flight edit).
- Host disk 100% full — machine-level, blocks witness legs until space is
  reclaimed (the `just lane-clean` orphan-root backlog is the
  coordinator's call; my rm of my own `_build-w10a` was permission-denied).

## kd_flip dry-run (verbatim, 2026-10-20 ~19:45 PDT)

```
$ python3 scripts/kd_flip.py
  KD-126: [OPEN] lib/smalt/egress/KvRoutes.ex
FLIP-PENDING-WITNESS: 6
  KD-126: no post-shim receipt newer than shim mtime (2026-10-20T19:30:06)
```

FLIP-PENDING-WITNESS is the expected outcome per the W10-A task: the flip
is mtime-gated and executes at integration after the shared substrate
recycles onto a post-fix build and the walk witness lands.
