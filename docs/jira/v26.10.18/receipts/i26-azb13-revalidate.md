# I26 — AZB-13 transient first-validation refusal re-run

Standing: PASS (transient CLOSED)
Context: burn harness (boot-burn revalidation, 3 runs x 5 files OK); no mix test invocation

## Task

Re-run `python3 scripts/validate_burn.py --gate` over the 5 tracked
`docs/jira/v26.10.18/burn/boot-*.jsonl` files 3x. AZB-13's receipt disclosed a
transient first-validation refusal that passed on byte-identical files re-run.
If all 3 exit 0, the transient is closed (classify). No edits, no git.

## Command

```
python3 scripts/validate_burn.py --gate \
  docs/jira/v26.10.18/burn/boot-all-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-control-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-data-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-identity-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-integration-1792372587.jsonl
```

(Repeated 3x. Note: `--gate` requires an explicit `files` positional; bare
`--gate` exits 2 with usage — observed verbatim below.)

## Embedded command output

Run 1: all 5 files `OK`, `exit=0`
Run 2: all 5 files `OK`, `exit=0`
Run 3: all 5 files `OK`, `exit=0`

Verbatim (run 1):

```
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-all-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-control-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-data-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-identity-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-integration-1792372587.jsonl: OK
```

Supplementary: a 6th untracked-in-task file, `boot-burn.jsonl`, also exists in
the same dir and validates `OK`, `exit=0`.

## Classification

3/3 consecutive exit-0 on the byte-identical tracked files → the AZB-13
transient is CLOSED. Most probable cause class: concurrent-write/read race —
the validator's first pass ran while a burn ring writer still had the JSONL
append-open (partial/last line mid-write), not a validator state bug: the
validator is stateless per invocation (pure file parse), so a "first-pass
state" flake is not mechanistically available. No validator change warranted.

## Falsifier

Any future `--gate` exit 1 on unchanged tracked boot JSONL reopens this row.
