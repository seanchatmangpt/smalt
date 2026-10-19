# i29: mods/ratchet test suite + plugin validation (receipt i29-mod-tests)
Context: solo(mods/ratchet plugin test suite + claude plugin validate)

- Date: 2026-10-18
- Lane: bench-runner (solo, no edits, no git)
- Subject: `/Users/sac/smalt/mods/ratchet` (plugin: `.claude-plugin/plugin.json`)

## Command + output

```
$ node --test mods/ratchet/test/
ℹ tests 29
ℹ pass 29
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 876.973041
exit=0
```

```
$ claude plugin validate mods/ratchet
Validating plugin manifest: /Users/sac/smalt/smalt/mods/ratchet/.claude-plugin/plugin.json
✔ Validation passed
exit=0
```

Note: validator echoed the path with a doubled `smalt` segment; resolve to
`/Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json` (same manifest, exit 0).

Only one test dir exists under `mods/` (`mods/ratchet/test`) — the integration
lane's suite and R8's suite already co-exist in that single directory; both
covered by the one run. 29/29 matches expected count.

## Machine

```
$ just bench-machine
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Standing

PASS — 29/29 node tests, plugin manifest validation passed, zero errors,
zero skips. No files modified; no git operations.
