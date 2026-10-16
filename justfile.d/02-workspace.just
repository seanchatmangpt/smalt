# 02-workspace — DoD lane module (owner: DoD-2; see docs/jira/v26.10.14)
# Recipes for the Smalt Sovereign Next.js workspace (workspace/).

# Absolute workspace root (justfile lives at repo root, so anchor to it).
ws := join(justfile_directory(), "workspace")

# npm ci when a lockfile exists (reproducible), npm install otherwise.
@ws-install:
    cd {{ws}} && npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund

@ws-build:
    cd {{ws}} && npm run build

@ws-lint:
    cd {{ws}} && npm run lint

# NODE_PATH: the court compiles lib/ to a temp outDir, so plain node
# resolution cannot see workspace/node_modules from there — export it.
@ws-court:
    cd {{ws}} && NODE_PATH="{{ws}}/node_modules" node scripts/e2e-court.mjs

# Converge: run the court; on FAIL, surface each failing check's one-line
# summary (the court already prints `# FAIL: name: detail`) and exit with the
# court's own exit code.
@ws-converge: ws-court
    @cd {{ws}} && NODE_PATH="{{ws}}/node_modules" node scripts/e2e-court.mjs > /tmp/ws-court.log 2>&1; code=$?; \
      if [ $code -ne 0 ]; then \
        echo "ws-converge: court FAILED — failing checks:"; \
        grep '^# FAIL:' /tmp/ws-court.log || cat /tmp/ws-court.log; \
      fi; \
      exit $code
