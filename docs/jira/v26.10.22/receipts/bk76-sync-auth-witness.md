# BK-76 — Sync batch route enforce-mode auth witness (BK-63 deviation 2 closed)

**Standing:** **ALIVE** — `/sync/journal/batch` is enforce-lawful on the real wire: tokenless → 401 + KD-15 challenge, STS-minted bearer → 200 `{lastSeq, receiptToken}`, garbage bearer → 401.

Context: solo

## What was disclosed (BK-63 deviation 2)

BK-63's sync-route court rode `:anonymous` auth mode, so the enforce-mode STS bearer was never exercised on `/sync/journal/batch`. This receipt witnesses the route under the default `:enforce` mode on the live substrate — the goal is to prove the route is enforce-lawful, not an auth exemption. Client-side snapback/verify is unaffected (auth is transport-layer).

## Boot

- Canonical checkout `/Users/sac/smalt`, branch `main` @ `adb460a` + in-flight tree.
- Pinned toolchain (`.tool-versions`: elixir 1.20.4-otp-29 / erlang 29.1.2); bare `mix` in the shell resolved to 1.19.5 — all mix invocations ran with the pinned installs on PATH.
- `MIX_BUILD_ROOT=_build-bk76` (lane lease), warm compile exit 0 (~47s incremental after first full pass).
- Boot: `MIX_BUILD_ROOT=_build-bk76 SMALT_UP_TIMEOUT=240 9>&- just substrate-up` → exit 0, all 4 listeners (9443/9444/5672/5673) UP, lock fd closed, `scripts/substrate.sh` derives the per-host dev key and hard-pins `auth_mode: :enforce` (substrate.sh:210).
- Batch body: 3 frames (`Smalt.Sync.Frame.encode`, seqs 1–3, client_id `0x7600000000000001`, 180 bytes) encoded via `mix run --no-start` on the same build root, written to `/tmp/bk76_batch.bin`.

## Wire evidence (real curl, host 127.0.0.1)

### Leg 1 — tokenless batch POST → 401 + KD-15 challenge

```
curl -sS -X POST -H "Content-Type: application/octet-stream" \
  --data-binary @/tmp/bk76_batch.bin http://127.0.0.1:8443/sync/journal/batch
# http_code=401  curl_exit=0
```

Headers:

```
www-authenticate: Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:8443", error="invalid_token", error_description="MissingBearerToken"
access-control-expose-headers: www-authenticate
{"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}
```

### Leg 2a — STS mint (`POST /dev/oauth2/v2.0/token`, client_credentials)

```
curl -sS -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=bk76-probe&client_secret=bk76-secret&scope=api://smalt/.default" \
  http://127.0.0.1:9443/dev/oauth2/v2.0/token
# http_code=200  curl_exit=0
# token_type=Bearer expires_in=3600 token_len=1263 header=eyJhbGciOiJSUzI1NiIs (RS256)
```

### Leg 2b — batch POST with STS-minted bearer → 200

```
curl -sS -X POST -H "Content-Type: application/octet-stream" \
  -H "Authorization: Bearer $TOK" \
  --data-binary @/tmp/bk76_batch.bin http://127.0.0.1:8443/sync/journal/batch
# http_code=200  curl_exit=0
```

Body (truncated token):

```
{"frames":[{"seq":1,"verdict":"admit"},{"seq":2,"verdict":"admit"},{"seq":3,"verdict":"admit"}],
 "lastSeq":3,
 "receiptToken":"534d4c540000000100000000000000037fd3c3a3..."}
```

Independent seal verification (python, over the exact 180 wire bytes): magic `534d4c54`, version 1, leafCount 3, reserved 272 zero bytes, recomputed sha256-chain root `7fd3c3a3...01c7c` == token root. `root_match=True`.

### Leg 3 — garbage bearer → 401

```
curl -sS -X POST -H "Authorization: Bearer garbage.bk76.not-a-jwt" \
  --data-binary @/tmp/bk76_batch.bin http://127.0.0.1:8443/sync/journal/batch
# http_code=401  curl_exit=0
www-authenticate: ... error="invalid_token", error_description="SignatureVerificationFailed"
{"error":{"code":"InvalidAuthenticationToken","message":"SignatureVerificationFailed"}}
```

## Verdict

- `/sync/journal/batch` sits BEHIND the global bearer guard (`Smalt.Auth.Bearer` plug runs before the `w6r_fallthrough` chain that owns `Smalt.Egress.SyncRoutes`); it is NOT in the exempt namespace (`@exempt_prefixes` = `/oauth2/`, `/.well-known/`, `/common/discovery/`, `/attest/`; tenant STS regex covers only `/{tid}/oauth2/v2.0/token` — `/sync/*` matches none).
- BK-63 deviation 2 closed: the route is enforce-lawful on the wire, not an auth exemption. The client-side snapback/verify path is transport-auth-orthogonal.
- Client_id `0x7600000000000001` committed head now 3 on the shared substrate (sync store state, harmless scratch identity).

## Commands / exits

| step | command | exit |
|---|---|---|
| warm compile | `MIX_BUILD_ROOT=_build-bk76 asdf exec mix compile` | 0 |
| boot | `MIX_BUILD_ROOT=_build-bk76 SMALT_UP_TIMEOUT=240 9>&- just substrate-up` | 0 |
| frame encode | `mix run --no-start -e '...'` (bk76 build root) | 0 (180 bytes) |
| leg 1 | tokenless POST | curl 0, HTTP 401 |
| leg 2a | STS mint | curl 0, HTTP 200 |
| leg 2b | bearer POST | curl 0, HTTP 200 |
| leg 3 | garbage bearer POST | curl 0, HTTP 401 |
| seal check | python sha256-chain recompute | root_match=True |

## Falsifier

A tokenless or garbage-bearer batch POST returning non-401 on the enforce-mode substrate, or a valid STS bearer returning non-200, inverts this receipt. Neither observed; leg status pinned above with live wire output.

## Notes for the register

- Not committed (per instruction).
- Substrate left UP on `_build-bk76` (it was UP at lane start; restarted under the lane lease to pick up the warm build).
- `SMALT_UP_TIMEOUT` was needed at 240s on this loaded host (default 90s can lose to a cold dep compile even with a warm app build).
