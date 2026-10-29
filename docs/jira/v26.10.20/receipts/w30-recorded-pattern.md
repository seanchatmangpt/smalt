# W30-F — Azure SDK guideline testing-8 recorded-test pattern against smalt

**Standing: PASS** (record → replay green → mutate red triple witnessed)
Date: 2026-10-21 · Lane: W30-F · Context: solo

## Files

- `/Users/sac/smalt/popcorn_demo/azurite-spike/recorded/recorder.mjs` — records a
  real blob round trip against smalt, 6 transactions, pinned
  `api-version=2021-12-02` (testing-8 explicit pin), emits
  `recordings/blob-roundtrip.json` (schema `recorded-test/v1`: per-transaction
  `{name, request:{method,url,headers,body}, response:{status,headers,body}}`).
- `/Users/sac/smalt/popcorn_demo/azurite-spike/recorded/recorded-test.mjs` — replays
  the recordings against smalt with no live recording pass: re-sends each recorded
  request and asserts status + normalized headers + normalized body match exactly.
- `/Users/sac/smalt/popcorn_demo/azurite-spike/recorded/recordings/blob-roundtrip.json`

## Endpoint deviation (disclosed)

The task named smalt 9444. 9444 (ARM TLS twin) routes only the ARM surface — blob
paths return `RouteNotFound` there. The blob data plane is `http://127.0.0.1:8443`;
recorder/replay target it (endpoint is an argv/env override on both scripts).
Witnessed: `curl -sk -X PUT https://127.0.0.1:9444/devstoreaccount1/rec-test/rt.txt
-> 404 {"code":"RouteNotFound"}` vs `8443 -> 201`.

## Witnessed runs (actual output)

Record (fresh run; container `rec-pattern-<ts>-<pid>`):

```
[record] create-container: 201
[record] put-blob: 201
[record] get-blob: 200
[record] get-container-properties: 200
[record] delete-blob: 409
[record] delete-container: 409
[record] wrote 6 transactions -> .../recordings/blob-roundtrip.json
```

Replay (twice, both green, exit 0):

```
[replay] create-container: PASS (201)
[replay] put-blob: PASS (201)
[replay] get-blob: PASS (200)
[replay] get-container-properties: PASS (200)
[replay] delete-blob: PASS (409)
[replay] delete-container: PASS (409)
[replay] 6/6 transactions match recording
```

Non-vacuity (mutated `get-blob` recorded body -> replay red):

```
[replay] get-blob: FAIL
  body: recorded="MUTATED-BODY" actual="hello-recorded-pattern"
[replay] 5/6 transactions match recording
red_exit=1
```

Restore (fresh record pass) -> replay green, exit 0.

## Findings (real behavior, not defects of the pattern)

1. **smalt HTTP-created containers default `immutable=true`** with no policy
   (`lib/smalt/data_plane/blob_storage.ex:2065` create arm; message in
   `blob_service.ex:259`), so blob/container DELETE legs record real
   `409 ContainerLocked` responses and the clean-slate DELETE itself is refused.
   Consequence: recorder and replay mint a fresh container per run and the replay
   performs the guideline's standard URL substitution
   (`/rec-pattern-<ts>-<pid>` -> `/replay-pattern-<runSuffix>`); the recorded
   container name is derived from the recording, not hardcoded.
2. smalt reflects the request `authorization` header on responses and embeds
   volatile `etag`/`last_modified` in PUT-blob JSON bodies — both normalized
   before comparison (header denylist + JSON body key strip), matching how the
   Azure SDK test recorder scrubs volatile fields.

## Env

Pre-existing substrate (beam pid 9849) on 9443/9444/8443, auth_mode `:enforce`;
STS bearer from `POST http://127.0.0.1:9443/organizations/oauth2/v2.0/token`
(any client_id/secret). No bench jsonl emitted (not a bench lane — pattern proof).
