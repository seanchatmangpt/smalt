# Receipt: BK-CELL1 — topology matrix cell 1a witnessed

- **Date**: 2026-10-22
- **Lane**: BK-CELL1
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: docs/jira/v26.10.22/TOPOLOGY-MATRIX.md cell 1 (host-dev x host,
  laptop runner, scale 1) upgraded SUPPORTED-NOW → SUPPORTED-NOW-WITNESSED.
  Falsifier F1 executed against the real substrate + real console.

## Execution

1. **Substrate**: already UP via the lane-safe lock manager
   (`scripts/substrate.sh status`):

   ```
   [STATUS] port 9443: UP (pid 3790 58788)
   [STATUS] port 9444: UP (pid 3790 58788)
   [STATUS] port 5672: UP (pid 3790 58788)
   [STATUS] port 5673: UP (pid 3790)
   [STATUS] substrate UP (pid 3790)
   [STATUS] lock FREE (flock -n succeeds)
   ```

2. **Console**: attempted a lane-private `next dev -p 43211`. Next 16
   refused — the shared `.next` dist dir was already held by a live
   next-server (pid 23623, v16.4.2, port 3000, serving this same
   checkout's workspace and answering HTTP 200 on `/`). Per fan-out law
   (one console surface, no shadow servers) I witnessed against that
   live server rather than kill another actor's process. My spawned
   process exited on its own:

   ```
   ✓ Ready in 348ms
   ⨯ Another next dev server is already running.
   ```

3. **Console root (host-dev face)**:

   ```
   $ curl -s -o /dev/null -w '%{http_code} bytes=%{size_download}' http://localhost:3000/
   200 bytes=10705
   $ curl -sI http://localhost:3000/
   HTTP/1.1 200 OK
   X-Frame-Options: DENY
   X-Content-Type-Options: nosniff
   Referrer-Policy: no-referrer
   Cross-Origin-Opener-Policy: same-origin
   Cross-Origin-Embedder-Policy: require-corp
   Cache-Control: no-store
   ```

4. **Real traffic (BFF face → emulator)**: `POST /api/sync/state`
   (workspace BFF reconciliation gateway — `smaltFetch` → loopback data
   plane :8443 → cosmos sync/state container, STS bearer minted for
   `:enforce` mode):

   ```
   $ curl -s -w '\nHTTP %{http_code}\n' -X POST http://localhost:3000/api/sync/state \
       -H 'content-type: application/json' -H 'origin: http://localhost:3000' \
       -d '[{"id":"bkcell1-witness-doc","data":{"lane":"BK-CELL1","cell":"1a"}}]'
   {"applied":[{"id":"bkcell1-witness-doc","etag":"\"bf860355-9be8-48f7-a3de-64e1db86b03a\"","status":"applied"}],"conflicts":[],"errors":[]}
   HTTP 200
   ```

   A real cosmos etag came back from the emulator — the full hop
   (console BFF → `smaltFetch`/`assertLocalUrl` → loopback :8443 → STS
   mint → cosmos write) executed. F1's "console fetch throws Air-gap
   violation" negation did not occur.

## Falsifier F1 — executed, not falsified

F1 (`just up` + `next dev`, a console page issuing `smaltFetch` returns
backend data; falsified if the fetch throws `Air-gap violation`): the
server-side BFF face issued `smaltFetch` to the real emulator and applied
a doc with a server-issued etag. Cell stands.

## Teardown (honest)

- My spawned dev-server process (pid 22630) exited by itself after the
  `.next` refusal — nothing of mine is left running (`ps -p 22630` → no
  such process).
- Pre-existing next-server pid 23623 (not mine, serving another lane's
  posture on 3000) left untouched.
- Substrate left UP (was up before the lane; shared surface).
- Residue: one test doc `bkcell1-witness-doc` in the emulator's cosmos
  `sync/state` container (witness write). Cosmetic; emulator store is
  dev-scratch.

## Cross-lane disclosure

- Witnessed against the pre-existing dev server on port 3000 (pid 23623)
  instead of a fresh private-port server: Next 16 single-`.next` lock
  makes a second dev server on this checkout impossible without editing
  shared `next.config.mjs` (distDir) — a workspace-lane file I do not
  own. Typed as an environment constraint, not a bypass: the server is
  the same checkout, same code, same substrate.
