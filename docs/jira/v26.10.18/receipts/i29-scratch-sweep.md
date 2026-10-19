# i29 scratch sweep — edit_atom_bridge.py / edit_test.py

Context: solo

Date: 2026-10-18 · Context: solo · Standing: PASS (no-op disposition)

## Finding

The two reported files are **not at the repo root**. Full-tree search
(`find . -name "edit_atom_bridge.py" -o -name "edit_test.py"` excluding
node_modules/_build/.git) returned zero hits inside
`/Users/sac/smalt`; they live at:

- `/tmp/edit_atom_bridge.py`
- `/tmp/edit_test.py`

Both are one-shot lane scratch edit scripts targeting repo paths:

- `/tmp/edit_atom_bridge.py` → writes
  `lib/smalt/messaging/amqp/atom_bridge.ex` (i29 :closed silent clause +
  `rate_limited_reason/1` once-rate-limited debug aggregation).
- `/tmp/edit_test.py` → writes `test/amqp/atom_bridge_test.exs`
  (flood-silence test + rate-limit aggregation test).

## Reference check

`grep -rn "edit_atom_bridge\|edit_test" --include=*.sh --include=*.just
--include=*.md` → zero real references. All hits were substring matches of
`credit_test` (e.g. `flow_credit_test.exs`) — spurious. Not tracked by git
(outside the tree), referenced by no committed script.

## Diagnostics verdict

- `edit_atom_bridge.py:1` — `import io, sys` unused: **confirmed**, but
  harmless in an already-applied scratch script; not referenced by anything,
  so fixing it has zero consumers. Left as-is.
- `edit_test.py:87` "invalid str.replace overload": **stale/spurious**. The
  file is 81 lines; the only `replace` call (line 79,
  `src.replace(marker, new_tests, 1)`) is a valid three-arg `str.replace`.
  Both files parse clean under `python3 -m ast`:

```
$ python3 -c "import ast; ast.parse(open('/tmp/edit_atom_bridge.py').read()); ast.parse(open('/tmp/edit_test.py').read()); print('both parse OK')"
both parse OK
```

## Disposition

No repo change. The scripts' edits are **already applied** to the working
tree (verified by grep, not memory):

```
$ grep -c "rate_limited_reason\|amqp_atom_rate_limit" lib/smalt/messaging/amqp/atom_bridge.ex
2
$ grep -c "flood of closed mid-request connections is silent\|non-terminal read faults log once per window" test/amqp/atom_bridge_test.exs
2
```

Both targets already appear as modified in `git status`, matching this lane's
in-flight i29 work (`lib/smalt/messaging/amqp/atom_bridge.ex`,
`test/amqp/event_hubs_test.exs`). Per the task's own alternatives
(.gitignore section OR move to tmp/), the files are already in tmp/ — the
move-to-tmp/ disposition is satisfied; .gitignore needs no entry since /tmp
is outside the repo. Deleted nothing (a cleanup of /tmp scratch is the
owner's call; these carry the i29 edit history).

## Standing

PASS — scratch located, confirmed unreferenced, confirmed already-applied,
no repo mutation required. No errors, no skips.
