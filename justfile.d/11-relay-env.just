# 11-relay-env — canonical session env block for the smalt loopback substrate.
# DoD-11: one recipe that prints (and, when evaled, exports) every variable a
# relay/SDK session needs. All endpoints are 127.0.0.1; all paths in-repo.
#
# Ports mirror smalt-cli/smalt_cli/config.py (ADR-PY-001):
#   SMALT_ARM 9443 / SMALT_EGRESS 8443 / SMALT_AMQP 5672
# AZURE_* mapping is ADR-PY-001 AZURE_EXPORT_PLAN; SDKs that need endpoint
# args instead of env vars are covered by the cheat sheet below.

# Print the canonical env block. Use: eval "$(just relay-env)"
[doc("Print/exports the canonical relay session environment (loopback only)")]
@relay-env:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO="$(git rev-parse --show-toplevel)"
    cd "$REPO"
    echo "# --- smalt relay env (loopback-only, in-repo) ---"
    echo 'export SMALT_ARM="https://127.0.0.1:9443"'
    echo 'export SMALT_EGRESS="https://127.0.0.1:8443"'
    echo 'export SMALT_AMQP="127.0.0.1:5672"'
    echo 'export SMALT_SB_SHARED_KEY="$(openssl rand -base64 32)"'
    echo "export SMALT_SDK_ROOT=\"\${SMALT_SDK_ROOT:-$REPO/test/sdk-smoke/node_modules}\""
    echo '# TLS dev material (mint with: scripts/gen_dev_cert.sh)'
    echo 'export SMALT_TLS_CERTFILE="$PWD/.smalt/tls/dev-cert.pem"'
    echo 'export SMALT_TLS_KEYFILE="$PWD/.smalt/tls/dev-key.pem"'
    echo 'export SSL_CERT_FILE="$PWD/.smalt/tls/ca-cert.pem"'
    echo "# --- AZURE_* mapping (ADR-PY-001, smalt-cli/smalt_cli/config.py) ---"
    echo 'export AZURE_CLIENT_ID="smalt-emulator-client"'
    echo 'export AZURE_TENANT_ID="smalt-emulator-tenant"'
    echo 'export AZURE_CLIENT_SECRET="emulator-accepted"'
    echo 'export AZURE_AUTHORITY_HOST="https://127.0.0.1:9443/"'
    echo 'export AZURE_ARM_ENDPOINT="https://127.0.0.1:9443"'
    echo 'export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=smalt;AccountKey=$(openssl rand -base64 32);EndpointSuffix=smtt.local"'
    echo "# --- endpoint-args cheat sheet (SDKs needing constructor args, not env) ---"
    echo '#   Python:  CosmosClient("https://127.0.0.1:8443", credential=<key>)'
    echo '#   Node:    new CosmosClient({ endpoint: "https://127.0.0.1:8443", key: <key> })'
    echo '#   Node:    new ServiceBusClient("sb://127.0.0.1:5672", cred)'
    echo '#   Node:    new EventHubProducerClient("sb://127.0.0.1:5672", hub, cred)'
    echo '#   smalt-cli reads SMALT_ARM / SMALT_EGRESS / SMALT_AMQP from the environment (no endpoint flags);'
    echo '#   a non-loopback value raises NON_LOOPBACK_ENDPOINT (config.enforce_loopback).'
    echo 'eval "$(scripts/dev_env.sh)"'
