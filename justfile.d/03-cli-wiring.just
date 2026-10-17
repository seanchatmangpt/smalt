# 03-cli-wiring — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# DoD-3 (CLI wiring lane). smalt-cli lives at smalt-cli/ with two venvs:
#   .venv      — typer + pytest (CLI surface, gates, hw, daemon)
#   .venv-cli  — azure SDKs + pytest (CLI-4/CLI-5 SDK wire lanes in tests/)
# GATE1's discovery (smalt_cli/gates.py SUITE_GLOBS) looks for
# tests/sdk_wire*/ and smalt_cli/test_wire_*.py — the lanes landed tests/ at
# smalt-cli/tests/test_*.py instead. gates.py has no env seam, so cli-gate1
# drives run_gate1(root, targets=...) directly with the real layout and
# satisfies the per-lane venv resolution (ADR-PY-002) via .venvs/<lane>
# symlinks to .venv-cli. gates.py itself is NOT edited.

# SHIM-COURT note: under `import`, justfile_directory() resolves to the repo
# root justfile dir, so no `..` traversal is needed; adding one escapes the
# checkout (was: a sibling smalt-cli dir next to the repo, nonexistent).
SMALT_CLI := justfile_directory() / "smalt-cli"
VENV := SMALT_CLI / ".venv" / "bin" / "python"
VENV_CLI := SMALT_CLI / ".venv-cli" / "bin" / "python"

# Full test suite: SDK wire lanes (tests/) under .venv-cli, package lanes
# (smalt_cli/test_*.py) under .venv.
[private]
@cli-test:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    echo "== SDK wire lanes (tests/) via .venv-cli =="
    "{{VENV_CLI}}" -m pytest tests/ -q -p no:cacheprovider
    echo "== package lanes (smalt_cli/test_*.py) via .venv =="
    "{{VENV}}" -m pytest smalt_cli/ -q -p no:cacheprovider

# All four gates; appends gate<N>.run receipts to audit_manifest.jsonl.
[private]
@cli-gates:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    "{{VENV}}" run_gates.py

[private]
@cli-gate2:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    "{{VENV}}" run_gates.py --gate 2

[private]
@cli-gate3:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    "{{VENV}}" run_gates.py --gate 3

[private]
@cli-gate4:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    "{{VENV}}" run_gates.py --gate 4

# GATE1 pointed at the real landed layout: smalt-cli/tests/test_*.py with the
# .venv-cli interpreter (per-lane venv via .venvs/<lane> symlink, ADR-PY-002).
[private]
@cli-gate1:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    mkdir -p .venvs
    for f in tests/test_*.py; do
        lane="$(basename "$f")"
        [ -e ".venvs/$lane" ] || ln -s ../.venv-cli ".venvs/$lane"
    done
    "{{VENV}}" -c "import glob; from smalt_cli.gates import ROOT, run_gate1; targets = sorted(glob.glob('tests/test_*.py')); print(run_gate1(ROOT, targets=targets).to_json())"

# Run the loopback daemon (reads only).
[private]
@cli-daemon:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    exec "{{VENV}}" -m smalt_cli.daemon

# Smoke: --help plus one real invocation per registered sub-app.
[private]
@cli-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{SMALT_CLI}}"
    "{{VENV}}" -m smalt_cli.cli --help
    "{{VENV}}" -m smalt_cli.cli hw discover
    "{{VENV}}" -m smalt_cli.cli gate audit-integrity
