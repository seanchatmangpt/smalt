# KD-166 Wire Witness — SUBPROTOCOL ECHO ABSENT (FIX NOT LANDED) + KD-168 gate confirmation

**Standing:** ALIVE (falsifier executed on the real wire, close condition NOT met — KD-166 fix NOT landed, row stays OPEN; typed, no flip).
Context: solo
Date: 2026-10-22 · Lane: KD-166W · Repo: /Users/sac/smalt

## What ran

Real-substrate wire witness for KD-166 (Web PubSub client WS handshake,
`lib/smalt/webpubsub/router.ex` + `socket.ex`, `# KD-COVERS: KD-166`).

- Substrate: booted by a concurrent lane via `scripts/substrate.sh up` (lock fd
  closed `9>&-`, per-WINDOW flock); status verified **substrate UP (pid 30875)**,
  ports 9443/9444/5672/5673 listening, and the Web PubSub face listening on
  **5676** (`beam.smp` pid 21011). I did not boot or tear down the substrate —
  my `substrate.sh up` attempt was pre-empted by the other lane's lock (exit 143
  during lock wait); I attached to the lane-booted substrate.
- Raw wire client (python3, socket-level HTTP, not a WS library): minted a
  client token via `POST http://127.0.0.1:5676/webpubsub/hubs/chathub/generateToken?userId=witness166`
  (real 200 + JWT), then sent the exact request shape the KD-166 row names:

```
GET /webpubsub/hubs/chathub?access_token=<JWT> HTTP/1.1
Host: 127.0.0.1:5676
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <random 16B, b64>
Sec-WebSocket-Version: 13
Sec-WebSocket-Protocol: json.webpubsub.azure.v1
```

## Raw output (embedded, unedited)

```
HTTP/1.1 101 Switching Protocols
date: Thu, 22 Oct 2026 11:25:27 GMT
upgrade: websocket
connection: Upgrade
sec-websocket-accept: 7Id3M3LBJqY7isirkxpWEeaOn9w=
cache-control: max-age=0, private, must-revalidate
```

**No `Sec-WebSocket-Protocol` header in the 101.** Close condition
(`Sec-WebSocket-Protocol: json.webpubsub.azure.v1` echoed in the 101) is NOT met.

## Corroborating source state (HEAD tree, no git commands run)

- `mix.lock`: bandit **1.13.1** — `deps/bandit/lib/bandit/websocket/handshake.ex`
  `send_handshake/2` builds the 101 from `upgrade/connection/sec-websocket-accept`
  + per-message-deflate extension header + `conn.resp_headers`; **zero
  `sec-websocket-protocol` handling anywhere in deps/bandit/lib**.
- `lib/smalt/webpubsub/router.ex:36` calls `upgrade_adapter(:websocket, ...)`
  with no `sec-websocket-protocol` resp_header set — no custom 101-echo path
  landed. `socket.ex` comments still describe the divergence as present.
- Conclusion: the WPS-EXP4/BK-111 fix is **not landed** on this tree. KD-166
  row stays **OPEN** with its typed disposition; kd_flip not applicable
  (no witness receipt postdates a fix — there is no fix).

## KD-168 (same pass)

Typed disposition: environment-gated (hardware-typed-UNSUPPORTED) — a real
VCEK/VCEM-signed SEV-SNP/TDX quote must be producible/verifiable on this host.
Gate check (one run):

```
$ ls /dev/sev /dev/tdx /dev/sev-guest
ls: /dev/sev: No such file or directory
ls: /dev/tdx: No such file or directory
ls: /dev/sev-guest: No such file or directory
Darwin arm64
```

Gate genuinely unavailable on this host (Darwin/arm64, no TEE devices).
KD-168 stays typed **environment-gated UNSUPPORTED**; no flip, confirmation
recorded here per task.

## Repair owed (not performed by this lane)

Minimal lawful path per the BK-11 disposition: in `lib/smalt/webpubsub/router.ex`,
before `upgrade_adapter`, when the client offered a subprotocol, set
`put_resp_header("sec-websocket-protocol", "json.webpubsub.azure.v1")` — Bandit's
`send_handshake/2` appends `conn.resp_headers` to the 101, so this is the custom
101-echo path. Owner: webpubsub surface lane (WPS-EXP4/BK-111). Re-witness
required after it lands; this receipt does not pre-approve a flip.

## Commands

- `scripts/substrate.sh status` → substrate UP (pid 30875); lock owned by
  lane-booting window; left up (shared, coordinator owns transitions).
- Raw client above, single pass, exit 0; token mint 200; 101 captured.
