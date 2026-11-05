# 08-publish-dry — DoD lane module (owned by its lane; see docs/jira/v26.10.14)

# Publish dry-run gate: builds the hex tarball and gates it
# (inner-tar key grep, packaged-set leak grep, ERROR_CODES regen identity).
# Exit 0 only if all automatable gates pass.
# Signing-key rotation EXECUTED 2026-10-15; publication gated on final court-x2.
publish-dry:
    @bash scripts/publish_dry.sh

# WO-10 promotion rider (lane 9, v26.11.6): ash_graphlaw is an unconditional
# path dep — the publish-dry gate must never regress it to dev/test-only
# (a `only:` on ash_graphlaw would silently drop the SHACL admission path
# from the packaged product surface).
publish-dry-rider:
    @bash scripts/publish_dry_rider.sh
