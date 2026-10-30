# bulk-generate-scaffolds

How to render a whole decomposition plan — any N-target scaffold set — as
one ontology, one rule, one loop, and how to fix the two defects this
session actually hit while doing it.

## The pattern (real project: /tmp/ggen-split)

/tmp/ggen-split renders 25 module scaffolds with one rule. The stanza from
`/tmp/ggen-split/ggen.toml`, verbatim:

```toml
[[generation.rules]]
name = "module-scaffold"
query = { file = "queries/extract.rq" }
template = { file = "templates/module.ex.tera" }
output_file = "all-modules.txt"
mode = "Overwrite"
```

## The ontology models the plan, not the files

`ontology/split.ttl` declares a `spl:Ticket` per split ticket and a
`spl:Module` per target file. Real rows (verbatim, abbreviated to two of
25):

```turtle
spl:t06 a spl:Ticket ; rdfs:label "T06" ;
        spl:receipt "r6-armgateway-split.md" .

spl:m5 a spl:Module ; spl:tickets spl:t06 ;
       spl:receipt "r6-armgateway-split.md" ;
       spl:path "lib/smalt/arm_gateway/engine/lro.ex" ;
       spl:ns "Smalt.ArmGateway.Engine.Lro" ;
       rdfs:label "long-running-operation engine" ;
       spl:gate "test/internal + test/integration green, zero test edits" .
```

Each row carries the ticket pointer, the landing receipt, the target path,
the namespace, a boundary label, and the gate string. The graph holds the
plan; the template renders one scaffold per row; the lane lands behavior by
verbatim extraction, guided by the scaffold's own moduledoc.

## The template loop

`templates/module.ex.tera` is one `{% for %}` over `sparql_results`. The
`{% endfor %}` sits on its own line — tail hygiene (defect 2 below). Full
text is in the tutorial's template section; the rendered excerpt in
[the tutorial](../tutorials/ggen-first-sync.md#the-real-thing-you-just-built)
is what one row becomes.

## Defect 1 — projected-but-unbound variable

SELECT projects `?receipt`; the WHERE body never binds it. ggen exits 1 at
render, and no file is written. Reproduced this session, verbatim stderr:

```text
ERROR: CLI execution failed: Command execution failed: validation error:
[FM-GEN-008][TEMPLATE_VARIABLE_MISSING] example=`/private/tmp/r19-repro.5GY9Zd`
template=`templates/module.ex.tera` rule=`module-scaffold`: template render
failed: Failed to render 'generation_rule::module-scaffold': Variable
`row.receipt` not found in context while rendering
'generation_rule::module-scaffold'
```

Fix: bind the variable with a triple pattern in WHERE —
`spl:receipt ?receipt ;` on the `?m` block. The real /tmp/ggen-split
`queries/extract.rq` carries the fixed shape: every SELECT variable appears
as a body object, `ORDER BY ?path` on the tail.

## Defect 2 — heredoc delimiter glued to {% endfor %}

When a loop renders shell-style heredoc blocks, gluing the delimiter to the
loop tag deletes the per-iteration newline: iteration 2 concatenates onto
iteration 1's delimiter line. Reproduced this session. Glued template tail
(`templates/emit.sh.tera`):

```text
SHEOF{% endfor %}
```

Rendered output with two rows — line 4 is the leak:

```text
cat >> out/installed.exs <<'SHEOF'
# FILE: lib/x.ex
# receipt=r6.md
SHEOFcat >> out/installed.exs <<'SHEOF'
# FILE: lib/y.ex
# receipt=r6.md
SHEOF
```

`SHEOFcat` means a bash heredoc never matches its line-start delimiter; the
rest of the file leaks into the heredoc as literal junk. Fix — newline
between the delimiter line and the tag:

```text
SHEOF
{% endfor %}
```

Post-fix proof from the same run matrix: `grep -c "SHEOFcat" out/emit.sh`
printed `0` (exit 0), and the rendered file carries one delimiter per
block. Template tail hygiene: every `{% ... %}` tag sits on its own line,
and the loop body's last emitted line ends with its own newline.

## The compile sweep

Render, split, compile:

```bash
cd /tmp/ggen-split
ggen sync run
# split all-modules.txt into tree/ (25 files, one per scaffold block), then:
mix compile
```

The real tree landed 25 scaffold files under `tree/lib/smalt/...` and the
session's compile sweep ran over them; `ebin/` holds the 25 compiled beams
(`Elixir.Smalt.ArmGateway.Engine.Lro.beam` through
`Elixir.Smalt.Policy.Assignments.beam` — `ls /tmp/ggen-split/ebin`).

## Related

- Landing the scaffolds into a live checkout:
  [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)
- Why the ontology carries gates and receipts:
  [ontology-first-decomposition](../explanation/ontology-first-decomposition.md)
- Template error classes:
  [tera-gotchas](../reference/tera-gotchas.md)
