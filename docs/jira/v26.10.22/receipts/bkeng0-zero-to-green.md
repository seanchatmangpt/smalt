# BK-ENG0 — Engineer zero-to-green: bootstrap → up → real-SDK → sdk-all → doctor → down/up

**Standing: PARTIAL_ALIVE**
Context: full
Date: 2026-10-22 · repo /Users/sac/smalt (canonical checkout, main)
Mission: an engineer cloning the repo runs the Justfile alone and reaches a running
substrate with real Azure SDKs working against it.

## What an engineer's first hour now does

| Step | Command | Standing |
|---|---|---|
| 1 | `just bootstrap` | stages 1–7 GREEN (stage 8 typed below) |
| 2 | `just up` (fixed; detached: `nohup just up &`) | GREEN — 5 ports, CA-signed TLS leaf |
| 3 | `eval "$(just relay-env)"` + SDK touch (wf2 leg) | GREEN — real @azure SDKs, real 2xx |
| 4 | `just sdk-ts` / `sdk-py` / `sdk-census` (repointed) | ts exit 1 (KD-115), py exit 0, census below |
| 5 | `just doctor` re-run | GREEN (idempotent) |
| 6 | `just down` → re-`up` → verify | GREEN — ports actually free, then all 5 back |

## Landed repairs (all witnessed in this session)

1. **bootstrap.sh stage 7 idempotency** (`scripts/bootstrap.sh`): a healthy
   already-serving substrate was a typed exit 2 "port held". Now: reuse for the
   smoke (verify `/metadata/endpoints` 200), never tear down a substrate we didn't
   start; only a non-smalt holder is the typed exit 2.
2. **`just up` degraded boot** (root `justfile`): a bare `mix run --no-halt` boot
   serves a SELF-SIGNED cert (`CN=127.0.0.1`, self-issued) that real Azure SDKs
   reject (`DEPTH_ZERO_SELF_SIGNED_CERT`, direct probe) and boots with no SB
   shared key. Now sources `scripts/dev_env.sh` + exports
   `SMALT_TLS_CERTFILE/KEYFILE/SSL_CERT_FILE`, mints certs if absent. Post-fix
   probe: leaf `CN=localhost, i:CN=STRICT X509V3 smalt-dev-ca` (CA-signed).
3. **`just down` orphaned the beam** (root `justfile`): killed only the
   pid-file pid (the bash/mix wrapper) — the beam child kept every port while the
   recipe printed "Substrate stopped." (witnessed: port 9443 still LISTEN after
   "down"). Now also kills live port holders and bounded-poll-verifies 9443 free
   (exit 1 "DOWN FAILED" otherwise).
4. **doctor.py substrate detection** (`scripts/doctor.py`): (a) accepted only the
   substrate.sh state pid — a `just up` beam (mix wrapper pid file) was classified
   foreign → typed FAULT port-in-use. Now resolves the live beam holding 9443
   (`beam.smp` + `mix run` command match). (b) A healthy substrate WITH a
   co-listener (witnessed: an ssh -R relay bound `*:9443/:5672` alongside the
   beam) was a FAULT; now `ok (held by healthy substrate pid N (+ co-listener pid(s) …))`.
5. **sdk recipes repointed** (`justfile.d/04-sdk-recipes.just`): the RETIRED
   exit-1 stubs ran even though the successors exist on disk — the module header
   itself mandates repointing. `sdk-ts` → `verification/ts run-all.mjs`,
   `sdk-census` → `census.test.cjs`, `sdk-py` → `verification/py/run.sh`.
   First repoint attempt: `-x` on a mode-644 `run-all.mjs` fails → `-f`.
6. **wf2 blob leg repaired** (`verification/ts/wf2/index.ts`): three latent bugs
   — stale hardcoded `smaltacct-key` (MAC mismatch; substrate derives
   `base64(sha256(account<>"smalt-dev-sb"))` per `lib/smalt/auth/shared_key.ex`),
   `container` never assigned (ReferenceError on the never-executed path), and
   `container.setLegalHold` does not exist in @azure/storage-blob JS 12.x
   (Python-only API). Rewritten to SDK-lawful surfaces; wf2 now 11/11 GREEN.
7. **wf4 kv-recover URL bug** (`verification/ts/wf4/index.ts`): recover/purge
   appended after `?api-version=` producing `.../recover?api-version=7.4/recover`
   → substrate 400. Substrate route itself verified 200 via curl. Fixed → wf4
   FAIL cells gone (see sdk-ts3 rollup).
8. **py suite premise rot** (`verification/py/test_wf2_concurrency.py`,
   `test_wf3_messaging.py`, `test_wf6_newcaps.py`): ARM PUT namespace now 202-LRO
   (accept 200/201/202), appconfig PUT create-or-update 200 (not only 201), and
   the "JOIN must 400" assertion predated the deliberately-landed JOIN grammar
   (`lib/smalt/cosmos_sql.ex` implements JOIN fan-out) — rewritten as a positive
   JOIN fan-out assertion + grammar-external 400 residue. sdk-py: 21 passed,
   1 honest skip (workspace-tables ARM family not landed, typed), 1 xfail → **exit 0**.
9. **relay-env scheme drift** (`justfile.d/11-relay-env.just`): `SMALT_EGRESS`
   and the CosmosClient cheat-sheet exported `https://127.0.0.1:8443` but the
   egress plane is plain HTTP (`https` handshake fails exit 35; `http` → 401
   challenge). Fixed to `http`.

## Typed gaps (honest red, not hidden)

- **KD-115 (registered, standing UNKNOWN)**: SB plain-queue receiver
  zero-delivery on flow credit — wf3 `sb-send20-receive-complete`,
  `sb-message-lock-lost`, `sb-dlq-maxdelivery` FAIL; `sdk-ts` therefore exits 1
  (honest red per contract). Sessions DO deliver (wf3 `sb-session-fifo` GREEN);
  event hubs fully GREEN. Deep AMQP receiver-engine work outside this lane's
  scope; close condition per `docs/jira/v26.10.19/receipts/kd115-sb-receiver-zero-delivery-tbd.md`.
- **bootstrap stage 8 (`mix test`) on THIS machine**: 1006/1033 pass; 27 failures
  typed as machine-load/concurrent-lane artifacts, not bootstrap defects:
  same tests PASS in isolation (sample re-run: `kv404_typed_error_test.exs` +
  `kv_ec_create_test.exs` → `Result: 7 passed`); the fleet ran ~16 concurrent
  beams and in-flight lib/ edits during the run (witnessed mid-run compile break
  from another lane's half-landed powl2 refactor). A fresh machine or a quiet
  window (`just quiet-check` posture) is the fair gate; the proof stage needs a
  quiet-machine re-run to type GREEN.
- **sdk-census**: exit 1 — 3 pass / 9 fail, all 9 in the KD-115 class
  (zero-delivery receive-timeouts: bytes, dead-letter, deferred-receive,
  exclusive/ordered session, renewal-peek, abandon-complete, dlq-properties).
  Honest red, same registered root cause.
- **keychain-trust advisory**: pre-existing; `sudo security add-trusted-cert…`
  remediation is sudo-gated, typed ADVISORY (not a fault).

## Embedded command receipts (verbatim key lines)

```text
$ just bootstrap            # run 3 (stages 1-7 green; stage 8 below)
[1/8] Prerequisites … ok (0s)
[2/8] Hex dependencies … ok (7s)
[3/8] Compile … ok (14s)
[4/8] Dev environment check … ok (2s)
[5/8] TLS material … reusing existing … ok (0s)
[6/8] Doctor --fix … [PASS] Smalt doctor diagnostic court passed. ok (1s)
[7/8] Boot smoke … substrate already running — reused for smoke (not torn down)
      GET http://127.0.0.1:9443/metadata/endpoints -> 200  ok (0s)
[8/8] Proof test … Result: 1006/1033 passed, 12 excluded, Failed: 27   (typed above)

$ just up (fixed recipe) + port verify
9443 LISTEN … 9444 LISTEN; endpoints=200
openssl s_client … 0 s:CN=localhost /  i:CN=smalt-dev-ca   ← was CN=127.0.0.1 self-issued

$ wf2 leg (real @azure SDKs vs just-up substrate), SMALT_TS_RUNID=bkeng0f*
[GREEN] cosmos-8way-etag-race — 1x200=true 7x412=true winnerV=1
[GREEN] appconfig-ifmatch-race — fulfilled=1 412=1 finalValue=A
[GREEN] blob-upload / blob-download-roundtrip / blob-metadata-echo
[GREEN] blob-ifmatch-stale-412 / blob-delete-202 / blob-container-delete   (11/11 GREEN)

$ just sdk-py
21 passed, 1 skipped, 1 xfailed in 28.11s → SDK_PY_EXIT=0

$ just sdk-ts (run-all.mjs, private v13/v14 substrates)
wf1 12/12 GREEN; wf2 11/11 GREEN; wf4 FAIL cells fixed (kv-recover) —
wf3: 5 GREEN + 3 FAIL (KD-115, registered) → SDK_TS_EXIT=1 (honest red)

$ just doctor (re-run, just-up beam + ssh-relay co-listener)
[PASS] port-arm … ok (held by healthy substrate pid 41684 (+ co-listener pid(s) 42824))
[PASS] Smalt doctor diagnostic court passed.

$ just down && nohup just up && verify   (second session)
[SMALT] Substrate stopped.   (was: printed stopped while beam survived)
lsof 9443 → 0 holders; re-up: 9443:ok 8443:ok 5672:ok 5673:ok 9444:ok; endpoints=200
```

## Files owned/changed by this lane

`scripts/bootstrap.sh`, `scripts/doctor.py`, `justfile` (up/down),
`justfile.d/04-sdk-recipes.just`, `justfile.d/11-relay-env.just`,
`verification/ts/wf2/index.ts`, `verification/ts/wf4/index.ts`,
`verification/py/test_wf2_concurrency.py`, `verification/py/test_wf3_messaging.py`,
`verification/py/test_wf6_newcaps.py`, receipt. No lib/ edits (a mid-run
powl2/executor.ex compile break was another lane's half-landed refactor that
completed on its own; no unblock applied).

## Second session verdict

`just down` → `just up` → 5 ports → endpoints 200 → wf2 SDK touch GREEN — the
engineer's second session works from the Justfile alone. The honest-red
residue is KD-115 (registered open divergence; sdk-ts AND sdk-census exit 1, all
failures one root cause) and a quiet-machine re-run of bootstrap stage 8 to type
it GREEN.
