#!/bin/sh
# hermetic-entrypoint — readOnlyRootFilesystem-compatible exec of the prod
# release. Runtime-injected material only:
#   - TLS: mount .smalt/tls at $SMALT_CERT_DIR (default /smalt/.smalt/tls) or
#     override SSL_CERT_FILE / SMALT_CERT_DIR env.
#   - Credentials: env only (no baked keys; SMALT_* / AZURE_* contract per
#     README / `just relay-env`).
# No writes outside tmpfs-declared paths (/tmp, /app/_release/tmp).
set -eu

# HOME must be writable for the BEAM's transient files (.erlang.cookie
# handling lives under HOME); /tmp is tmpfs-declared.
export HOME="${HOME:-/tmp}"
[ -w /tmp ] || { echo "hermetic-entrypoint: /tmp not writable — declare it tmpfs" >&2; exit 1; }

RELEASE_BIN="/app/_release/bin/smalt"
[ -x "$RELEASE_BIN" ] || { echo "hermetic-entrypoint: missing $RELEASE_BIN" >&2; exit 1; }

exec "$RELEASE_BIN" "$@"
