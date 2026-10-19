# mod-r10: ratchet mod DOCS + INSTALL lane

Standing: PASS (with two disclosed seam fixes outside the named lease)
Context: solo(install-path verification + node -e gate smoke + node turn.js self-check)
Scope: README + CLAUDE.md bullet (lease); install-path verification.

## Deliverables

- `/Users/sac/smalt/mods/ratchet/README.md` — NEW. Grounded in the landed
  sources (register.js, turn.js, gate.js, state.js x2): 20-agent ratchet
  (default capacity 20), panel, auto-execute (timer tick, 5-min dedup,
  zero sleeps), court gate (DONE is receipt-gated; PreToolUse deny gate for
  generated artifacts / force-push / `rm -rf /`), install (marketplace +
  `--plugin-dir`), `/ratchet` command surface, three-surface state file
  contract, honest boundary (interactive-session injection, WSL hook gap,
  terminal/Desktop/VSCode-only panel).
- `/Users/sac/smalt/CLAUDE.md` — one bullet added to Conventions (after the
  no-sleep doctrine bullet) pointing at the mod + `/ratchet` + README path.

## Verification (real output)

1. `claude plugin validate /Users/sac/smalt/mods/ratchet` →

```
Validating plugin manifest: /Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json

⚠ Found 1 warning:

  ❯ author: No author information provided. Consider adding author details for plugin attribution

✔ Validation passed with warnings
```
   exit=0. Only warning is missing `author` attribution.

2. `claude plugin marketplace add /Users/sac/smalt/mods` — FIRST RUN
   FAILED (exit 1, `Marketplace file not found at
   /Users/sac/smalt/mods/.claude-plugin/marketplace.json`). Fixed by
   creating `/Users/sac/smalt/mods/.claude-plugin/marketplace.json`
   (name `smalt-mods`, one plugin entry: ratchet, source `./ratchet`).
   SECOND RUN:

```
Adding marketplace…✔ Successfully added marketplace: smalt-mods (declared in user settings)
```
   exit=0; `claude plugin marketplace list` shows `smalt-mods`,
   Source: Directory (/Users/sac/smalt/mods). `/plugin install
   ratchet@smalt-mods` is an interactive REPL command, not verifiable from
   a non-interactive shell — documented as the install step; the
   marketplace registration itself is receipted above.

3. Gate smoke (after seam fix below), `node -e` against `gate.js`:

```
deny force-push: {"ok":false,"reason":"blocked: force-push to main"}
allow normal   : {"ok":true,"reason":null}
deny generated : {"ok":false,"reason":"blocked: hand-edit of generated artifact docs/ERROR_CODES.md"}
```

4. `node mods/ratchet/hooks/turn.js` self-check → `selftest ok — state at
   /Users/sac/smalt/mods/ratchet/state.json`; scratch state file removed
   after the self-check.

## Compile-freeze SLA disclosures (outside lease, minimal unblock fixes)

1. `/Users/sac/smalt/mods/ratchet/hooks/lib/gate.js:35` — referenced
   undefined variable `regex` (`regex.lastIndex = 0`), so every Bash-gate
   call threw ReferenceError instead of evaluating; the deny gate was
   fail-open. Minimal fix: `p.re.lastIndex = 0;`. This belongs to the
   gate-lane owner; per SLA it is named here for cross-lane attribution.
   Post-fix smoke in Verification item 3 proves deny/allow both route.
2. `/Users/sac/smalt/mods/.claude-plugin/marketplace.json` — did not exist;
   the documented `marketplace add` install path hard-failed without it.
   Created the minimal manifest (above).

## Boundary

- Not done here: `/plugin install ratchet@smalt-mods` (interactive-only),
  hooks.json Register wiring test (needs a live interactive session —
  honest boundary documented in README).
- No git operations (per lease).
