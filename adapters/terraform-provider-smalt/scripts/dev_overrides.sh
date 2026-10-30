#!/usr/bin/env bash
# Idempotently write a Terraform CLI config with a dev_overrides block for the
# locally built azurerm provider, then print the TF_CLI_CONFIG_FILE export line.
# Never touches ~/.terraformrc.
#
# Syntax note: Terraform >= 1.14 rejects labeled dev_overrides blocks
# ("The blocks inside the provider_installation block may not have any
# labels"); the provider source -> path mapping is an attribute of an
# UNLABELED dev_overrides block.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC_FILE="${MODULE_DIR}/dev.tfrc"

mkdir -p "$(dirname "${RC_FILE}")"

cat > "${RC_FILE}" <<HCL
provider_installation {
  dev_overrides {
    "hashicorp/azurerm" = "${MODULE_DIR}"
  }
  direct {}
}
HCL

echo "export TF_CLI_CONFIG_FILE=\"${RC_FILE}\""
