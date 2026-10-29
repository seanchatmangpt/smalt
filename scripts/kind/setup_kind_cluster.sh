#!/usr/bin/env bash
# Vendored from ggen-marketplace k8s/harness/setup_kind_cluster.sh
# (aaif-enterprise-court-cluster pattern), lane BK-MKTG v26.10.22.
# smalt adaptations: default cluster name "kind-smalt", config
# k8s/kind-config.yaml (repo), --wait 180s (BEAM image load headroom).
set -euo pipefail

CLUSTER_NAME="${1:-kind-smalt}"
CONFIG_PATH="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/k8s/kind-config.yaml}"

echo "[INFO] Creating ephemeral kind cluster: ${CLUSTER_NAME}"
kind create cluster --name "${CLUSTER_NAME}" --config "${CONFIG_PATH}" --wait 180s

echo "[INFO] Cluster ${CLUSTER_NAME} initialized successfully."
kubectl cluster-info --context "kind-${CLUSTER_NAME}" || true
