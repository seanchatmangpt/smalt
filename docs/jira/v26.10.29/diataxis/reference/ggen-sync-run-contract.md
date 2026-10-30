# ggen-sync-run-contract

The verified contract of `ggen sync run` — flags, validation, paths,
output, errors. Everything here was executed against the installed ggen
this session (see [version-drift](version-drift.md) for which binary that
is).

## Flag surface

`ggen sync run --help`, ggen 26.10.11, exit 0, this session. Complete
option list (flag column verbatim; description column reflowed to fit the
100-char limit — wording unchanged):

```text
      --dry-run            Resolve and render but do not write any files
                           to disk; report what would change.
      --format <format>    Output format [possible values: json,
                           json-pretty, yaml, table, plain, tsv, quiet]
      --select <select>    Select/project nested JSON output using
                           JSONPath, key selection, or JMESPath query
                           projections
      --watch              Watch the filesystem and re-run the pipeline
                           automatically whenever a watched file changes.
      --consumer-mode      Suppress installer emission of outputs derived
                           from `fixtureOnly`-marked specs (OS-13 consumer
                           mode).
      --introspect         Introspect CLI capabilities as JSON Schema
                           array for LLM tool-calling
      --structured-errors  Output errors using StructuredError format
      --autonomic          Enable autonomic features and output
                           structured errors
  -h, --help               Print help
```

Notes:

- No `--manifest`, no `--rule` (see
  [point-ggen-at-a-manifest](../how-to/point-ggen-at-a-manifest.md) and
  [run-a-single-rule](../how-to/run-a-single-rule.md)).
- `--consumer-mode` exists on 26.10.11 but is absent from the flag list in
  `~/.claude/skills/run-ggen/SKILL.md` (written against 26.8.18) — a live
  version-drift data point.

## Validation-time errors (before the pipeline runs)

- `error[E0013]` "SELECT query lacks ORDER BY" — strict_mode (default on)
  rejects a SELECT without ORDER BY at config validation.
  Reproduced this session, exit 1.
- `[FM-CONFIG-003]` — ggen.toml failed to parse or validate; the nested
  error is specific (missing ORDER BY, bad path). Per SKILL.md; the
  `[FM-CONFIG-001]` variant (ggen.toml not found at cwd) reproduced this
  session, exit 1.
- `[FM-WRITE-002]` — a resolved output path carries a `..` traversal
  component. Reproduced this session, exit 1; quote below.

## Render-time errors

- `[FM-GEN-008][TEMPLATE_VARIABLE_MISSING]` — template reads a row field
  whose SPARQL variable is projected but never bound in the WHERE body.
  Reproduced this session, exit 1, no file written; fix in defect 1 of
  [bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md).

The `[FM-WRITE-002]` quote, verbatim stderr (one logical line, wrapped
here at 100 chars):

```text
ERROR: CLI execution failed: Command execution failed: validation error:
[FM-WRITE-002] `to:` path "../all-modules.txt" contains a traversal
component; it must stay inside the project root
```

The fix pattern (bind the variable in WHERE) is defect 1 in
[bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md).

## Path resolution

- `output_dir` and each rule's `output_file` resolve relative to
  `ggen.toml`'s directory (always the cwd).
- `..` components are rejected (`[FM-WRITE-002]`, above).
- Keep the whole tree under one directory you `cd` into.

## Success output

Exit 0. stdout carries a JSON summary; human-readable progress goes through
`tracing` on stderr. Real summary from /tmp/ggen-split (run.json; the four
64-hex hashes abridged to `head…tail` to fit the line limit — full values
in /tmp/ggen-split/run.json):

```json
{
  "closure": {
    "actuator": "ggen@26.10.11",
    "ontology/split.ttl": "4d22e3c7…3fd4",
    "queries/extract.rq": "3fed0836…22ab",
    "templates/module.ex.tera": "c6f630a4…2000"
  },
  "decisions": { "out/all-modules.txt": "written" },
  "graph_hash_hex": "c111413b…9ac8",
  "packs": {},
  "skipped": [],
  "written": [ "out/all-modules.txt" ]
}
```

Fields: `written` / `skipped` (file lists), `decisions` (per-file
written/skipped), `graph_hash_hex` (graph content hash), `closure` (a
content hash per input file plus the actuator version). Parse JSON, not
the tracing lines.

Stderr tracing lines look like (stage line from the same run, reflowed at
100 chars; wording verbatim):

```text
INFO ggen.cli{command=sync run version="26.10.11"}:pipeline.emit{
operation.name="pipeline.emit" ... pipeline.files_generated=1}:
ggen_engine::generation_rules: close time.busy=337µs time.idle=1.28ms
```

— stage timings (`load`, `extract`, `validate`, `generate`, `emit`), not
result data.

## Related

- [tera-gotchas](tera-gotchas.md)
- [version-drift](version-drift.md)
