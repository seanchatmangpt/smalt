#!/usr/bin/env bash
# Build the provider binary and write dev.tfrc (dev_overrides, attribute form).
# Never touches ~/.terraformrc.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${MODULE_DIR}"

echo "[build_install] go build terraform-provider-azurerm"
go build -o terraform-provider-azurerm .

echo "[build_install] write dev.tfrc (dev_overrides attribute form)"
bash scripts/dev_overrides.sh > /dev/null

echo "[build_install] OK: ${MODULE_DIR}/terraform-provider-azurerm"
