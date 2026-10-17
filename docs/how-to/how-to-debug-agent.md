# how to debug with an agent under fix mode

Debug ritual: the failing test is the witness — it gets committed (frozen), not
edited. While fix mode is active, `scripts/test_freeze_gate.sh` refuses any
working diff that touches `test/`. Adapted from the Anthropic
"deterministic freeze" pattern: an agent cannot silently mutate the assertion
that proves its fix.

## The ritual

```bash
just fix-start test/telemetry_test.exs:42   # freeze the witness
# fix lib/ freely; preflight refuses test/ edits
git add lib/... && git commit -F <msg-file>  # commit fix + witness together
just fix-end                                 # lift freeze, restore 0644
```

- `fix-start` writes marker `.smalt/fix-mode` (0444), chmods the named test
  file 0444, records it in `.smalt/fix-mode-tests`.
- `fix-end` restores 0644 and removes marker + ledger.
- `just preflight` = doctor + freeze gate; it is the portable in-repo
  enforcement (works on any machine, any runtime, no hooks).

## What the gate allows

Under `SMALT_FIX_MODE=1` (or the marker file), the working diff (staged +
unstaged + untracked under `test/`) may only touch `lib/ scripts/ priv/
config/`. `--json` emits `{"fix_mode_active", "violations", "marker"}` for the
doctor check.

## Claude Code agents (hooks, optional parity layer)

In-repo gate is the portable mechanism. If you also want the same enforcement
at the harness layer for Claude Code agents, add a PreToolUse hook matching
Edit/Write on `test/` that runs the gate when the marker exists and denies the
call — e.g. in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'if [ -f .smalt/fix-mode ]; then bash scripts/test_freeze_gate.sh ||
            echo \"deny: TEST_FREEZE_VIOLATION\" >&2; exit 2; fi'"
          }
        ]
      }
    ]
  }
}
```

The in-repo gate (`just preflight`) remains the enforcement of record; the
hook is parity convenience, not authority (hooks = intent, never authority).

## See Also

- `scripts/test_freeze_gate.sh`
- `justfile.d/22-native.just` (`fix-start` / `fix-end` / `preflight`)
