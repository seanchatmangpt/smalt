# BK-127 — SPOF-B receipt reconcile (supervisor-race addendum + court re-run)

**Standing:** **ALIVE** (spofb court 7/7 green on current tree; standing line of
`spofb-eh-atom-fixes.md` confirmed stale and closed out via dated addendum)
Repo: `/Users/sac/smalt` · branch `main` · Context: solo · Build root `MIX_BUILD_ROOT=_build-bk127`

## Findings

1. `docs/jira/v26.10.22/receipts/spofb-eh-atom-fixes.md` (committed `588bd36`)
   does NOT mention the supervisor-race class: its A-2 description presents
   the whereis-gated lazy `GenServer.start` fallback as the degraded
   ordering fallback without noting it races the supervisor's restart of the
   killed permanent child (`:already_started` loop → IntegrationSupervisor
   intensity exhaustion → `:shutdown` app death — the mechanism behind the
   receipt's "5/8 full-suite" flake attribution).
2. The race was found and fixed by the BK-104 lane (lazy start routed through
   `Supervisor.start_child(IntegrationSupervisor, child_spec)` in
   `event_hubs.ex` + `eh_geo_dr.ex`).
   `docs/jira/v26.10.22/receipts/bk104-eh-atom-heirs.md` is the closing
   authority.

## Action taken

- Appended a dated "Addendum (2026-10-22, BK-127 reconcile)" section to
  `spofb-eh-atom-fixes.md` citing bk104-eh-atom-heirs.md as the closing
  authority for the race class. Original receipt content preserved unchanged.
- No `lib/` edits; no commit made by this lane.

## Verification (real output, current tree)

```
$ MIX_BUILD_ROOT=_build-bk127 asdf exec mix test test/internal/spofb_eh_atom_court_test.exs
Running ExUnit with seed: 791681, max_cases: 32
.......
Finished in 1.5 seconds (0.00s async, 1.5s sync)
Result: 7 passed        # exit 0
```

One full-suite run, green on the first try (post-bk104-fix tree) — consistent
with the bk104 receipt's 7/7 ×8 consecutive post-fix record; the pre-fix
~50% app-death flake did not reproduce.
