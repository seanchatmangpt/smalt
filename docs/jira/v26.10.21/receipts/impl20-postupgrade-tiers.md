# IMPL-20: post-upgrade wire-tier re-validation (OTP 29.1.2 recycled substrate)

Context: pair(wire census against the coordinator-recycled shared substrate (bounded-poll recycle observation))

**Standing:** **ALIVE** — full wire-tier census green on the recycled OTP-29 substrate.

- Date: 2026-10-21 13:43 PDT
- Subject: /Users/sac/smalt @ e426d7dd18c0593c3fbfbf2c35c3123f556d296f (main)
- Toolchain: asdf Erlang/OTP 29.1.2 (erts-17.1.1), Elixir 1.20.4-otp-29, Apple M3 Max, macOS 26.2
- Substrate: recycled control-plane beam on :9443 confirmed via `ps` (erts-17.1.1, pid from `lsof -t -iTCP:9443 -sTCP:LISTEN`); `GET /metadata/endpoints` → 200. Bounded poll (20 s interval, 20 min cap) observed the transition OTP 28.3.1 (erts-16.2) → 29.1.2 within ~9 min of lane start.
- Lane build: `MIX_BUILD_ROOT=_build-impl20`, OTP-29 mix from PATH (`/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin`).

## Command (replay)

```bash
export PATH=/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH
MIX_BUILD_ROOT=_build-impl20 mix test test/integration/<file>   # per file below
```

## Census

| File | Result | MIX_EXIT |
|---|---|---|
| test/integration/kv_crypto_face_test.exs | 4 passed, 0 fail | 0 |
| test/integration/apim_wire_test.exs | 6 passed, 0 fail | 0 |
| test/integration/appconfig_events_test.exs | 5 passed, 0 fail | 0 |
| test/integration/kd155_delete_framing_test.exs | 5 passed, 0 fail | 0 |
| test/integration/blob_quota_headers_test.exs | 3 passed, 0 fail | 0 |
| test/integration/kd_conformance_test.exs | 5 passed, 0 fail | 0 |
| **Total** | **28 passed, 0 failures, 0 errors** | — |

Logs: `/tmp/impl20_{apim_wire,appconfig_events,kd155_delete_framing,blob_quota_headers,kd_conformance}.log`

## Findings

- No regressions introduced by the toolchain move. Zero typed findings.
- Session incident (transient, not a regression): first census attempt at 13:40–13:43
  hit a mid-edit `lib/smalt/json_compat.ex` (SyntaxError at 154:1, owned by the
  concurrent IMPL-5 json rollout lane). Compile-freeze SLA observed — lane did not
  touch the file; owner landed a fix within ~3 min and compile recovered; all six
  files then green. Prior to that window, the homebrew OTP-28 toolchain fails to
  compile the current working tree (`blob_storage.ex` defguard error) — the OTP-29
  toolchain is required for this tree state; that failure is pre-existing upstream
  work, not IMPL-20 scope.
