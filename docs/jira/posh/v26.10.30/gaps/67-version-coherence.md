# Gap 67: version coherence across smalt / posh / tf-provider / charter

Status: CLOSED — no gap in tree; WARN-level skew disclosed, tooling landed.

## Surface

`just version` → `scripts/posh_version.sh` (courtroom-platform-az). Prints
component | version | source file | owning-tree SHA, a SUBJECT-SHA line
(smalt HEAD), and WARN skew notes. Exit 0 always — skew is disclosed, not
failed (charter and release versions legitimately differ).

## Verbatim run (2026-10-30, smalt HEAD f0e0a12575c38f07e37a40ed58f4e448086c97b3)

```
component                     | version              | source file                                | tree SHA
------------------------------+----------------------+--------------------------------------------+------------------
smalt                         | 26.10.25            | mix.exs @version                          | f0e0a12575c3
posh                          | f0e0a125-dirty      | posh/Makefile VERSION (git describe stamp)| f0e0a12575c3
tf-provider-smalt             | dev                 | adapters/terraform-provider-smalt/main.go:28| f0e0a12575c3
posh-charter                  | v26.10.30           | docs/jira/posh/v26.10.30/00-charter.md:1  | f0e0a12575c3
courtroom-az                  | (none)              | (consumer tree; no version declared)      | 31c58e915feb

SUBJECT-SHA (smalt HEAD): f0e0a12575c38f07e37a40ed58f4e448086c97b3

WARN skew: charter v26.10.30 vs smalt mix.exs 26.10.25 — legitimate (charter is the posh v26.10.30 milestone label, not a release version).
WARN skew: terraform-provider-smalt version is the hardcoded 'dev' (main.go:28); stamp via -ldflags "-X main.version=$(git describe --tags --always)" at build. Disclosed one-liner, not landed this lane.
NOTE: posh carries no static version anywhere in-tree (go.mod declares only the module path; go1.26.0 toolchain). The 'posh 0.1.0' in the lane brief is not present in the tree — build-time git-describe stamp is the only version identity.
NOTE (consumed-by): final-wave receipts should cite this table via 'just version' output verbatim, keyed on the SUBJECT-SHA line.
```

## Findings

1. **smalt 26.10.25** — `mix.exs` line 4 `@version "26.10.25"`. Authoritative release version.
2. **posh has NO static version.** go.mod declares only `module smalt.dev/posh` +
   `go 1.26.0`. Identity is the Makefile build stamp: `VERSION ?= $(shell git
   describe --tags --always --dirty)` → `-ldflags -X main.version=$(VERSION)`
   (posh/Makefile:6-7, main.go:51). Current tree stamps as `f0e0a125-dirty`.
   **Lane brief's "posh 0.1.0" does not exist anywhere in-tree** — recorded as a
   brief-vs-tree divergence, not landed as a version.
3. **tf-provider-smalt `dev`** — hardcoded `var version = "dev"`
   (adapters/terraform-provider-smalt/main.go:28, comment: "set for future
   -ldflags injection"). Disclosed stamping one-liner: `go build -ldflags "-X
   main.version=$(git describe --tags --always)"` — NOT landed this lane
   (Makefile edit is another lane's file).
4. **Charter v26.10.30** — `00-charter.md:1` header. Differs from mix 26.10.25
   by design (milestone label). WARN, not FAIL.
5. **courtroom-platform-az** — consumer tree declares no version; tracked by
   SHA only (31c58e915feb at run time).

## Consumed-by

Final-wave receipts should embed this table verbatim (via `just version`) and
key identity on the `SUBJECT-SHA (smalt HEAD)` line — the receipt's subject is
the smalt tree, and the SHA line is the only field that survives a dirty diff.
