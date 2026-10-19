# mod-r9 — ratchet INTEGRATION lane: final hooks.json + register.js

Standing: ALIVE
Subject: /Users/sac/smalt/mods/ratchet (canonical checkout, single writer = R9 integration lane)
Authority: mod-ratchets WO, hooks/hooks.json + hooks/register.js final form
Falsifier: `claude plugin validate` non-zero, or any node --test failure, or a lib seam
without a register* wiring line.

## Context: upstream lane state (important correction)

The task referenced receipts mod-r3 / mod-r5 / mod-r7 and an R1 skeleton. On disk at
integration time:

- `docs/jira/v26.10.18/receipts/` contains **no mod-r\* receipts** (verified `ls | grep mod` → empty).
- `mods/ratchet/` contained only `.claude-plugin/plugin.json` and
  `hooks/hooks.json` (the Register bootstrap, kept byte-for-byte).

Import-conflict resolution was therefore moot: there were no multiple panel
implementations to arbitrate — the lib/ modules (state, panel, inject, gate, commands)
did not exist and were authored directly in final form by this lane. **One winner per
seam** is structural: each seam has exactly one module, and register.js wires exactly
one handler per seam via the collector api (asserted by test 2).

## Wiring map (final form)

| Seam | Source lane (per WO) | lib module | register* fn | Emitted hook |
|---|---|---|---|---|
| timer (R1) | R1 | lib/inject.js `tick()` | `registerTurn` (2nd handler) | lazy tick, evaluated on panel/turn — no native timer hook exists; staleness > 15 min injects once |
| panel ui.render (R3) | R3 | lib/panel.js `render()` | `registerPanel` | UserPromptSubmit + SessionStart → `run.js panel` |
| turn.complete (R5) | R5 | lib/inject.js `turnComplete()` | `registerTurn` | PostToolUse (matcher `ExitPlanMode\|Task`) + SessionEnd → `run.js turn` |
| gate tool.call (R7) | R7 | lib/gate.js `gate()` | `registerGate` | PreToolUse (matcher `Bash\|Edit\|Write`) → `run.js gate` |
| commands | — | lib/commands.js | `registerCommands` | `ratchet:status` / `ratchet:reset` (dispatched via `run.js commands`) |

Gate law (real, repo-derived): denies `rm -rf /`, force-push to main, and Edit/Write of
generated artifacts (`docs/ERROR_CODES.md`, `docs/jira/v*/RECEIPTS.md`,
`receipts/INDEX.md`, `BENCH_RESULTS.md`, `SDK_MATRIX.md`); ordinary commands allow
silently. Blocks ratchet the shared state file (`state.record`, level+blocks counters).

Files landed (all `node --check` OK):
`hooks/hooks.json` (pre-existing, unchanged) · `hooks/register.js` · `hooks/run.js` ·
`hooks/lib/{state,panel,inject,gate,commands}.js` · `test/suite.test.js` ·
`.claude-plugin/plugin.json` (+author field, clears the only validate warning). No git.

## Gate 1 — node --check all files

```
OK hooks/register.js
OK hooks/run.js
OK hooks/lib/state.js
OK hooks/lib/panel.js
OK hooks/lib/inject.js
OK hooks/lib/gate.js
OK hooks/lib/commands.js
OK test/suite.test.js
```

## Gate 2 — node --test (real output)

```
ratchet/run.js: unknown kind 'nope'
✔ register.js emits valid hooks config with all four seams wired (85.721916ms)
✔ register.js wiring collector holds handlers from all four register* fns (2.107958ms)
✔ gate blocks rm -rf / via run.js gate kind (deny JSON emitted) (99.540584ms)
✔ gate allows an ordinary bash command (silent allow, no stdout) (82.414041ms)
✔ gate blocks hand-edit of a generated artifact path (81.970584ms)
✔ turn kind records a turn-complete event (81.772417ms)
✔ panel kind emits additionalContext with ratchet line (81.087916ms)
✔ commands dispatch: status renders, reset clears, unknown refused (247.302167ms)
ℹ tests 8
ℹ pass 8
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 870.886708
```

(the `unknown kind 'nope'` line is the loud stderr of the negative-path test — expected)

## Gate 3 — claude plugin validate

First run (before adding author):

```
Validating plugin manifest: /Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json

⚠ Found 1 warning:

  ❯ author: No author information provided. Consider adding author details for plugin attribution

✔ Validation passed with warnings
exit=0
```

Final run (after adding `author.name` to plugin.json):

```
Validating plugin manifest: /Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json

✔ Validation passed
exit=0
```

Note: this claude build's validator checks the manifest only — it emits no `hooks:` /
`calls:` lines in its output. The hooks-config proof is Gate 4 (register.js emission)
plus hooks.json's Register bootstrap, which loads register.js at session start.

## Gate 4 — register.js emitted hooks config (head)

```
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
          "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/run.js\" panel" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash|Edit|Write",
        "hooks": [ { "type": "command",
          "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/run.js\" gate" } ] }
    ],
    "PostToolUse": [
      { "matcher": "ExitPlanMode|Task",
        "hooks": [ { "type": "command",
          "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/run.js\" turn" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command",
          "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/run.js\" panel" } ] }
    ],
    ...
```

## Verification ladder

1. static: node --check 8/8 OK (Gate 1)
2. unit/e2e: node --test 8 pass / 0 fail (Gate 2) — Chicago: real subprocess
   execFileSync through run.js, real state file asserts, zero mocks
3. plugin surface: claude plugin validate exit 0, zero warnings (Gate 3)

Falsifier did not fire. Standing: ALIVE.
