# Receipt — V261019-14 (boot-library)

Context: solo(V261019-14) — all commands below executed by this lane, 2026-10-19 ~10:09 PDT.
Standing: **ALIVE** — the boot library exists, is syntax-clean, and its CLI
answers a real read-only status query with a typed record; outputs below
are this session's.
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- `scripts/lib/substrate_boot.sh` — ONE shared substrate-boot library,
  generalizing the per-harness boot machinery that six+ harnesses each
  embedded privately (the deleted `ts-run.mjs` boot block, snapshot at
  `docs/jira/v26.10.19/lifts/ts-run.mjs`; the smalt-cli conftest identity
  guard, snapshot at `docs/jira/v26.10.19/lifts/conftest.py`).
- `scripts/substrate-ctl` — the CLI front door over the library.
- Laws encoded (per the library header, read this session): fd-9 law
  (children spawned `9>&-`, post-spawn lsof assert that no descendant holds
  the lock fd — closes the witnessed 27-min flock→mix→beam starvation
  channel); two-tier locking (front door `/tmp/smalt-substrate.lock` +
  per-block locks); marker-based identity reuse (marker present AND age
  <= 3600s AND marker pid in the LISTEN set AND auth matches — never adopt
  on faith); no-sleep health (bounded 250 ms poll on port accept + HTTP 200
  on ARM `/metadata/endpoints`); JSON receipt as the last stdout line of a
  successful up (`{block,ports,pid,reused,marker,auth}`); typed exit
  contract 0/1/2/3/64.
- No `lib/` edits by this lane.

## Verification (real output tails)

```
$ bash -n scripts/lib/substrate_boot.sh && echo "substrate_boot.sh syntax OK"
substrate_boot.sh syntax OK
$ bash -n scripts/substrate-ctl && echo "substrate-ctl syntax OK"
substrate-ctl syntax OK
```

```
$ scripts/substrate-ctl status --block b1
block=b1 ports=39010 39011 39012 39013 39014 39015 up=0 identity_verified=0 pid=none health=ERR
exit=0
```

(`up=0` is the honest cold answer: nothing is booted for block b1 on this
machine right now; the CLI answered with a typed record rather than a
fabricated up-state.)

```
$ python3 scripts/non_duplication_gate.py
[PASS] non-duplication gate: 6 file(s) clean
exit=0
```

(Adjacent governance over the consumers of this library — the residual
tier — is green this session.)

## Acceptance greps

- `grep -rn "SmaltTest.Lifecycle" test/ -l` => 0 matches (legacy module
  deleted with the old suite; the library is its successor — census in
  V261019-07). Migration of remaining harness boot sites is the suites'
  (V261019-08/09) close condition.
- `git diff --stat lib/` — not run by this lane; this lane has zero `lib/`
  edits.

## Deviations

1. Skeleton anticipated an Elixir module successor to
   `SmaltTest.Lifecycle`; the landed library is bash
   (`scripts/lib/substrate_boot.sh` + `scripts/substrate-ctl`) per the
   clean-room reset design. A full `up` cycle was not executed by this
   lane (substrate boot is a consequential serialized transition owned by
   substrate-op); status + syntax + law-census are this receipt's executed
   surface.
