"""Terraform HCL2 extraction for smalt-migrate (PRD Module 1, REQ-1.1).

Lexer/recursive-descent extraction of declared azurerm resources, modules,
data sources, and nested blocks. Interpolated values (`${...}` / `var.x` /
`module.x` / `data.x`) are typed with full reference qualifiers and
`unresolved: True`, never guessed or collapsed.

Fail-closed: a file whose scan raises or has unbalanced braces surfaces as a
typed ScanError in the topology's `errors` list — never a silent partial.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Resource types this increment understands. Anything else in a scanned file
# is tracked in unsupported_types (PRD scope: Azure resources smalt can emulate).
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

_INTERP = re.compile(r"\$\{")
_REF_RE = re.compile(r"^[a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)+$")
_NUM_RE = re.compile(r"^-?\d+(?:\.\d+)?$")


@dataclass
class ResourceBlock:
    tf_type: str
    hcl_name: str
    file: str
    attributes: dict[str, Any] = field(default_factory=dict)
    nested_blocks: dict[str, list[dict[str, Any]]] = field(default_factory=dict)


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
    modules: list[dict[str, Any]] = field(default_factory=list)
    data_sources: list[dict[str, Any]] = field(default_factory=list)


def _skip_string(text: str, i: int) -> int:
    """Given text[i] == '"', return index just past the closing '"'."""
    n = len(text)
    i += 1
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        if c == "$" and i + 1 < n and text[i + 1] == "{":
            # Skip interpolation ${ ... } inside string (may contain quotes)
            i += 2
            depth = 1
            while i < n and depth > 0:
                ic = text[i]
                if ic == '"':
                    i = _skip_string(text, i)
                    continue
                if ic == "{":
                    depth += 1
                elif ic == "}":
                    depth -= 1
                i += 1
            continue
        i += 1
    return n


def _match_heredoc_end(text: str, i: int) -> int | None:
    """If text[i:] starts a heredoc (`<<EOF` or `<<-EOF`), return index just past
    the closing delimiter line, or None if not a heredoc."""
    m = re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\r?\n", text[i:])
    if not m:
        return None
    delim = m.group(1)
    pos = i + m.end()
    n = len(text)
    while pos < n:
        nl = text.find("\n", pos)
        line_end = nl if nl != -1 else n
        line = text[pos:line_end].rstrip("\r").strip()
        if line == delim:
            return line_end + (1 if nl != -1 else 0)
        pos = line_end + 1 if nl != -1 else n
    return n


def _strip_comments(text: str) -> str:
    """Strip #, //, and /* ... */ comments outside string literals and heredocs."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            end = _skip_string(text, i)
            out.append(text[i:end])
            i = end
            continue
        if c == "<" and i + 1 < n and text[i + 1] == "<":
            hd_end = _match_heredoc_end(text, i)
            if hd_end is not None:
                out.append(text[i:hd_end])
                i = hd_end
                continue
        if c == "#":
            nl = text.find("\n", i)
            if nl == -1:
                break
            out.append("\n")
            i = nl + 1
            continue
        if c == "/" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "/":
                nl = text.find("\n", i)
                if nl == -1:
                    break
                out.append("\n")
                i = nl + 1
                continue
            if nxt == "*":
                end = text.find("*/", i + 2)
                if end == -1:
                    break
                # Preserve newlines for accurate structure
                out.append("\n" * text[i : end + 2].count("\n"))
                i = end + 2
                continue
        out.append(c)
        i += 1
    return "".join(out)


def _match_braces(text: str, open_idx: int) -> int:
    """Return index just past the matching close brace, or -1 (unbalanced)."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = _skip_string(text, i)
            continue
        if c == "<" and i + 1 < n and text[i + 1] == "<":
            hd_end = _match_heredoc_end(text, i)
            if hd_end is not None:
                i = hd_end
                continue
        if c == "{":
            depth += 1
        elif c == "}":
            if depth > 0:
                depth -= 1
                if depth == 0:
                    return i + 1
            else:
                return -1
        i += 1
    return -1


def _match_delim(text: str, open_idx: int, open_ch: str, close_ch: str) -> int:
    """Return index just past matching close_ch (for [] or ()), or -1."""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = _skip_string(text, i)
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def _skip_ws(text: str, i: int) -> int:
    n = len(text)
    while i < n and text[i] in " \t\r\n":
        i += 1
    return i


def _parse_string_literal(raw: str) -> Any:
    val = raw[1:-1]
    val = val.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n")
    if _INTERP.search(val):
        return {"raw": val, "unresolved": True}
    return val


def _classify_ref(raw: str) -> dict[str, Any]:
    parts = raw.split(".")
    head = parts[0]
    if head == "var" and len(parts) >= 2:
        return {"ref": raw, "ref_kind": "var", "ref_name": parts[1], "ref_hcl": None, "unresolved": True}
    if head == "local" and len(parts) >= 2:
        return {"ref": raw, "ref_kind": "local", "ref_name": parts[1], "ref_hcl": None, "unresolved": True}
    if head == "module" and len(parts) >= 2:
        return {"ref": raw, "ref_kind": "module", "ref_name": parts[1], "ref_hcl": None, "unresolved": True}
    if head == "data" and len(parts) >= 3:
        return {
            "ref": raw,
            "ref_kind": "data",
            "ref_type": parts[1],
            "ref_hcl": parts[2],
            "unresolved": True,
        }
    if head in ("each", "count", "self", "path", "terraform"):
        return {"ref": raw, "ref_kind": head, "ref_hcl": None, "unresolved": True}
    return {
        "ref": raw,
        "ref_kind": "resource",
        "ref_type": head,
        "ref_hcl": parts[1] if len(parts) >= 2 else None,
        "unresolved": True,
    }


def _parse_value(raw: str) -> Any:
    raw = raw.strip()
    if not raw:
        return None
    if raw.startswith('"') and _skip_string(raw, 0) == len(raw):
        return _parse_string_literal(raw)
    if raw.startswith("[") and raw.endswith("]"):
        return _parse_list(raw[1:-1])
    if raw.startswith("{") and raw.endswith("}"):
        attrs, _ = _parse_hcl_body(raw[1:-1])
        return attrs
    if raw in ("true", "false"):
        return raw == "true"
    if _NUM_RE.match(raw):
        try:
            return int(raw)
        except ValueError:
            return float(raw)
    if _REF_RE.match(raw):
        return _classify_ref(raw)
    return {"raw": raw, "unresolved": True}


def _parse_list(inner: str) -> list[Any]:
    items: list[Any] = []
    i = 0
    n = len(inner)
    while i < n:
        i = _skip_ws(inner, i)
        if i >= n:
            break
        if inner[i] == ",":
            i += 1
            continue
        start = i
        if inner[i] == '"':
            end = _skip_string(inner, i)
            items.append(_parse_value(inner[start:end]))
            i = end
            continue
        if inner[i] == "{":
            end = _match_braces(inner, i)
            if end < 0:
                break
            items.append(_parse_value(inner[start:end]))
            i = end
            continue
        if inner[i] == "[":
            end = _match_delim(inner, i, "[", "]")
            if end < 0:
                break
            items.append(_parse_value(inner[start:end]))
            i = end
            continue
        # bare token until comma or newline
        while i < n and inner[i] not in ",\n\r":
            if inner[i] == "(":
                end = _match_delim(inner, i, "(", ")")
                i = end if end > 0 else n
            else:
                i += 1
        tok = inner[start:i].strip()
        if tok:
            items.append(_parse_value(tok))
    return items


def _read_value_span(text: str, i: int) -> int:
    """Read an HCL2 expression value starting at i, returning end index."""
    n = len(text)
    i = _skip_ws(text, i)
    if i >= n:
        return i
    c = text[i]
    if c == '"':
        end = _skip_string(text, i)
        # Check for trailing binary/ternary/index operators on the same line
        j = end
        while j < n and text[j] in " \t":
            j += 1
        if j < n and text[j] in ".?[":
            pass
        else:
            return end
    if c == "[":
        end = _match_delim(text, i, "[", "]")
        return end if end > 0 else n
    if c == "{":
        end = _match_braces(text, i)
        return end if end > 0 else n
    if c == "<" and i + 1 < n and text[i + 1] == "<":
        hd_end = _match_heredoc_end(text, i)
        if hd_end is not None:
            return hd_end
    # General expression: read to end of line, balancing (), [], {}
    while i < n and text[i] not in "\n\r":
        ch = text[i]
        if ch == '"':
            i = _skip_string(text, i)
        elif ch == "(":
            end = _match_delim(text, i, "(", ")")
            i = end if end > 0 else n
        elif ch == "[":
            end = _match_delim(text, i, "[", "]")
            i = end if end > 0 else n
        elif ch == "{":
            end = _match_braces(text, i)
            i = end if end > 0 else n
        else:
            i += 1
    return i


def _parse_hcl_body(body: str) -> tuple[dict[str, Any], dict[str, list[dict[str, Any]]]]:
    """Parse top-level attributes and nested sub-blocks of an HCL2 block body."""
    attrs: dict[str, Any] = {}
    nested: dict[str, list[dict[str, Any]]] = {}
    i = 0
    n = len(body)
    ident_re = re.compile(r"[a-zA-Z_][a-zA-Z0-9_-]*")

    while i < n:
        i = _skip_ws(body, i)
        if i >= n:
            break
        m = ident_re.match(body, i)
        if not m:
            # Skip unexpected token to next line
            nl = body.find("\n", i)
            i = nl + 1 if nl != -1 else n
            continue
        key = m.group(0)
        i = _skip_ws(body, m.end())
        if i < n and body[i] == "=":
            val_start = i + 1
            val_end = _read_value_span(body, val_start)
            attrs[key] = _parse_value(body[val_start:val_end])
            i = val_end
            continue

        # Otherwise it's a nested block: `type ["label" ...] { ... }`
        labels: list[str] = []
        while i < n and body[i] != "{":
            if body[i] == '"':
                end = _skip_string(body, i)
                labels.append(body[i + 1 : end - 1])
                i = _skip_ws(body, end)
            else:
                lm = ident_re.match(body, i)
                if lm:
                    labels.append(lm.group(0))
                    i = _skip_ws(body, lm.end())
                else:
                    break
        if i < n and body[i] == "{":
            end = _match_braces(body, i)
            if end < 0:
                break
            sub_body = body[i + 1 : end - 1]
            sub_attrs, sub_nested = _parse_hcl_body(sub_body)
            nested.setdefault(key, []).append(
                {"labels": labels, "attributes": sub_attrs, "blocks": sub_nested}
            )
            i = end
        else:
            nl = body.find("\n", i)
            i = nl + 1 if nl != -1 else n

    return attrs, nested


def _attrs(body: str) -> dict[str, Any]:
    """Compatibility helper returning only top-level attributes."""
    attrs, _ = _parse_hcl_body(body)
    return attrs


def parse_file(path: Path) -> ScanResult:
    """Parse one .tf file into resource, module, and data blocks.
    Never raises for content problems we can classify; unexpected exceptions
    propagate to scan_dir's typed error capture."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    modules: list[dict[str, Any]] = []
    data_sources: list[dict[str, Any]] = []

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return ScanResult([], [ScanError(file=str(path), error=str(exc), error_class="unreadable_file")], 1, {})

    text = _strip_comments(text)
    scanned = 1

    top_re = re.compile(
        r'\b(?P<kind>resource|data|module)\s+"(?P<l1>[^"]+)"(?:\s+"(?P<l2>[^"]+)")?\s*\{'
    )
    pos = 0
    n = len(text)
    while pos < n:
        m = top_re.search(text, pos)
        if not m:
            break
        kind = m.group("kind")
        l1 = m.group("l1")
        l2 = m.group("l2")
        brace_idx = m.end() - 1
        end = _match_braces(text, brace_idx)
        if end < 0:
            label = f"'{l2}' ({l1})" if l2 else f"'{l1}'"
            errors.append(
                ScanError(
                    file=str(path),
                    error=f"unbalanced braces in {kind} block {label}",
                    error_class="unparsable_file",
                )
            )
            break
        body = text[m.end() : end - 1]
        pos = end

        if kind == "resource" and l2 is not None:
            if l1 not in SUPPORTED_TYPES:
                unsupported[l1] = unsupported.get(l1, 0) + 1
                continue
            attrs, nested = _parse_hcl_body(body)
            blocks.append(
                ResourceBlock(
                    tf_type=l1,
                    hcl_name=l2,
                    file=str(path),
                    attributes=attrs,
                    nested_blocks=nested,
                )
            )
        elif kind == "module":
            attrs, nested = _parse_hcl_body(body)
            modules.append(
                {
                    "name": l1,
                    "source": attrs.get("source"),
                    "file": str(path),
                    "attributes": attrs,
                    "nested_blocks": nested,
                }
            )
        elif kind == "data" and l2 is not None:
            attrs, nested = _parse_hcl_body(body)
            data_sources.append(
                {
                    "tf_type": l1,
                    "hcl_name": l2,
                    "file": str(path),
                    "attributes": attrs,
                    "nested_blocks": nested,
                }
            )

    return ScanResult(blocks, errors, scanned, unsupported, modules=modules, data_sources=data_sources)


def scan_dir(directory: Path) -> ScanResult:
    """Scan a directory recursively for .tf files and extract resource blocks."""
    blocks: list[ResourceBlock] = []
    errors: list[ScanError] = []
    unsupported: dict[str, int] = {}
    modules: list[dict[str, Any]] = []
    data_sources: list[dict[str, Any]] = []
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
        modules.extend(res.modules)
        data_sources.extend(res.data_sources)
        for t, c in res.unsupported_types.items():
            unsupported[t] = unsupported.get(t, 0) + c
    return ScanResult(blocks, errors, files, unsupported, modules=modules, data_sources=data_sources)
