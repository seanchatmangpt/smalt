# ============================================================================
# 52-kind.just — kind/swarm topology (lanes BK-JUSTK + BK-JUSTK2, v26.10.22).
#
# Engineer path:  just kind-up -> kind-images -> kind-deploy -> swarm-status
#
# BK-JUSTK2 repair (BK-MKTG garbled-recipe dependency fix + manifest
# reconciliation, receipt docs/jira/v26.10.22/receipts/bkjustk2-recipes-fix.md):
# recipes now target the canonical deployable set — HAND-WRITTEN
# k8s/smalt-backend.yaml (StatefulSet smalt-backend, ns default) and
# k8s/smalt-console.yaml.
# The k8s/*.gen.yaml renders are gate-checked REFERENCE only (BK-MKTG typed
# diff: no StatefulSet/multi-port/env) — never applied by these recipes.
# Console-in-cluster is UNBLOCKED (Dockerfile.console landed, BK-IMG).
#
# KROOT: for an IMPORTED module, justfile_directory() is already the repo
# root (imports merge into the root namespace); parent_directory would
# resolve to /Users/sac (witnessed: kind-images run 1 cd'd there and
# `git rev-parse` died with exit 128).
#
# W-D (kind node containerd disk-full incident): kind-images pre-flights the
# node's /var/lib/containerd free space and prunes unused images
# (crictl rmi --prune) before the build loop — fail-closed below 20000MB
# even after prune ([KIND-IMAGES-FAIL] node disk low). just kind-prune
# exposes the prune standalone.
# ============================================================================

KROOT := justfile_directory()

# Identity (override via env: SMALT_KIND_*).
SMALT_KIND_CLUSTER     := env_var_or_default("SMALT_KIND_CLUSTER", "smalt")
SMALT_KIND_NS          := env_var_or_default("SMALT_KIND_NS", "smalt")
SMALT_KIND_BACKEND_IMG := env_var_or_default("SMALT_KIND_BACKEND_IMG", "smalt:hermetic")
SMALT_KIND_CONSOLE_IMG := env_var_or_default("SMALT_KIND_CONSOLE_IMG", "smalt-console:local")
SMALT_KIND_N           := env_var_or_default("SMALT_KIND_N", "2")
SMALT_KIND_HERMETIC_IMG := env_var_or_default("SMALT_KIND_HERMETIC_IMG", "smalt:hermetic")
# Deployable manifest identity — HAND-WRITTEN k8s/ files are canonical
# (BK-MKTG typed diff: the k8s/*.gen.yaml renders cannot model
# StatefulSet/multi-port/env and would boot a broken swarm; never apply them).
SMALT_KIND_BACKEND_MANIFEST := "k8s/smalt-backend.yaml"
SMALT_KIND_CONSOLE_MANIFEST := "k8s/smalt-console.yaml"
SMALT_KIND_STS          := "smalt-backend"
# The hand-written manifests pin `namespace: default`.
SMALT_KIND_MANIFEST_NS  := "default"
KIND_GEN               := "tmp/kind"

# Fail-closed tool check — typed error naming the install command, exit 3.
_check_kind_tools:
    @for t in kind kubectl docker; do \
        command -v "$t" >/dev/null 2>&1 || { \
          echo "[KIND-PREREQ-FAIL] tool not on PATH: $t — install: brew install $t" >&2; \
          exit 3; }; \
      done; echo "[KIND-PREREQ] kind/kubectl/docker present"

# Create the kind cluster from the canonical k8s/kind-config.yaml (REQUIRED —
# the generated single-node fallback heredoc was removed fail-closed, W-D:
# a silently-generated config diverges from the canonical topology and masks
# config drift). Idempotent: existing cluster is a no-op success.
[no-cd]
kind-up: _check_kind_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{KROOT}}
    cfg="k8s/kind-config.yaml"
    if [ ! -f "$cfg" ]; then
      echo "[KIND-UP-FAIL] $cfg missing — canonical kind config is required (generated fallback removed, W-D); restore k8s/kind-config.yaml or derive one from k8s/kind/cluster.yaml" >&2
      exit 1
    fi
    if kind get clusters | grep -qx "{{SMALT_KIND_CLUSTER}}"; then
      echo "[KIND-UP] cluster {{SMALT_KIND_CLUSTER}} already exists — idempotent no-op"
    else
      kind create cluster --name {{SMALT_KIND_CLUSTER}} --config "$cfg" --wait 180s \
        || { echo "[KIND-UP-FAIL] kind create cluster exited nonzero" >&2; exit 1; }
    fi
    kubectl config use-context kind-{{SMALT_KIND_CLUSTER}} >/dev/null
    kubectl get nodes

# Delete the kind cluster. Idempotent (exit 0 when already absent).
[no-cd]
kind-down:
    #!/usr/bin/env bash
    set -euo pipefail
    if kind get clusters 2>/dev/null | grep -qx "{{SMALT_KIND_CLUSTER}}"; then
      kind delete cluster --name {{SMALT_KIND_CLUSTER}}
    else
      echo "[KIND-DOWN] cluster {{SMALT_KIND_CLUSTER}} absent — idempotent no-op"
    fi

# Witness cluster + swarm surface (report-only, exit 0 always).
[no-cd]
kind-status:
    #!/usr/bin/env bash
    set -uo pipefail
    command -v kind >/dev/null 2>&1 || { echo "[KIND-PREREQ-FAIL] kind — install: brew install kind" >&2; exit 3; }
    if ! kind get clusters 2>/dev/null | grep -qx "{{SMALT_KIND_CLUSTER}}"; then
      echo "[KIND-STATUS] cluster {{SMALT_KIND_CLUSTER}} not created — run: just kind-up"
    else
      kubectl config use-context kind-{{SMALT_KIND_CLUSTER}} >/dev/null 2>&1 || true
      echo "[KIND-STATUS] nodes:"
      kubectl get nodes 2>/dev/null || true
    fi
    echo "[KIND-STATUS] swarm surface (ns {{SMALT_KIND_MANIFEST_NS}}):"
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} get statefulset,deploy,pods,svc -o wide 2>/dev/null \
      || echo "  (namespace surface not deployed — run: just kind-deploy)"

# Standalone node-image prune (W-D disk-full incident). Deletes unused images
# inside the kind node's containerd to reclaim /var/lib/containerd space.
# Fail-closed (exit 1) when the cluster is not up.
[no-cd]
kind-prune:
    #!/usr/bin/env bash
    set -euo pipefail
    node="{{SMALT_KIND_CLUSTER}}-control-plane"
    command -v docker >/dev/null 2>&1 || { echo "[KIND-PREREQ-FAIL] docker — install: brew install docker" >&2; exit 3; }
    docker inspect "$node" >/dev/null 2>&1 \
      || { echo "[KIND-PRUNE-FAIL] node container $node not found — run: just kind-up first" >&2; exit 1; }
    echo "[KIND-PRUNE] pruning unused images in $node (/var/lib/containerd)"
    docker exec "$node" crictl -r unix:///run/containerd/containerd.sock rmi --prune
    echo "[KIND-PRUNE] done; witness: docker exec $node df -m /var/lib/containerd"

# Containerd disk preflight (W-D): free MB on /var/lib/containerd in the kind
# node, one crictl-prune retry, fail-closed below 20000MB after prune.
[no-cd]
_kind_node_disk_preflight:
    #!/usr/bin/env bash
    set -euo pipefail
    node="{{SMALT_KIND_CLUSTER}}-control-plane"
    docker inspect "$node" >/dev/null 2>&1 \
      || { echo "[KIND-IMAGES-FAIL] node container $node not found — run: just kind-up first" >&2; exit 1; }
    free_mb() {
      docker exec "$node" env LC_ALL=C df -k -P /var/lib/containerd 2>/dev/null \
        | awk 'NR==2 {print int($4/1024)}'
    }
    avail="$(free_mb)"
    # Threshold default 20000MB; SMALT_KIND_MIN_DISK_MB overrides explicitly
    # (witnessed 2026-10-30: the shared colima VM volume also hosts a second
    # live kind cluster whose volumes hold ~27GB, so the default cannot be
    # met on this host — the override is the disclosed, typed way past it).
    threshold="${SMALT_KIND_MIN_DISK_MB:-20000}"
    echo "[KIND-IMAGES] node $node /var/lib/containerd avail: ${avail:-?}MB (threshold ${threshold}MB)"
    if [ "${avail:-0}" -lt "$threshold" ]; then
      echo "[KIND-IMAGES] below threshold — crictl rmi --prune"
      docker exec "$node" crictl -r unix:///run/containerd/containerd.sock rmi --prune || true
      avail="$(free_mb)"
      echo "[KIND-IMAGES] after prune avail: ${avail:-?}MB"
    fi
    if [ "${avail:-0}" -lt "$threshold" ]; then
      echo "[KIND-IMAGES-FAIL] node disk low: ${avail:-0}MB avail on $node:/var/lib/containerd (< ${threshold}MB after prune) — run: just kind-prune, or kind-down + kind-up to recreate" >&2
      exit 1
    fi
    echo "[KIND-IMAGES] node disk preflight OK"

# Docker build the three images and `kind load docker-image` all into the
# cluster: hermetic runtime (docker/Dockerfile.hermetic ->
# SMALT_KIND_HERMETIC_IMG), backend release (docker/Dockerfile ->
# SMALT_KIND_BACKEND_IMG, the image the StatefulSet pins as smalt:local),
# console (Dockerfile.console -> SMALT_KIND_CONSOLE_IMG, BK-IMG).
# Sibling path deps ride as build contexts per docker/README.md; SUBJECT_SHA
# is a REQUIRED build-arg for both backend builds (org.smalt.subject label
# discipline). The console build has no sibling build contexts.
[no-cd]
kind-images: _check_kind_tools _kind_node_disk_preflight
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{KROOT}}
    SHA=$(git rev-parse HEAD)
    ctx=(--build-arg SUBJECT_SHA="$SHA"
         --build-context ash_graphlaw="$PWD/../ash_graphlaw"
         --build-context ggen_igniter="$PWD/../ggen_igniter"
         --build-context ash_r2rml="$PWD/../ash_r2rml"
         --build-context graphlaw_ex="$PWD/../graphlaw/graphlaw_ex")
    for spec in \
      "docker/Dockerfile.hermetic|{{SMALT_KIND_HERMETIC_IMG}}|yes" \
      "docker/Dockerfile|{{SMALT_KIND_BACKEND_IMG}}|yes" \
      "Dockerfile.console|{{SMALT_KIND_CONSOLE_IMG}}|no"; do
      IFS='|' read -r df img withctx <<<"$spec"
      echo "[KIND-IMAGES] building $img ($df)"
      if [ "$withctx" = yes ]; then
        docker build -f "$df" -t "$img" . "${ctx[@]}" \
          || { echo "[KIND-IMAGES-FAIL] docker build failed: $df -> $img" >&2; exit 1; }
      else
        docker build -f "$df" -t "$img" . \
          || { echo "[KIND-IMAGES-FAIL] docker build failed: $df -> $img" >&2; exit 1; }
      fi
      kind load docker-image "$img" --name {{SMALT_KIND_CLUSTER}} \
        || { echo "[KIND-IMAGES-FAIL] kind load failed: $img" >&2; exit 1; }
    done
    echo "[KIND-IMAGES] 3 images built and loaded into kind cluster {{SMALT_KIND_CLUSTER}}"

# Apply the HAND-WRITTEN backend manifest (k8s/smalt-backend.yaml: cookie+TLS
# Secrets, ConfigMap, headless/ClusterIP/NodePort Services, StatefulSet
# smalt-backend ns=default) and wait ready. BEAM distribution:
# RELEASE_NODE=smalt@<pod>.smalt-backend-headless.default.svc.cluster.local,
# shared RELEASE_COOKIE — net_adm:ping across pods (witness: swarm-status).
# Before first apply, overwrite the cookie placeholder host-side:
#   kubectl create secret generic smalt-release-cookie \
#     --from-literal=cookie="$(openssl rand -hex 16)" --save-config
# Replicas are managed by the manifest/swarm-up, not this recipe.
[no-cd]
kind-deploy: _check_kind_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{KROOT}}
    m="{{SMALT_KIND_BACKEND_MANIFEST}}"
    [ -f "$m" ] || { echo "[KIND-DEPLOY-FAIL] $m manifest missing — hand-written manifest is the deployable set; do NOT substitute k8s/*.gen.yaml (BK-MKTG typed diff)" >&2; exit 1; }
    # TLS Secret `smalt-tls` must exist before the StatefulSet mounts it
    # (k8s/README.md §2); auto-provision from the dev CA when available,
    # typed fail-closed otherwise (never a pending-forever pod).
    if ! kubectl -n {{SMALT_KIND_MANIFEST_NS}} get secret smalt-tls >/dev/null 2>&1; then
      if [ -f .smalt/tls/ca-cert.pem ] && [ -f .smalt/tls/ca-key.pem ]; then
        echo "[KIND-DEPLOY] minting k8s-scoped TLS pair from dev CA -> secret smalt-tls"
        mkdir -p {{KIND_GEN}}
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -CA .smalt/tls/ca-cert.pem \
          -CAkey .smalt/tls/ca-key.pem \
          -subj "/CN=smalt-backend-0.smalt-backend-headless.{{SMALT_KIND_MANIFEST_NS}}.svc.cluster.local" \
          -addext "subjectAltName=DNS:localhost,DNS:smalt-backend-0.smalt-backend-headless.{{SMALT_KIND_MANIFEST_NS}}.svc.cluster.local,DNS:smalt-backend-1.smalt-backend-headless.{{SMALT_KIND_MANIFEST_NS}}.svc.cluster.local,DNS:smalt-backend.{{SMALT_KIND_MANIFEST_NS}}.svc.cluster.local,IP:127.0.0.1" \
          -keyout {{KIND_GEN}}/k8s-tls-key.pem -out {{KIND_GEN}}/k8s-tls-cert.pem
        kubectl create secret tls smalt-tls --cert={{KIND_GEN}}/k8s-tls-cert.pem --key={{KIND_GEN}}/k8s-tls-key.pem -n {{SMALT_KIND_MANIFEST_NS}} --save-config
      else
        echo "[KIND-DEPLOY-FAIL] secret smalt-tls missing and .smalt/tls dev CA not found — run scripts/gen_dev_cert.sh, then retry; or create: kubectl create secret tls smalt-tls --cert=... --key=... (k8s/README.md §2)" >&2; exit 1
      fi
    fi
    kubectl apply -f "$m"
    echo "[KIND-DEPLOY] waiting for StatefulSet {{SMALT_KIND_STS}} ready"
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} wait --for=jsonpath='{.status.readyReplicas}'={{SMALT_KIND_N}} --timeout=600s "statefulset/{{SMALT_KIND_STS}}" \
      || { echo "[KIND-DEPLOY-FAIL] not ready in 600s — witness: kubectl -n {{SMALT_KIND_MANIFEST_NS}} get pods -o wide; just kind-status" >&2; exit 1; }
    echo "[KIND-DEPLOY] deployed and ready; witness: just swarm-status"

# Remove the swarm (cluster stays). Idempotent (delete --ignore-not-found).
[no-cd]
kind-undeploy: _check_kind_tools
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{KROOT}}
    m="{{SMALT_KIND_BACKEND_MANIFEST}}"
    kubectl delete -f "$m" --ignore-not-found
    echo "[KIND-UNDEPLOY] swarm removed"

# Deploy the console (k8s/smalt-console.yaml: Deployment + NodePort 30080).
# Unblocked: Dockerfile.console (BK-IMG) and the console manifest (BK-K8SM)
# have landed. Requires console image loaded (just kind-images).
[no-cd]
kind-deploy-console: _check_kind_tools
    # [KIND-CONSOLE-BLOCKED] retired: Dockerfile.console + manifest landed.
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{KROOT}}
    m="{{SMALT_KIND_CONSOLE_MANIFEST}}"
    [ -f "$m" ] || { echo "[KIND-CONSOLE-FAIL] $m missing" >&2; exit 1; }
    kubectl apply -f "$m"
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} rollout status deploy/smalt-console --timeout=300s \
      || { echo "[KIND-CONSOLE-FAIL] console Deployment not ready in 300s" >&2; exit 1; }
    echo "[KIND-CONSOLE] deployed; host URL http://localhost:9080 (kind extraPortMapping 9080->30080)"

# Console port-forward (localhost:3000). Fail-closed when not deployed
# in-cluster; prints the host alternative.
[no-cd]
kind-console:
    #!/usr/bin/env bash
    command -v kubectl >/dev/null 2>&1 || { echo "[KIND-PREREQ-FAIL] kubectl — install: brew install kubectl" >&2; exit 3; }
    if ! kubectl -n {{SMALT_KIND_MANIFEST_NS}} get svc/smalt-console >/dev/null 2>&1; then
      echo "[KIND-CONSOLE-ABSENT] svc/smalt-console not found in ns {{SMALT_KIND_MANIFEST_NS}} — run: just kind-deploy-console. Host alternative: (cd workspace && npm run dev)" >&2
      exit 3
    fi
    echo "[KIND-CONSOLE] http://localhost:9080 (kind extraPortMapping), or port-forward -> http://localhost:3000 (Ctrl-C to stop)"
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} port-forward svc/smalt-console 3000:3000

# Scale the backend StatefulSet to N (arg; default 2, matching the manifest).
# Fail-closed when the StatefulSet is absent.
[no-cd]
swarm-up N="{{SMALT_KIND_N}}":
    #!/usr/bin/env bash
    set -euo pipefail
    command -v kubectl >/dev/null 2>&1 || { echo "[KIND-PREREQ-FAIL] kubectl — install: brew install kubectl" >&2; exit 3; }
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} get "statefulset/{{SMALT_KIND_STS}}" >/dev/null \
      || { echo "[SWARM-UP-FAIL] statefulset/{{SMALT_KIND_STS}} not found in ns {{SMALT_KIND_MANIFEST_NS}} — run: just kind-deploy" >&2; exit 1; }
    kubectl -n {{SMALT_KIND_MANIFEST_NS}} scale "statefulset/{{SMALT_KIND_STS}}" --replicas="{{N}}"
    echo "[SWARM-UP] replicas -> {{N}}; witness: just swarm-status"

# Witness the Erlang swarm: from {{SMALT_KIND_STS}}-0, net_adm:ping every
# peer by headless-DNS node name
# (smalt@<pod>.smalt-backend-headless.default.svc.cluster.local — the node
# names the manifest's RELEASE_NODE pins), then Node.list() length as ground
# truth. Fails closed when the swarm is not up or when node 0 sees no peers.
[no-cd]
swarm-status:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v kubectl >/dev/null 2>&1 || { echo "[KIND-PREREQ-FAIL] kubectl — install: brew install kubectl" >&2; exit 3; }
    ns="{{SMALT_KIND_MANIFEST_NS}}"
    sts="{{SMALT_KIND_STS}}"
    kubectl -n "$ns" get pod "$sts-0" >/dev/null \
      || { echo "[SWARM-STATUS-FAIL] pod $sts-0 not found — run: just kind-deploy" >&2; exit 1; }
    echo "[SWARM-STATUS] pinging from $sts-0 (node names smalt@<pod>.smalt-backend-headless.$ns.svc.cluster.local):"
    peers=0
    for i in 0 1 2 3 4 5 6 7; do
      pod="$sts-$i"
      kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 || break
      [ "$pod" = "$sts-0" ] && continue
      fqdn="$pod.smalt-backend-headless.$ns.svc.cluster.local"
      r=$(kubectl -n "$ns" exec "$sts-0" -- /app/_release/bin/smalt eval \
            ":net_adm.ping(:'$fqdn')" 2>/dev/null | tail -1)
      case "$r" in
        pong) echo "  smalt@$fqdn pong"; peers=$((peers+1)) ;;
        *)    echo "  smalt@$fqdn pang ($r)" ;;
      esac
    done
    members=$(kubectl -n "$ns" exec "$sts-0" -- /app/_release/bin/smalt eval 'length(Node.list())' 2>/dev/null | tail -1)
    echo "[SWARM-STATUS] Node.list() length: $members"
    [ "${members:-0}" -ge 1 ] || { echo "[SWARM-STATUS-FAIL] $sts-0 sees no cluster peers" >&2; exit 1; }
    echo "[SWARM-STATUS] ALIVE ($peers peer(s) ponged)"
