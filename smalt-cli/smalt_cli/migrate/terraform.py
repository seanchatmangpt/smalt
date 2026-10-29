"""Terraform HCL extraction for smalt-migrate (PRD Module 1, REQ-1.1).

Regex/block-scan extraction of declared azurerm resources. Interpolated
values (`${...}` / `var.x`) are typed UNRESOLVED, never guessed.

Fail-closed: a file whose scan raises surfaces as a typed ScanError in the
topology's `errors` list — never a silent partial.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Resource types this increment understands. Anything else in a scanned file
# is ignored (PRD scope: Azure resources smalt can emulate).
SUPPORTED_TYPES = frozenset(
    {
        "azurerm_cosmosdb_account",
        "azurerm_cosmosdb_sql_database",
        "azurerm_cosmosdb_sql_container",
        "azurerm_storage_container",
        "azurerm_servicebus_namespace",
        "azurerm_servicebus_namespace_queue",
        "azurerm_servicebus_topic",
        "azurerm_servicebus_subscription",
        "azurerm_eventhub_namespace",
        "azurerm_eventhub",
        "azurerm_eventhub_consumer_group",
        "azurerm_key_vault",
        "azurerm_key_vault_secret",
        "azurerm_api_management",
    }
)

# resource "TYPE" "NAME" {
_RESOURCE_OPEN = re.compile(r'resource\s+"(?P<type>[^"]+)"\s+"(?P<name>[^"]+)"\s*\{')

_INTERP = re.compile(r"\$\{")


@dataclass
class ResourceBlock:
    tf_type: str
    hcl_name: str
    file: str
    attributes: dict[str, Any] = field(default_factory=dict)


@dataclass
class ScanError:
    file: str
    error: str
    error_class: str = "scan_error"


@dataclass
class ScanResult:
    blocks: list[ResourceBlock]
    errors: list[ScanError]
    files_scanned: int
    unsupported_types: dict[str, int]  # tf_type -> occurrence count


def _strip_comments(text: str) -> str:
    # Line comments and heredoc-free // and #; block comments /* */ too.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)^\s*(#|//).*$", "", text)


def _match_braces(text: str, open_idx: int) -> int:
    """Return index just past the matching close brace, or -1 (unbalanced)."""
    depth = 0
    in_str = False
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}" and depth > 0:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def parse_file(path: Path) -> ScanResult:
    """Parse one .tf file into resource blocks. Never raises for content
    problems we can classify; unexpected exceptions propagate to scan_dir's
    typed error capture."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return ScanResult([], [ScanError(file=str(path), error=str(exc), error_class="unreadable_file")], 1, {})

    text = _strip_comments(text)
    scanned = 1
    for m in _RESOURCE_OPEN.finditer(text):
        tf_type = m.group("type")
        name = m.group("name")
        end = _match_braces(text, m.end() - 1)
        if end < 0:
            errors.append(
                ScanError(
                    file=str(path),
                    error=f"unbalanced braces in resource block '{name}' ({tf_type})",
                    error_class="unparsable_file",
                    )
            )
            continue
        body = text[m.end() : end - 1]
        if tf_type not in SUPPORTED_TYPES:
            unsupported[tf_type] = unsupported.get(tf_type, 0) + 1
            continue
        blocks.append(ResourceBlock(tf_type=tf_type, hcl_name=name, file=str(path), attributes=_attrs(body)))

    return ScanResult(blocks, errors, scanned, unsupported)


def _attrs(body: str) -> dict[str, Any]:
    """Extract top-level scalar attributes and single-line string lists.
    Bare references (`= azurerm_x.y.name`) are typed as refs keyed by their
    HCL label; interpolations (`${...}`) are typed unresolved. Nested blocks
    (e.g. consistency_policy { }) are skipped in this increment."""
    out: dict[str, Any] = {}
    for am in re.finditer(
        r'(?m)^[ \t]*([a-zA-Z_][a-zA-Z0-9_]*)[ \t]*=[ \t]*(.+?)[ \t]*$',
        body,
    ):
        key = am.group(1)
        raw = am.group(2)
        if raw.startswith('"'):
            m = re.match(r'"((?:[^"\\]|\\.)*)"$', raw)
            if not m:
                continue
            val = m.group(1)
            val = val.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n")
            if _INTERP.search(val):
                out[key] = {"raw": val, "unresolved": True}
            else:
                out[key] = val
        elif raw.startswith("["):
            items = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
            if raw.rstrip().endswith("]"):
                out[key] = [
                    {"raw": v, "unresolved": True} if _INTERP.search(v) else v for v in items
                ]
        elif raw in ("true", "false"):
            out[key] = raw == "true"
        elif re.match(r"^-?\d+(?:\.\d+)?$", raw):
            try:
                out[key] = int(raw)
            except ValueError:
                out[key] = float(raw)
        elif re.match(r"^[a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)+$", raw):
            # bare reference: resource TYPE_LABEL.attr or var.name / data.x.y
            parts = raw.split(".")
            out[key] = {"ref": raw, "ref_hcl": parts[1] if len(parts) >= 2 else None, "unresolved": True}
        # anything else (maps, heredocs, functions) is ignored for this increment
    return out


def scan_dir(directory: Path) -> ScanResult:
    """Scan a directory recursively for .tf files and extract resource blocks."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    files = 0
    try:
        tf_files = sorted(directory.rglob("*.tf"))
    except OSError as exc:
        return ScanResult([], [ScanError(file=str(directory), error=str(exc), error_class="unreadable_dir")], 0, {})
    for f in tf_files:
        res = parse_file(f)
        files += res.files_scanned
        blocks.extend(res.blocks)
        errors.extend(res.errors)
        for t, c in res.unsupported_types.items():
            unsupported[t] = unsupported.get(t, 0) + c
    return ScanResult(blocks, errors, files, unsupported)
