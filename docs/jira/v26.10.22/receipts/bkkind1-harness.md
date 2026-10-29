# BK-KIND1 — kind harness conformance (Armstrong OTS drift audit)

Standing: ALIVE. Context: solo.

Lane 3, ggen-marketplace best-practices sweep. Vendored copies audited line-by-line against upstream `~/ggen-marketplace/k8s/harness/` (upstream mtimes 2026-10-08; audit 2026-10-22). Result: 4 deltas justified-local, 1 silent-fork-class delta found and **repaired this lane** (delta 5). Marketplace repo untouched; upstream contribution delivered as the typed note below.

## Embedded diff at audit time (BK-MKTG state)

setup_kind_cluster.sh, vendored vs upstream:

```diff
 #!/usr/bin/env bash
+# Vendored from ggen-marketplace k8s/harness/setup_kind_cluster.sh
+# (aaif-enterprise-court-cluster pattern), lane BK-MKTG v26.10.22.
+# smalt adaptations: default cluster name "kind-smalt", config
+# k8s/kind-config.yaml (repo), --wait 180s (BEAM image load headroom).
 set -euo pipefail

-CLUSTER_NAME="${1:-aaif-enterprise-court-cluster}"
-CONFIG_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kind-cluster-config.yaml"
+CLUSTER_NAME="${1:-kind-smalt}"
+CONFIG_PATH="${2:-$(git rev-parse --show-toplevel)/k8s/kind-config.yaml}"

-kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_PATH}" --wait 60s
+kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_PATH}" --wait 180s
```

teardown_kind_cluster.sh, vendored vs upstream:

```diff
+# Vendored from ggen-marketplace k8s/harness/teardown_kind_cluster.sh ... (3-line header)
-CLUSTER_NAME="${1:-aaif-enterprise-court-cluster}"
+CLUSTER_NAME="${1:-kind-smalt}"
```

## Delta verdicts

| # | delta | verdict | grounds |
|---|---|---|---|
| 1 | 3-line attribution header (both scripts) | justified-local | Armstrong OTS law satisfied — drift is self-typed, not silent |
| 2 | default `CLUSTER_NAME` = `kind-smalt` (both) | justified-local | distinct name avoids collision with other kind clusters on a shared docker host |
| 3 | default `CONFIG_PATH` = repo `k8s/kind-config.yaml` | justified-local | smalt topology (1 control-plane + 2 workers; extraPortMappings 9443/9444/5672/9080) is the whole point; upstream `kind-cluster-config.yaml` is a different topology (8080/8443, 1 worker) |
| 4 | `--wait 60s` → `180s` (setup) | justified-local | witnessed need (BK-K8SM): smalt-hermetic BEAM image load headroom before control-plane readiness |
| 5 | config-path **resolution method**: upstream script-relative (`$(dirname BASH_SOURCE)/..`) → vendored `git rev-parse --show-toplevel` | **silent-fork (minor) — repaired** | the only logic-class delta: the vendored copy hard-depends on a git checkout, while upstream semantics work anywhere. Harmless today (zero callers — `justfile.d/52-kind.just` `kind-up` has its own path), but it was a logic change dressed as a default |

## Delta 5 repair (applied this lane)

Upstream's script-relative semantics restored, adapted to smalt layout
(scripts sit one level deeper, so two levels up):

```bash
CONFIG_PATH="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/k8s/kind-config.yaml}"
```

File: `scripts/kind/setup_kind_cluster.sh` (only change this lane).

## Upstream-improvement direction (typed contribution note)

**Deliverable-only marker**: coordinator owns cross-repo transitions; the
marketplace repo was NOT edited. Note formatted for direct filing upstream.

Learnings from smalt's kind usage (BK-K8SM live cluster creation) that
upstream `k8s/harness/setup_kind_cluster.sh` should adopt, each falsifiable:

1. **Parametrize `CONFIG_PATH` as `$2` and `--wait` as `$3`.**
   Motivation: upstream hardcodes the config path (script-relative) and
   `--wait 60s`, so any downstream with a different cluster topology must
   vendor the script — which is exactly how smalt ended up with a fork.
   With `$2`/`$3`, smalt's vendoring collapses to upstream-with-args:
   `setup_kind_cluster.sh kind-smalt <repo>/k8s/kind-config.yaml 180s` —
   Armstrong's OTS law taken literally.
   Close condition: smalt deletes `scripts/kind/` in favor of
   upstream-with-args once upstream accepts these args.
2. **Stop hardcoding hostPort 8080.** Witnessed 2026-10-22 (BK-K8SM): host
   8080 was occupied on the dev machine; smalt remapped console to 9080.
   Upstream `kind-cluster-config.yaml` maps containerPort 30080 → hostPort
   8080 unconditionally. Improvement: make the console hostPort overridable
   (env var interpolated into the config, or a second fixed mapping on an
   uncommon port), or at minimum document the collision class in the harness
   README. Falsifier: on a machine with anything already listening on 8080,
   upstream setup fails with a bare `bind: address already in use` and no
   typed hint.
3. **Worker count as a parameter (`WORKERS=${WORKERS:-1}` or config
   templating).** BK-K8SM needed 2 workers so the backend StatefulSet's
   2 replicas spread across nodes, and the burn Deployment's required
   anti-affinity needs >= 2 schedulable nodes. Upstream's single hardcoded
   worker makes replica-spreading workloads unschedulable without
   regenerating the config. Falsifier: schedule a 2-replica anti-affinity
   workload against the upstream default config; a pod goes Pending.

## Verification

- `bash -n` on both scripts: clean (`bash -n: both clean`).
- Default config resolution after the delta-5 fix, executed in a real bash
  subshell: resolved to `/Users/sac/smalt/k8s/kind-config.yaml`, `test -f`
  → exists: yes.
- Arg passthrough witnessed live: `bash scripts/kind/setup_kind_cluster.sh
  kind-smalt /tmp/definitely-missing-config.yaml` → `[INFO] Creating ephemeral
  kind cluster: kind-smalt` then `ERROR: failed to create cluster: error
  reading file: open /tmp/definitely-missing-config.yaml: no such file or
  directory` — `$1`/`$2` reach kind; fast-fail before any cluster creation.
- No live cluster created (upstream kind-smalt cluster from BK-K8SM left
  untouched; teardown script unchanged except typed default already present).
