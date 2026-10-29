#!/usr/bin/env bash
# Vendored from ggen-marketplace k8s/harness/teardown_kind_cluster.sh
# (aaif-enterprise-court-cluster pattern), lane BK-MKTG v26.10.22.
# smalt adaptation: default cluster name "kind-smalt".
set -uo pipefail

CLUSTER_NAME="${1:-kind-smalt}"

echo "[INFO] Tearing down ephemeral kind cluster: ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" || true
echo "[INFO] Ephemeral cluster ${CLUSTER_NAME} deleted cleanly."
