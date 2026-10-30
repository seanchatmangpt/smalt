# Gap 14 — kubeconfig contexts vs canonical cluster name `smalt`

Status: **ALIVE** (all probes executed this session, 2026-10-30)
Lane: 14 (read-only probes: kubectl, kind, grep; this file is the only write)

## Observed state (receipts)

- `kubectl config current-context` → `kind-smalt`
- `kubectl config get-contexts` → 11 contexts, none named bare `smalt`
  (colima, kind-a2a-local, kind-athena, kind-bitflow-enterprise, kind-ex4pm,
  kind-kind, kind-ostar, kind-platform-eng-colima-dr, kind-smalt,
  kind-sregym-trial, kind-unrdf)
- `kind get clusters` → `athena`, `smalt` — kind-level cluster name IS `smalt`;
  the kubeconfig context is `kind-smalt` (kind's mandatory `kind-` prefix)
- `kubectl get pods` (current ctx kind-smalt) → live workload
  (posh-sidecar-witness Completed; smalt-backend-0 CrashLoopBackOff, age 30s)
  — current-context currently targets the RIGHT cluster
- `kubectl get pods --context smalt` → `Error in configuration: context was
  not found for specified context: smalt` — loud failure, not silent

## Findings

### F1 — No bare `smalt` context exists; `--context smalt` fails loudly

Severity: **LOW** (loud failure, easy to diagnose). No doc/script/tool outside
`docs/jira` history references `--context smalt` (grep of ~/smalt and
~/cai/courtroom-platform-az: zero hits, non-jira). Close condition: none
required; if a runbook ever writes `--context smalt` it fails with a typed
error, never silently targets the wrong cluster.

### F2 — current-context reliance is guarded in the main court, but some scripts carry hardcoded or global-mutating context handling

Severity: **MEDIUM**.

Evidence:

- `/Users/sac/smalt/scripts/r30-court.sh:48-56` — s00 context-guard reads
  `kubectl config current-context` and REFUSES with rc=1 unless it is exactly
  `kind-smalt`. Good: fail-closed, never silent-wrong-cluster.
- `/Users/sac/smalt/scripts/p08_kind_gate.sh:35-59` and
  `/Users/sac/smalt/scripts/p08_harness.sh:25` — hardcode `--context kind-smalt`
  (explicit, but not derived from `SMALT_KIND_CLUSTER`; renaming the cluster
  via `SMALT_KIND_CLUSTER=x just kind-up` would leave these scripts silently
  pinned to a cluster named smalt).
- `/Users/sac/smalt/justfile.d/52-kind.just:74` (`kind-up`) and `:97`
  (`kind-status`) run `kubectl config use-context kind-{{SMALT_KIND_CLUSTER}}`
  — **mutates the global current-context as a side effect** (`kind-status` with
  `|| true` also flips it when it can). Any concurrent lane or other repo's
  kubectl work on a different cluster (athena, colima, …) silently retargets.

### F3 — Silent-wrong-cluster failure mode

Severity: **MEDIUM**. If current-context drifts to another context
(kind-athena, colima), plain `kubectl get pods` succeeds against the WRONG
cluster with no warning — verified shape: `kubectl get pods` with current ctx
returns real pods, nothing in output names the cluster. Only
`r30-court.sh`'s s00 guard protects; ad-hoc kubectl, `p08_kind_gate.sh` style
scripts, and CI are the silent surface. Close condition: courts/scripts select
context explicitly (flag or `kubectl config use-context` immediately before
the workload, derived from `SMALT_KIND_CLUSTER`) — or a runbook step pins
`kubectl config use-context kind-smalt` before any kubectl block.

### F4 — kubeconfig hygiene

Severity: **LOW**. 10 stale contexts (a2a-local, athena, bitflow-enterprise,
ex4pm, kind, ostar, platform-eng-colima-dr, sregym-trial, unrdf, colima) for
clusters that mostly no longer exist in `kind get clusters`. Harmless today
(only reachable via explicit selection) but widens the F3 silent-drift surface.
Close condition: optional runbook cleanup step
(`kubectl config delete-context/delete-cluster` for non-`kind-smalt` entries,
snapshot first), never blind `~/.kube/config` deletion.

## Row summary

| id | severity | evidence | close condition |
|----|----------|----------|-----------------|
| F1 | LOW | `--context smalt` → typed error (run this session) | none needed |
| F2 | MEDIUM | r30-court.sh:48-56 guard; p08_*.sh hardcoded; 52-kind.just:74,97 global use-context | derive contexts from `SMALT_KIND_CLUSTER`; avoid global `use-context` side effects |
| F3 | MEDIUM | plain kubectl succeeds against wrong cluster silently; only r30-court.sh guards | explicit `--context` in courts; runbook `use-context kind-smalt` step |
| F4 | LOW | 10 stale contexts in `kubectl config get-contexts` | optional cleanup step in runbook, snapshot-first |

Key file: `/Users/sac/smalt/justfile.d/52-kind.just` (lines 74, 97 — the only
global current-context mutation points); guard witness:
`/Users/sac/smalt/scripts/r30-court.sh:48-56`.
