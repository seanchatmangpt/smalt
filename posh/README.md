# posh — Go adapter membrane for smalt

POSH-001 scaffold. SPAF Tier 2: a stateless Go "foreign membrane" between the
smalt BEAM core and hyperscaler ecosystems (Azure ARM, Terraform, Kubernetes).
Protocol translation only — zero domain state (charter law 2).

## Layout

- `cmd/posh/main.go` — entrypoint; op registry (`echo` is the first admitted op).
- `internal/server` — membrane listener: unix socket `run/posh.sock` + optional
  TCP, length-prefixed JSON framing, `/healthz`, graceful SIGTERM shutdown.
- `internal/api` — typed request/response envelopes (`id`, `op`, `params`,
  `deadline`; `ok`/`error` with codes `TRANSPORT | UPSTREAM | DEADLINE |
  REFUSED_EGRESS`).
- `internal/config` — `posh.yaml` egress allowlist loader; fail-closed on
  missing file (POSH-008).
- `posh.yaml` — runtime config (see below).

## Prerequisites

- colima running (`colima start`); kind + kubectl on PATH (kind cluster
  canonical name: `smalt` — `just kind-up` creates it)
- Go 1.23+ (this module); Terraform >= 1.14, < 2 (provider dev_overrides)
- asdf Elixir 1.20.4 only for BEAM-side tests — system mix (Elixir 1.19.5) fails
- `ggen` optional (only for `posh-generate`)
- Ordering contract: `just kind-up` → `just kind-images` → `just kind-deploy`
  → `just posh-court`

## Build & test

    make build   # CGO_ENABLED=0 static binary -> bin/posh
    make test    # Chicago tests: real listener over temp sockets, no mocks
    make vet

## Quickstart: boot + echo (one terminal, three commands)

> Canonical onboarding path: smalt `README.md` §POSH (`just posh-court`).
> This section is the membrane-only echo walk, not the full operator path.

```bash
make -C posh build
mkdir -p posh/run && (cd posh && ./bin/posh -config posh.yaml &) && sleep 1
python3 - <<'PY'
import socket, struct, json
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect("posh/run/posh.sock")
b = json.dumps({"id":"q1","op":"echo","params":{"msg":"hello"}}, separators=(",",":")).encode()
s.sendall(struct.pack(">I", len(b)) + b)
h = s.recv(4); n = struct.unpack(">I", h)[0]
body = b""
while len(body) < n: body += s.recv(n - len(body))
print(json.loads(body))
PY
pkill -f bin/posh || true
```

Expect `{'id': 'q1', 'ok': {'result': {'msg': 'hello'}}}`. Full framing
details: `docs/wire-protocol.md`. `pkill` sends SIGTERM; the membrane shuts
down gracefully and removes the socket file.

## Run

    posh -config posh.yaml

Listens on the unix socket from `posh.yaml` (default `run/posh.sock`); set
`tcp_addr` to also serve HTTP (`/healthz` and JSON envelope POSTs) over TCP.
SIGTERM shuts down gracefully and removes the socket file.

## posh.yaml

```yaml
socket: run/posh.sock
tcp_addr: ""            # optional, e.g. 127.0.0.1:7443
egress_allowlist:       # default-deny; missing file refuses boot (POSH-008)
  - smalt.internal
```

## Wire protocol (v1)

4-byte big-endian length prefix + JSON envelope. Requests carry `id`, `op`,
`params`, `deadline`. Responses carry exactly one of `ok`/`error`. Unknown ops
are typed `UPSTREAM` errors; malformed envelopes are typed `TRANSPORT` errors.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Boot refuses, exit 2, "refused boot" | `posh.yaml` missing/invalid (fail-closed, POSH-008) | Run from `posh/` or pass `-config <path>` to a valid `posh.yaml` |
| Boot refuses, exit 3, "refused listen" | Socket dir unwritable or stale socket | `mkdir -p run`; `rm -f run/posh.sock`; check `socket:` path |
| Connect: `No such file or directory` on `run/posh.sock` | Membrane not running or working dir differs | `socket:` resolves against the process CWD; run both from `posh/` |
| `frame length N out of bounds` then EOF | Frame `> 4 MiB` (`MaxFrameBytes`) or zero-length frame | Split the payload; see `docs/wire-protocol.md` |
| `{"code":"UPSTREAM","message":"unknown op \"...\""}` | Op not in the `cmd/posh/main.go` registry | Use an admitted op (`echo`); register new ops behind the egress allowlist |
| `{"code":"REFUSED_EGRESS", ...}` | Destination host not on `egress_allowlist` | Add the bare hostname to `posh.yaml` `egress_allowlist` |
| `{"code":"DEADLINE", ...}` / HTTP 504 | Handler exceeded the request `deadline` | Raise the RFC 3339 `deadline` in the request envelope |
