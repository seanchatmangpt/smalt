# 08-publish-dry — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# Publish dry-run gate: builds the hex tarball and gates it
# (inner-tar key grep, packaged-set leak grep, ERROR_CODES regen identity).
# Exit 0 only if all automatable gates pass.
# Signing-key rotation is deliberately pending (coordinator decision).
publish-dry:
    @bash scripts/publish_dry.sh
