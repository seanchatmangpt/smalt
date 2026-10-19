#!/usr/bin/env python3
"""portable_target_gate.py — portable-target gate for the verification/ suites.

The verification/{ts,py} suites must run against real Azure SDKs and stdlib
only — no smalt lib/, no mix, no absolute home paths, no undocumented env
reads. Scans verification/** for .ts/.mts/.cts/.js/.mjs/.py/.md files.

Every import/require must be one of:
  (a) official Azure SDK: `@azure/*`, `azure-*` (npm), or `azure.`/`azure-*`
      python packages (azure.core/cosmos/eventhub/servicebus/storage/keyvault/
      identity/mgmt/monitor/appconfiguration/data-tables covered by prefix);
  (b) Python stdlib (sys.stdlib_module_names) or pytest; node:* builtins and
      the plain `node --test` surface (node:test / node:assert);
  (c) relative import resolving within verification/;
  (d) TS-only: type/paths references within the verification tree
      (verification/...).

HARD violations regardless of form: `../lib`, `lib/smalt`, `mix test`,
`mix run`, `Smalt.` (capital-S Elixir module refs), `smalt-cli`, `priv/`,
`test/` imports, `_build`, user-home absolute paths (/(Users|home)/).

Env reads (os.environ / os.getenv / process.env) are allowed ONLY for
`SMALT_AZURE_*` / `AZURE_*` / documented overrides (`SMALT_TS_*`, `SMALT_PY_*`,
`SMALT_ARM_BASE`, `SMALT_EGRESS_BASE`, `SMALT_KV`, `SMALT_VAULT`,
`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
`NODE_TLS_REJECT_UNAUTHORIZED`, `NO_COLOR`, `SMALT_SB_SHARED_KEY`,
`SMALT_THROTTLE_*`, `SMALT_PLANES`, `SMALT_VERIF_SUB`); any other variable is
a violation. The gate's own allowlist/classes JSON read via a __file__-
relative path is lawful by construction (scripts/, not verification/).

Fail-closed: exit 1 on zero files scanned, unreadable file, or any violation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_ROOT = REPO_ROOT / "verification"

# .md prose is documentation (the law docs themselves must name the forbidden
# forms) — scanned for env reads is over-blocking; excluded from the walk.
SCAN_SUFFIXES = {".ts", ".mts", ".cts", ".js", ".mjs", ".py"}

# (a) TS/npm
NPM_ALLOWED = (re.compile(r"^@azure/"), re.compile(r"^azure-"))
NODE_BUILTIN = re.compile(r"^node(:|$)")
# (a)/(b) python
PY_ALLOWED_TOP = {"azure", "pytest", "requests"}  # requests: raw-wire probe legs

# HARD violations (content, regardless of import form)
HARD_PATTERNS = [
    ("../lib", r"\.\./lib\b"),
    ("lib/smalt", r"\blib/smalt\b"),
    ("mix test", r"\bmix test\b"),
    ("mix run", r"\bmix run\b"),
    ("Smalt. module ref", r"\bSmalt\."),
    ("smalt-cli", r"\bsmalt-cli\b"),
    ("priv/", r"\bpriv/"),
    ("test/ import", r"[\"']test/"),
    ("test_helper import", r"[\"']test_helper"),
    ("_build", r"\b_build\b"),
    ("user-home absolute path", r"/(Users|home)/"),
    ("absolute home path", r"\"/home/|'/home/|\"~/(?!/)"),
]

ENV_READ = re.compile(
    r"os\.environ(?:\.get)?\[?\s*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']\s*\]?"
    r"|os\.getenv\(\s*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']"
    r"|process\.env\.([A-Za-z_][A-Za-z0-9_]*)"
    r"|process\.env\[\s*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']\s*\]"
)

ENV_PREFIXES = ("SMALT_AZURE_", "AZURE_", "SMALT_TS_", "SMALT_PY_", "SMALT_THROTTLE_")
ENV_EXACT = {
    "SMALT_ARM_BASE", "SMALT_EGRESS_BASE", "SMALT_KV", "SMALT_VAULT",
    "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE",
    "NODE_TLS_REJECT_UNAUTHORIZED", "NO_COLOR", "SMALT_SB_SHARED_KEY",
    "SMALT_PLANES", "SMALT_VERIF_SUB",
    # harness infra (substrate-ctl / dev-CA location resolution)
    "SMALT_REPO", "SMALT_CERT_DIR",
}

PY_IMPORT = re.compile(
    r"^\s*(?:import|from)\s+([A-Za-z_][A-Za-z0-9_.]*)", re.M
)
TS_IMPORT = re.compile(
    r"""(?:\bimport\b[^\"';]*?|\bexport\b[^\"';]*?\bfrom\b[^\"';]*?|\brequire\(\s*|\bimport\(\s*)[\"']([^\"']+)""",
)
# Import-like statements must START the statement (allowing leading whitespace)
# and carry `from` (or be a bare side-effect `import "x"`) — a
# `path.resolve(import.meta.dirname, "../../..")` argument list or an
# `export const X = "..."` string literal is not an import.
TS_IMPORT_ANCHORED = re.compile(
    r"""^\s*(?:import\b[^\"';]*?\bfrom\b|import|export\b[^\"';]*?\bfrom\b)\s*[\"']([^\"']+)""",
)
TS_DYNAMIC_IMPORT = re.compile(r"""\b(?:require|import)\(\s*[\"']([^\"']+)""")


def env_allowed(name: str) -> bool:
    return name.startswith(ENV_PREFIXES) or name in ENV_EXACT


def py_allowed(mod: str, ts_py: bool) -> bool:
    top = mod.split(".")[0]
    if top in PY_ALLOWED_TOP:
        return True
    if top in sys.stdlib_module_names:
        return True
    return False


def ts_allowed(spec: str, path: Path, root: Path) -> bool:
    if NODE_BUILTIN.match(spec):
        return True
    if any(p.match(spec) for p in NPM_ALLOWED):
        return True
    if spec.startswith("."):
        resolved = (path.parent / spec).resolve()
        return str(resolved).startswith(str(root.resolve()) + "/")
    if spec.startswith("verification/"):
        return True
    return False


def scan_file(path: Path, root: Path, out: list):
    text = path.read_text(encoding="utf-8")
    is_py = path.suffix == ".py"
    is_ts = path.suffix in (".ts", ".mts", ".cts", ".js", ".mjs")
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw
        for label, pattern in HARD_PATTERNS:
            if re.search(pattern, line):
                out.append(f"{path}:{lineno}: HARD violation ({label}): {line.strip()}")
        for m in ENV_READ.finditer(line):
            name = next(g for g in m.groups() if g)
            if not env_allowed(name):
                out.append(
                    f"{path}:{lineno}: env read of undocumented variable {name!r}"
                )
        if is_py:
            for m in PY_IMPORT.finditer(line):
                mod = m.group(1)
                if mod.startswith("."):
                    resolved = (path.parent / mod).resolve()
                    if not str(resolved).startswith(str(root.resolve()) + "/"):
                        out.append(f"{path}:{lineno}: relative import escapes verification/: {mod}")
                elif mod.split(".")[0] in {"conftest", "harness"}:
                    # first-party suite modules (pytest conftest + harness/ pkg)
                    pass
                elif not py_allowed(mod, is_py):
                    out.append(f"{path}:{lineno}: disallowed python import: {mod}")
        if is_ts:
            for m in list(TS_IMPORT_ANCHORED.finditer(line)) + list(TS_DYNAMIC_IMPORT.finditer(line)):
                spec = m.group(1)
                if not ts_allowed(spec, path, root):
                    out.append(f"{path}:{lineno}: disallowed import: {spec}")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if args:
        files = [Path(a) for a in args]
    else:
        if not DEFAULT_ROOT.is_dir():
            print(
                f"[FAIL] verification/ tree absent — portable-target gate scanned 0 files (fail-closed)",
                file=sys.stderr,
            )
            return 1
        # Vendored/dependency trees are third-party, not suite code — excluded
        # from scan scope (the gate judges FIRST-PARTY verification sources).
        EXCLUDED_DIRS = {"node_modules", ".venv", "__pycache__", ".terraform"}
        files = sorted(
            p for p in DEFAULT_ROOT.rglob("*")
            if p.is_file() and p.suffix in SCAN_SUFFIXES
            and not any(part in EXCLUDED_DIRS for part in p.relative_to(DEFAULT_ROOT).parts)
        )
    files = [f for f in files if f.is_file()]
    if not files:
        print("[FAIL] portable-target gate scanned 0 files — fail-closed", file=sys.stderr)
        return 1

    violations: list = []
    try:
        for path in files:
            scan_file(path, DEFAULT_ROOT, violations)
    except OSError as exc:
        print(f"[FAIL] unreadable file: {exc}", file=sys.stderr)
        return 1

    if violations:
        for v in violations:
            print(v)
        print(f"[FAIL] portable-target gate: {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print(f"[PASS] portable-target gate: {len(files)} file(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
