# tera-gotchas

Tera template failure classes hit this session and in this session's
source material, with the minimal fix for each.

## Filter pipeline inside {% set %} concatenation fails to parse

```text
{% set x = a ~ (b | filter) %}
```

fails at the exact character of the `(` — `Failed to parse ... expected
identifier`. Fix: compute the filtered value in its own `{% set %}` first,
then concatenate two plain variables.

Source: `~/.claude/skills/run-ggen/SKILL.md` Gotchas (verified against
26.8.18 when written). Not re-reproduced this session — cited, not
re-witnessed.

## Optional SPARQL fields need `is defined` guards

A bare comparison on an OPTIONAL field that failed to bind on some rows:

```text
{% if f.maxCount == "1" %}   ->  Variable not found in context
```

Fix:

```text
{% if f.maxCount is defined and f.maxCount == "1" %}
```

Source: SKILL.md Gotchas; the same class surfaced live this session as
`[FM-GEN-008][TEMPLATE_VARIABLE_MISSING]` for a projected-but-unbound
variable (see defect 1 in
[bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md)
— the query-side fix is to bind it; the template-side guard is `is
defined`).

## GROUP_CONCAT over OPTIONAL needs COALESCE

```sparql
GROUP_CONCAT(DISTINCT ?x; separator="|")
```

throws `NotBoundError` on rows where `?x` never binds. Fix:

```sparql
COALESCE(?x, "")
```

inside the aggregate. Source: SKILL.md Gotchas. Not re-reproduced this
session.

## Loop-tag tail hygiene (live-reproduced this session)

Gluing a rendered heredoc delimiter to `{% endfor %}` deletes the
per-iteration newline; the next iteration concatenates onto the delimiter
line. Rendered junk this session, verbatim:

```text
SHEOFcat >> out/installed.exs <<'SHEOF'
```

Fix: newline between the last emitted line and the tag; post-fix
`grep -c "SHEOFcat" out/emit.sh` printed `0`. Full write-up: defect 2 in
[bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md).

## Query-side law that prevents half of these

Every SELECT variable must be bound by a triple pattern in the WHERE body,
not just projected (live-reproduced: `[FM-GEN-008]`, exit 1), and every
SELECT needs `ORDER BY` (live-reproduced: `error[E0013]`, exit 1). See
[the sync-run contract](ggen-sync-run-contract.md).

## Related

- [the sync-run contract](ggen-sync-run-contract.md)
- [bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md)
