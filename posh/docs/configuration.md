# posh Configuration

Configuration for the posh membrane has two surfaces:

1. **`posh.yaml`** — file config, the only admitted egress surface (POSH-008,
   fail-closed). Loaded by `internal/config`.
2. **Environment variables** — operational toggles read at boot/runtime by
   `internal/logging`, `internal/server`, and `cmd/posh`.

## posh.yaml

A missing or empty `posh.yaml` is a **boot refusal** (exit 2), never an open
floodgate. Every validation error names the file, the field, and the expected
type, e.g.:

```
posh: refused boot posh.yaml: field "tcp_addr": host:port address: "" does not parse as host:port (e.g. "127.0.0.1:7443")
```

### Complete annotated example

```yaml
# Required surface. Omitting `socket` is legal; it defaults to run/posh.sock.
socket: run/posh.sock

# Optional extra TCP listener. Format: "host:port". Empty/omitted = disabled.
# Validation requires an explicit host — an empty host is rejected so the
# process never wildcard-listens by accident.
tcp_addr: "127.0.0.1:7443"

# The ONLY admitted egress hostnames (default-deny). Empty/omitted list
# refuses ALL egress; the process still boots and serves local membrane
# traffic. Entries are bare hostnames: no scheme, port, path, or spaces.
# Validation rejects empty entries and entries containing / : @ or space.
egress_allowlist:
  - smalt.internal
  - kind.local
```

### Field reference

| Field | Type | Default | Notes (all validation errors name file+field+expected type) |
|---|---|---|---|
| `socket` | string | `run/posh.sock` | relative paths resolve against the process CWD |
| `tcp_addr` | string (`host:port`) | unset (TCP disabled) | must parse as `host:port` with a non-empty host |
| `egress_allowlist` | list of bare hostnames | `[]` (refuse all egress) | entries non-empty, no `/ : @` or space |

## Environment variables

Environment variables override or supplement file config at the process
level; there is no env var for the yaml fields themselves. Existing variables
(read by the code today):

| Variable | Read by | Default | Values / effect |
|---|---|---|---|
| `POSH_LOG_LEVEL` | `internal/logging` | `info` | `debug\|info\|warn\|error`, case-insensitive; unknown values fall back to `info`. Request-lifecycle logs are `debug`, so `warn+` removes all per-request log work from the hot path. |
| `POSH_DRAIN_TIMEOUT` | `internal/server` (`DrainTimeout`) | `5s` | Go duration (`"2s"`) or plain seconds (`"10"`). Unparseable values fall back to the default (fail-closed to the known-good window, never a zero drain). |
| `POSH_DEBUG` | `cmd/posh` | unset (off) | Exactly `1` starts a **dev-only** pprof HTTP endpoint on `http://127.0.0.1:6060/debug/pprof/`. Loopback-only by construction; never default-on. A failed bind logs to stderr and does not take the membrane down. Not for production. |

### Proposed (TODO — not implemented)

No further env var names are proposed; the three above cover the current
operational surface. If a future ticket adds, e.g., a pprof port override,
name it `POSH_DEBUG_ADDR` and document it in this table.

## Precedence

There is no layered file chain: one `-config <path>` file (default
`posh.yaml`, relative to the process CWD) plus the process environment.
File fields and env vars govern disjoint concerns (yaml = listeners + egress
surface; env = runtime behavior), so no overlap resolution is needed today.

## CLI flags

| Flag | Effect |
|---|---|
| `-config <path>` | Path to posh.yaml (default `posh.yaml`) |
| `-version` | Print `posh <version> (<commit>)` and exit. Version is stamped at build time by `make build` via `-ldflags -X main.version=$(git describe ...)`. Built with plain `go build`, the flag falls back to the toolchain-embedded VCS revision (or `dev`), so it never fails when the stamp is absent. |

## Validation errors

All validation failures are boot refusals (exit 2) and name
**file + field + expected type**:

| Bad value | Error message |
|---|---|
| `tcp_addr: "7443"` | `posh.yaml: field "tcp_addr": host:port address: "7443" does not parse as host:port (e.g. "127.0.0.1:7443")` |
| `tcp_addr: ":7443"` | empty-host refusal (never wildcard-listen by accident) |
| `egress_allowlist: [""]` | `field "egress_allowlist": list of hostnames: empty entry` |
| `egress_allowlist: ["http://x"]` | `field "egress_allowlist": bare hostname: "http://x" contains a scheme, port, path, or space` |
| malformed YAML | `posh.yaml: invalid YAML: ...` |
| file missing | `posh.yaml: file missing or unreadable (fail-closed, POSH-008)` |
