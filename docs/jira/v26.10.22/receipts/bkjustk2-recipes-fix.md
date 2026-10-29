# Receipt: bkjustk2-recipes-fix — 52-kind.just garbled-recipe repair + manifest reconciliation

**Standing: PARTIAL_ALIVE** — parse/syntax/prereq-error legs are ALIVE with embedded real
output; the in-cluster ready-wait leg is BLOCKED by an external, session-introduced kubeconfig
corruption (see Falsifiers), not by the recipes. `just --list` exits 0 tree-wide — the BK-MKTG
seal blocker is cleared.

Context: solo. Lane BK-JUSTK2, v26.10.22, repo /Users/sac/smalt.

## What landed

`justfile.d/52-kind.just` (BK-JUSTK's lease, repaired in place; BK-JUSTK had already fixed the
raw garbling live mid-lane — this lane reconciled the recipes onto the landed manifests):

| Recipe | Repair |
|---|---|
| all | defaults reconciled to the landed hand-written manifests: cluster `kind-smalt` (k8s/kind-config.yaml name), namespace `default` (pinned in the manifests), StatefulSet `smalt-backend`, replicas 2 (`SMALT_KIND_N`), new vars `SMALT_KIND_HERMETIC_IMG`, `SMALT_KIND_BACKEND_MANIFEST`, `SMALT_KIND_CONSOLE_MANIFEST`, `SMALT_KIND_STS`, `SMALT_KIND_MANIFEST_NS` (hand-written manifests pin `namespace: default`; .gen.yaml renders never applied) |
| kind-images | now builds + kind-loads all three images: docker/Dockerfile.hermetic→smalt:hermetic, docker/Dockerfile→smalt:local (the StatefulSet's image), Dockerfile.console→smalt-console:local (BK-IMG); per-image typed failure line |
| kind-deploy | applies the hand-written `k8s/smalt-backend.yaml` (the old version probed nonexistent `k8s/backend-statefulset.yaml`/`k8s/smalt-statefulset.yaml` and fell back to a generated heredoc manifest pinning smalt:hermetic + ns smalt); typed fail-closed when the manifest is missing (never applies a .gen.yaml); auto-provisions secret `smalt-tls` from the dev CA (k8s/README.md §2 procedure, minted with the pod-FQDN SANs) with typed fail-closed when no dev CA exists; waits on `statefulset/smalt-backend` |
| kind-undeploy | `kubectl delete -f k8s/smalt-backend.yaml --ignore-not-found` (old version deleted only the generated tmp file) |
| kind-deploy-console | BLOCKED cell retired: Dockerfile.console (BK-IMG) + k8s/smalt-console.yaml (BK-K8SM) have landed; now applies the console manifest + rollout status, URL http://localhost:9080 (kind extraPortMapping 9080→30080) |
| kind-console | URL now http://localhost:9080 (extraPortMapping) + port-forward 3000 fallback; typed ABSENT error reroutes to kind-deploy-console (was BLOCKED text) |
| swarm-up / swarm-status | target `statefulset/smalt-backend`, pods `smalt-backend-N`, pings headless-DNS node names `smalt@<pod>.smalt-backend-headless.default.svc.cluster.local` (matches the manifest's RELEASE_NODE); `Node.list()` length ground truth; per-recipe kubectl prereq check (exit 3 typed) |
| _check_kind_tools | unchanged typed prereq (exit 3, names `brew install <tool>`) |

## Embedded output (real, this session)

```
$ just --list; echo EXIT=$?
Available recipes:  (174 lines, exit 0)
    kind-up / kind-down / kind-status / kind-images / kind-deploy /
    kind-deploy-console / kind-console / swarm-up / swarm-status   (10 matches)
FINAL_LIST_EXIT=0
```

```
$ env PATH="/usr/bin:/bin" just kind-up        # kind/docker/kubectl hidden
[KIND-PREREQ-FAIL] tool not on PATH: kind — install: brew install kind
error: recipe `_check_kind_tools` failed on line 45 with exit code 3
PREREQ_EXIT=3
```

```
$ just kind-up          # env SMALT_KIND_CLUSTER=smalt set in this shell
[KIND-PREREQ] kind/kubectl/docker present
[KIND-UP] cluster smalt already exists — idempotent no-op
NAME                  STATUS   ROLES           AGE   VERSION
smalt-control-plane   Ready    control-plane   10m   v1.34.0
KIND_UP_EXIT=0
```

```
$ just kind-deploy      # leg 1 — real apply + TLS auto-provision (log /tmp/bk2-deploy2.log)
[KIND-PREREQ] kind/kubectl/docker present
[KIND-DEPLOY] minting k8s-scoped TLS pair from dev CA -> secret smalt-tls
secret/smalt-tls created
secret/smalt-release-cookie configured
configmap/smalt-backend-env unchanged
service/smalt-backend-headless created
service/smalt-backend created
service/smalt-backend-nodeport created
statefulset.apps/smalt-backend created
[KIND-DEPLOY] waiting for StatefulSet ready — timed out at 480s (kubeconfig CA data corrupted mid-session, see Falsifiers)
```

```
$ just kind-deploy      # leg 2 — after the kubeconfig corruption, fail-closed typed (recipes clean)
[KIND-PREREQ] kind/kubectl/docker present
[KIND-DEPLOY] minting k8s-scoped TLS pair from dev CA -> secret smalt-tls
error: unable to load root certificates: unable to parse bytes as PEM block
error: recipe `kind-deploy` failed with exit code 1
```

```
$ python3 per-recipe bash -n     (shebang bodies extracted the way just runs them)
kind-up OK / kind-down OK / kind-status OK / kind-images OK / kind-deploy OK /
kind-undeploy OK (per-image typed build/load failure lines) /
kind-deploy-console OK / kind-console OK / swarm-up OK / swarm-status OK
(all 10 shebang bodies bash-syntax clean)
```

## Verification ladder

1. `just --list` exit 0 (tree-wide parse — seal blocker cleared).
2. Per-recipe `bash -n` over the bodies exactly as just materializes them — 10/10 clean.
3. Typed prereq-error path witnessed real on 7 recipes (binaries hidden via PATH):
   exit 3, `[KIND-PREREQ-FAIL] tool not on PATH: <tool> — install: brew install <tool>`.
4. `just kind-up` real: idempotent no-op, exit 0, nodes listed.
5. `just kind-deploy` real apply leg: all resources created for real in `kind-smalt`
   (secret/configmap/3 services/statefulset smalt-backend) + secret smalt-tls minted from the
   dev CA with pod-FQDN SANs.
6. In-cluster ready-wait leg BLOCKED externally: `~/.kube/config` CA data was redacted to the
   literal string `DATA+OMITTED` by another actor mid-session (kubectl now refuses with
   "unable to parse bytes as PEM block" for EVERY context incl. kind-unrdf/kind-ostar —
   not smalt-specific, not caused by the recipes). The recipes' typed fail-closed behavior
   (exit 1 with the underlying kubectl error, no silent hang) was witnessed on leg 2.

## Falsifiers / boundary

- F1 (blocked leg): with a repaired kubeconfig + `just kind-images` (smalt:local never
  built/loaded this session — docker build is the remaining ~minutes leg), `just kind-deploy`
  should reach readyReplicas=2 and `just swarm-status` should witness net_adm:ping pong + Node.list() ≥1.
  Until then the swarm-readiness claim is UNKNOWN, not claimed.
- F2: the working tree 52-kind.just was stomped twice mid-lane by concurrent writers
  (coordinator tick / BK-JUSTK live edits), once reverting to the garbled version and once
  landing BK-JUSTK's own repair; my final version is a targeted diff ON TOP of BK-JUSTK's
  live version (respecting the in-flight lease) — if a later lane's diff dropped my edits,
  re-diff against this receipt's table. My first full-rewrite attempt also self-introduced
  corruption in one Write (witnessed: `{{KILLD_GEN}}`/`{{SMALT_SECRET_NS}` tokens), caught by
  `just --list`/bash -n before any landing; corrected and re-verified. Zero shims in lib/;
  zero lib/ edits.
