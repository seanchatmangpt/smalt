# POSH-001: posh Go module scaffold inside smalt

## Task
Create /Users/sac/smalt/posh/ as a Go module (go.mod, module smalt.dev/posh),
with cmd/posh/ main serving the membrane listener. Go 1.23+ (present: 1.23.4).
Structure: cmd/posh/main.go, internal/server (UDS+TCP listener), internal/api
(request/response types), Makefile (build static binary to posh/bin/posh).

## Acceptance
- `make -C posh build` produces posh/bin/posh (static, CGO_ENABLED=0).
- posh binary boots, serves a /healthz over its local socket, exits on SIGTERM.
- smalt repo .gitignore covers posh/bin/.

## Falsifier
A build that links cgo or requires runtime deps beyond the binary FAILS.

## Constraints
One canonical checkout (inside smalt repo); no vendoring without lockfile receipt.
