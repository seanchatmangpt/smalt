#!/usr/bin/env bash
# Print the TF_CLI_CONFIG_FILE path for the module's dev.tfrc (dev_overrides,
# attribute form; TF >= 1.14 rejects labeled blocks). Never touches ~/.terraformrc.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC_FILE="${MODULE_DIR}/dev.tfrc"

mkdir -p "$(dirname "${RC_FILE}")"

if [ ! -f "${RC_FILE}" ] || ! grep -q "dev_overrides" "${RC_FILE}" || grep -qE 'dev_overrides\s+"' "${RC_FILE}"; then
  bash "${MODULE_DIR}/scripts/dev_overrides.sh" > /dev/null
fi

echo "${RC_FILE}"
