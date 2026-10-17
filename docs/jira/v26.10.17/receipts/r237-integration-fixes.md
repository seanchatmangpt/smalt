# r237 — Integration fixes verification (bench-report empty window, ggen ledger sync, test_cosmos premise rewrite)

Standing: ALIVE

Verifies the three coordinator integration fixes landed and pass. Receipt-embedded
output is real command output from this session (2026-10-17).

## 1. `just bench-report` — exit 0 with v26.10.17 skipped note

```
$ just bench-report; echo "EXIT=$?"
[BENCH-REPORT] v26.10.17: no jsonl — skipped
[BENCH-REPORT] v26.10.14: 44 file(s), 103 rows -> /Users/sac/smalt/docs/jira/v26.10.14/BENCH_RESULTS.md
[BENCH-REPORT] v26.10.16: 8 file(s), 252 rows -> /Users/sac/smalt/docs/jira/v26.10.16/BENCH_RESULTS.md
EXIT=0
```

## 2. ggen manifest mcp stanza + receipts ledger

Manifest mcp stanza key is name=path (`template=>output`) form, no bare query field
remaining:

```
$ sed -n '111,119p' .ggen_igniter/manifest.json
    "lib/smalt/mcp/gen/mcp_descriptor.ex.eex=>lib/smalt/mcp/generated/mcp_descriptor.ex": {
      "out_template": "lib/smalt/mcp/gen/mcp_descriptor.ex.eex",
      "outputs": {
        "/Users/sac/smalt/lib/smalt/mcp/generated/mcp_descriptor.ex": "sha256:900c396b...fac47"
      },
      "pack_dir": null,
      "template": "lib/smalt/mcp/gen/mcp_descriptor.ex.eex",
      "updated_at": "2026-10-15T19:15:13.224703Z"
    }
```

Newest ledger entry in `.ggen_igniter/receipts/2026-10-17.jsonl` (227 lines) is not
refused:

```
$ tail -1 .ggen_igniter/receipts/2026-10-17.jsonl | python3 -c "...parse..."
alive unchanged rcpt_012a3c2565c53316 2026-10-17T21:56:14.943994Z
```

Newest `mcp_descriptor` entry:

```
standing: alive outcome: unchanged
recipe_key: lib/smalt/mcp/gen/mcp_descriptor.ex.eex=>lib/smalt/mcp/generated/mcp_descriptor.ex
```

## 3. smalt-cli cosmos pytest — 0 failures

Premise rewrite landed mid-poll. First observation (pre-landing) was
`1 failed, 7 passed` (`test_continuation_over_100_docs` → ServiceResponseError);
after the rewrite lane landed, three consecutive green runs:

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_cosmos.py -q -p no:cacheprovider
........                                                                 [100%]
8 passed in 20.89s
EXIT=0
```

(Additional consecutive green runs during the poll: `8 passed in 22.94s`,
`8 passed in 13.83s`, `8 passed in 19.74s`.)

## Verdict

All three integration fixes verified on real command output: bench-report exits 0
with the v26.10.17 skip note; ggen manifest mcp stanza is name=path form with newest
ledger entry `standing: alive`; test_cosmos 8/8 passed. Standing: ALIVE.
