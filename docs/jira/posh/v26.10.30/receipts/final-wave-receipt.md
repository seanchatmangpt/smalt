# Final Wave Receipt — posh window v26.10.30 (lane F17)

> **AS-OF NOTE (2026-10-30, added by lane 52):** this receipt predates the Go
> court scripts landing and the C1/C8/C4 changes. Gate verdicts below reflect
> the tree as of ~12:10 local 2026-10-30; later lanes (C1 role_definition close,
> C8 import-formats assertions, C4 changes, Go court scripts under `scripts/`)
> supersede the corresponding failures. Re-read `posh/KNOWN_DIVERGENCES.md` §6
> and `receipts/posh-court/` for current standing.

- **Date**: 2026-10-30 (written ~12:10 local)
- **Lane**: F17 (aggregation receipt, write-only)
- **Subject**: `/Users/sac/smalt` — POSH window v26.10.30 final wave
- **Method**: every gate re-run on disk this session; no session-memory standing.
  Verbatim tails below. `VET_EXIT`/`TEST_EXIT` echoes captured the pipe's exit
  (tail), not go's — the verbatim output lines are the evidence, not those echoes.

## 1. Gate re-verification (on disk, 2026-10-30 ~12:04–12:10)

### Gate 1 — `cd /Users/sac/smalt/posh && go vet ./... && go test ./...`

Run 1 (~12:04): `internal/andon` failed to build (`undefined: CorruptSignalError`,
`openIfExists`, `newLineScanner`, `jsonUnmarshal`); run 2 (~12:10) builds clean.
`internal/andon` files carry mtimes 12:05–12:08 — another lane was mid-write on
that package during run 1. Run 2 verbatim tail (current state):

```
--- FAIL: TestHoldOnSkipAndBlocked (0.00s)
    andon_test.go:203: skip must hold YELLOW, got GREEN
FAIL    smalt.dev/posh/internal/andon   0.404s
ok      smalt.dev/posh/internal/api     (cached)
ok      smalt.dev/posh/internal/armclient       (cached)
ok      smalt.dev/posh/internal/config  (cached)
ok      smalt.dev/posh/internal/doctor  (cached)
ok      smalt.dev/posh/internal/egress  (cached)
ok      smalt.dev/posh/internal/receipt (cached)
ok      smalt.dev/posh/internal/server  (cached)
FAIL
```

**Verdict**: PARTIAL. 7/8 packages pass; `internal/andon` (in-flight lane, files
written during this gate run) has one failing assertion:
`andon_test.go:203: skip must hold YELLOW, got GREEN`.

### Gate 2 — `cd /Users/sac/smalt/adapters/terraform-provider-smalt && go vet ./... && go test ./...`

Verbatim tail:

```
?   	terraform-provider-smalt	[no test files]
ok  	terraform-provider-smalt/internal/provider	3.522s
```

Vet: no diagnostics. Tests: 1/1 package `ok`. **Verdict: ALIVE.**

### Gate 3 — `python3 terraform-provider-smalt/scripts/schema_inventory_gate.py`

**Script does not exist on disk.** `find` over the repo returns zero matches;
`adapters/terraform-provider-smalt/scripts/` contains only `build_install.sh`,
`dev_overrides.sh`, `tfrc.sh`. The migration ledger
(`receipts/migration/terraform-provider-smalt-ledger.md` rows 61–62) records the
gate as **discarded (spike-era gate, regenerable bytecode)**. The 100/100
expectation in the F17 task is stale — the gate was ERRC-deleted with the spike.
**Verdict: N/A (discarded, per ledger).** The POSH-009 coverage gate that
superseded it has receipts on disk: `parity/posh009-coverage-gate-green.json`
(standing ALIVE, verdict "PASS — zero silent gaps", exit 0) and
`parity/posh009-coverage-gate-flip.json` (standing ALIVE, anti-vacuity flip).

### Gate 4 — `cd /Users/sac/smalt && just --evaluate` (parse check)

**FAIL, exit 1.** Verbatim error:

```
error: recipe `posh-up` first defined on line 35 is redefined on line 463
   ——▶ justfile.d/58-posh.just:463:1
    │
463 │ posh-up: posh-build
```

`justfile.d/58-posh.just` defines `posh-up` twice (line 35 and line 463) — the
W-ops lane's additions collided with W-gates' file. Parse-blocking: **every**
`just posh-*` recipe is currently unreachable. **Verdict: BLOCKED (one-line
fix: delete one of the two definitions).**

### Gate 5 — substrate (kind-smalt, live-wire)

`kubectl --context kind-smalt get pods -A` at ~12:05 (verbatim):

```
default              smalt-backend-0    0/2   CrashLoopBackOff   7 (29s ago)   119s
kube-system          coredns-66bc5c9577-cfmt6     1/1  Running  0  17m
kube-system          kube-proxy-mmlz5             0/1  Error    1  13s
kube-system          kube-proxy-tclxn             0/1  Error    1  13s
(+ control plane Running; kindnet 3 nodes)
```

Re-check at ~12:10: `The connection to the server 127.0.0.1:59455 was refused`
— the kind ladder churned between checks (F3's posh-court attempt recreated the
cluster; see F3 receipt below). `curl /metadata/endpoints`:
`8080:000 9444:000 4000:000` (connection refused/failed on all three; port 8080
returned 404 at ~12:05 while the pod was up, i.e. route missing even then).
smalt-backend pod logs unreadable (API server port changed with cluster churn).

**Verdict: BLOCKED — live-wire substrate is down at wrap.** Consistent with the
F3 court receipt (`posh-court-green.json`, standing FAIL: posh-court 0/8 PASS,
failing at `[POSH-COURT-PRE]` kind disk preflight —
`14756MB avail on smalt-control-plane:/var/lib/containerd (< 20000MB)`, host
volume at 94% capacity; port 9444/9445 held by beam 47052).

## 2. Wave tabulation (from receipts/docs on disk + untracked trees)

Receipts on disk: `receipts/dflss_audit_receipt.json`,
`receipts/measure/posh002-latency.json` (PASS),
`receipts/migration/{terraform-provider-smalt-ledger.md, posh007-errc-delete-receipt.json}`,
`receipts/mutation/turnstile-flip.json` (PASS),
`receipts/parity/{posh009-coverage-gate-green.json, posh009-coverage-gate-flip.json}` (ALIVE),
`receipts/posh-court/{go-gates-witness-f11.json (ALIVE, -race clean),
live-wire-witness-f2.json, posh-court-green.json (standing FAIL, 0/8)}`,
`receipts/wave2-membrane-receipt.json` (status GREEN).

| lane | tree | status on disk |
|---|---|---|
| POSH-001 / W-armclient / A1/A3 | `posh/` (Go module, untracked) | PARTIAL — 7/8 pkgs green (F11 -race witness ALIVE); `internal/andon` mid-write, 1 failing test at re-run |
| POSH-002 / W-turnstile, W-client, W-port, W-blake3 | `lib/smalt/posh/` (7 files + egress/ingress) | GREEN — wave2-membrane-receipt GREEN, turnstile byte contract pinned (digest `0c39d201…`), mutation flip PASS, latency receipt PASS |
| POSH-003 | `posh/internal/armclient/` | ALIVE — tests ok; C6 `arm probe` live 200 witness (in POSH-003 ticket) |
| POSH-004 / W-provider | `adapters/terraform-provider-smalt/` (untracked) | ALIVE — vet clean, tests ok; CI job defined in `posh-go.yml` |
| POSH-005 / W-sidecar, W-ops | `k8s/smalt-backend.yaml` (M), `k8s/posh-sidecar.yaml`, `docker/Dockerfile.posh`, `justfile.d/59-posh-ops.just` | PARTIAL — stanzas landed; live substrate down at wrap (crashloop / cluster churn) |
| POSH-006 / W-gates | `justfile.d/58-posh.just` (untracked) | BLOCKED — posh-court 0/8 (kind disk preflight); duplicate `posh-up` definition makes justfile unparseable |
| POSH-007 / R6 | `receipts/migration/` | ALIVE — ERRC delete APPLIED, archive sha256 `f0fe321b…` verified |
| POSH-008 / A7 | `lib/smalt/posh/egress/` + `posh/internal/egress` | ALIVE — egress tests ok, NAT64 fence test PASS (F11) |
| POSH-009 / A8 | `scripts/posh_coverage.py` + `receipts/parity/` | ALIVE — coverage gate green + flip receipts; `scripts/posh_mutation_court.py` present |
| POSH-010 / F13 | `_LANES.md`, `RESOLUTIONS.md` | ALIVE — final lane partition + seam decisions minted |
| pack lane P3 | `ggen-marketplace/packs/posh/` (untracked) | LANDED — frontmatter-schema pack (ggen 26.10.11), copy-out disabled pending KD-POSH-5 |
| CI lane 10 | `.github/workflows/posh-go.yml` (untracked) | LANDED — two jobs (posh + provider), live tests gated off via `TFPOSHT_LIVE` |

## 3. Standing verdicts — POSH-001..010

| order | standing | basis |
|---|---|---|
| POSH-001 Go adapter scaffold | **PARTIAL** | 7/8 pkgs pass; `internal/andon` 1 failing test (in-flight lane at re-run time) |
| POSH-002 BEAM membrane protocol | **ALIVE** | membrane GREEN, turnstile digest pinned, mutation flip PASS, latency PASS |
| POSH-003 Azure ARM client | **ALIVE** | tests ok + live 200 witness |
| POSH-004 Terraform provider (Go) | **ALIVE** | vet clean + tests ok + CI job |
| POSH-005 k8s sidecar | **PARTIAL** | artifacts landed; live substrate down at wrap |
| POSH-006 courts and gates | **BLOCKED** | posh-court 0/8 (kind disk preflight); justfile parse error blocks all `posh-*` recipes |
| POSH-007 migration from Elixir provider | **ALIVE** | ERRC delete APPLIED, sha-verified archive |
| POSH-008 egress fences | **ALIVE** | egress tests + NAT64 fence PASS |
| POSH-009 SDK parity register | **ALIVE** | coverage gate green + anti-vacuity flip receipts |
| POSH-010 lanes and wave plan | **ALIVE** | `_LANES.md`/`RESOLUTIONS.md` minted at wrap |

## 4. Open BLOCKEDs

1. **justfile parse error** (`justfile.d/58-posh.just`: `posh-up` defined at
   line 35 and line 463) — blocks every `just posh-*` recipe incl. posh-court.
   One-line coordinator fix; smallest unblock with the highest leverage.
2. **posh-court 0/8** — fails in `[POSH-COURT-PRE]` kind ladder: node disk
   preflight `14756MB < 20000MB` on `/var/lib/containerd` (60GB host volume at
   94%). Needs disk reclamation (route through osx-clnr / `just kind-prune`
   chain) before any court run.
3. **Live-wire substrate down at wrap** — kind-smalt API port churned,
   smalt-backend CrashLoopBackOff, `/metadata/endpoints` unreachable on all
   ports (8080 returned 404 while pod was up — route missing even when up).
4. **`internal/andon` failing test** (`TestHoldOnSkipAndBlocked`: skip must
   hold YELLOW, got GREEN) — in-flight lane surface; owner must land or revert.
5. **schema_inventory_gate.py gone** — the F17 task's gate (3) expectation
   (100/100) is stale; the gate was ERRC-discarded (ledger rows 61–62). Any
   doc still citing it needs the pointer moved to `scripts/posh_coverage.py`.

## 5. Proposed atomic commit plan (coordinator-owned; NOT executed)

All commits in `/Users/sac/smalt` with `git commit -F <msgfile>`. Commit only
the posh-window trees below — `git status` also carries many unrelated
modified files (docs/jira/v26.10.14–22 indices, lib/smalt/* data-plane splits,
config/, docker/Dockerfile.hermetic, .ggen_igniter/manifest.json) from earlier
windows; those are outside this wave and must not be swept into these commits.

1. **Go core** — `Add posh Go adapter core (POSH-001/003/008)`
   Files: `posh/` (whole untracked tree: cmd/, internal/, bin/, docs/, go.mod,
   go.sum, default.pgo) — note: gate on `internal/andon` first (BLOCKED #4).
   Message tail: gates witness F11 + this receipt's gate 1 run-2 tail.
2. **Provider** — `Add Go terraform provider adapter (POSH-004)`
   Files: `adapters/` (whole untracked tree).
3. **Membrane** — `Add posh BEAM membrane, client, turnstile, port supervision (POSH-002)`
   Files: `lib/smalt/posh/` (untracked) + coordinator-owned modified seams:
   `lib/smalt/arm_gateway/router.ex`, `lib/smalt/application.ex`,
   `lib/smalt/plane/identity_supervisor.ex`,
   `lib/smalt/plane/integration_supervisor.ex`, config seams `config/runtime.exs`,
   `config/test.exs`.
   Message tail: wave2-membrane-receipt + turnstile digest `0c39d201…`.
4. **Gates/ops** — `Add posh court/gate/ops recipes (POSH-006, POSH-005 ops)`
   Files: `justfile.d/57-tf-provider.just`, `justfile.d/58-posh.just` (AFTER
   fixing the duplicate `posh-up`), `justfile.d/59-posh-ops.just`, root
   `Justfile` (import lines), `scripts/posh_coverage.py`,
   `scripts/posh_mutation_court.py`.
5. **Packaging/k8s** — `Add posh sidecar stanza and packaging (POSH-005)`
   Files: `k8s/smalt-backend.yaml` (M), `k8s/posh-sidecar.yaml`,
   `docker/Dockerfile.posh`.
6. **CI** — `Add posh Go CI workflow`
   Files: `.github/workflows/posh-go.yml`, `.github/dependabot.yml`,
   `.github/workflows/kind-swarm.yml` (M, verify diff is posh-related first).
7. **Pack** — `Add posh ggen marketplace pack (P3, KD-POSH-5 copy-out disabled)`
   Files: `ggen-marketplace/packs/posh/` (untracked).
8. **Docs/receipts** — `Add posh window v26.10.30 docs and receipts`
   Files: `docs/jira/posh/` (whole untracked tree, incl. this receipt).

Order rationale: code (1–3) before gates (4) — the gates parse fix must land
before courts can run; packaging/CI (5–7) independent; docs last so the
receipts reference landed SHAs. Untracked stragglers to triage before the docs
commit: `justfile.d/56-courtroom.just`, `docs/jira/v26.10.25/` and
`v26.10.28/`, `.ggen_igniter/receipts/2026-10-30.jsonl` — not posh-window
files; coordinator to route to their own windows' commits.

## 6. Lane verdict

**PARTIAL.** Receipt written with real on-disk command outputs; gate 1 and
gate 5 failures are real (in-flight andon test; substrate down), gate 4 is a
one-line parse fix away, gate 3 is N/A (gate discarded by the wave itself).
