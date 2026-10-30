# Gap 73 — posh go 1.26.0 toolchain: downstream consumer map

Repo: `/Users/sac/smalt` · Date: 2026-10-30 · Status: **ALIVE**

Premise: Gemini bumped `posh/go.mod` to `go 1.26.0`; the sidecar Dockerfile
(builder `golang:1.23-alpine` + `GOTOOLCHAIN=local`) broke. All consumers
re-checked against the live tree; every one runs green today.

## Consumer map (all verified this session)

| # | Consumer | State | Receipt |
|---|---|---|---|
| 1 | `posh/Dockerfile` builder | ALIGNED — `FROM golang:1.26-alpine AS build` + `ENV GOTOOLCHAIN=local` (lines 12–13, coordinator's bump present) | `docker build -t posh:sidecar posh/` exit 0, image `posh:sidecar` sha256:7bfd650a64fd, 18.5MB |
| 2 | `.github/workflows/posh-go.yml` | AUTO-FOLLOWS — all three go steps use `go-version-file:` (`posh/go.mod` @45, `adapters/terraform-provider-smalt/go.mod` @80,123). No pinned go-version; setup-go resolves 1.26.0 from the file, CI will not break | grep receipt above |
| 3 | `.github/dependabot.yml` | ALIGNED — gomod entries for `/posh` and `/adapters/terraform-provider-smalt`, weekly; no go-version pin to update | grep receipt |
| 4 | `adapters/terraform-provider-smalt/go.mod` | UNAFFECTED — separate module, declares `go 1.25.0` (below 1.26, untouched by the bump) | `go build ./...` exit 0 (auto-downloaded go1.25.0), module `terraform-provider-smalt` |
| 5 | Host toolchain (go 1.23.4, `GOTOOLCHAIN=auto`) | WORKS — `cd posh && go build ./...` exit 0: auto downloaded go1.26.0 (`go version` → go1.26.0 darwin/arm64). `go vet ./...` clean. `go test ./...` all ok (15 pkgs, cached) | command receipts above |
| 6 | Lane scripts | NO GO PINS — `scripts/posh_version.sh:59` mentions go1.26.0 prose only; `scripts/trust_shim_probe/go.mod` declares `go 1.23` (own module, unaffected); `scripts/trust_shim/` notes are go1.23.4 cgo witnessing, not pins | grep receipt |

`GOTOOLCHAIN=local` on host refuses exactly as expected:
`go: go.mod requires go >= 1.26.0 (running go 1.23.4; GOTOOLCHAIN=local)` —
the Dockerfile's local+1.26-alpine pairing is the correct local-building fix.

## Close condition for the remaining edge

None required. The "lower the directive" alternative is **not viable**:
dependency floor is above 1.23 — `wazero v1.12.0` requires go1.25.0,
`golang.org/x/tools v0.52.0` declares 1.26.0, `bubbletea v1.3.10` requires
1.24.0 — and no post-1.23 stdlib feature is used in-tree (no `unique`,
`omitzero`, `weak` imports; grep clean), but the dep floor alone blocks
lowering. If a fully pinned host toolchain is wanted later: install go1.26
via brew/asdf; otherwise GOTOOLCHAIN=auto covers it. No lane-reproducibility
break remains open.
