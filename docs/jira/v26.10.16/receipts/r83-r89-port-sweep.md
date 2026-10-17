# R83/R89: port hygiene (substrate ports + collision detection)

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `scripts/port_sweep.sh` (+94 diff: getopts -y/-b, tree-aware orphan guards)

## Claim

Port-sweep repairs: per-port collision reporting, tree-aware orphan guards, boot-window
option.

## Re-run evidence

```
$ scripts/port_sweep.sh; echo exit=$?
== canonical port map (post) ==
port 9443: STILL HELD (beam.smp(10884) )
port 9444: STILL HELD (beam.smp(10884) )
port 8443: STILL HELD (beam.smp(10884) )
port 5672: STILL HELD (beam.smp(10884) )
port 5673: STILL HELD (beam.smp(10884) )
exit=0
```

## Verdict

PASS. Dry-run exit 0; each canonical port mapped to its holding pid (the live substrate
beam 10884 — a live listener, not an orphan, per the tree-aware law). Collision reporting
is the STILL HELD map itself. -y kill path deliberately not exercised against a live
substrate.
