# DRAFT — ready-to-apply edit for docs/jira/v26.10.16/PUBLISH_RECORD.md (B1 → CLOSED)

> Do not apply until the receipt r244 evidence block is filled with real
> command output (`receipts/r244-publish-record.md`). No receipt, no flip.

## Edit 1 — header Standing line (replace lines 3-5)

OLD:

```
- **Standing**: **PUBLISH-READY: NO — TYPED-BLOCKED** (updated 2026-10-17: **B1 only** —
  ex4pm hex auth, operator action; package built + checksum on record. B2 FIXED by lane
  G2's landed guard; B4 FIXED; B5/B6 advisory; gates green; remediation = NEXT_WINDOW §13)
```

NEW:

```
- **Standing**: **PUBLISH-READY: YES (B1 CLOSED 2026-10-17)** — see the B1 closure
  addendum below and the witness receipt
  `docs/jira/v26.10.17/receipts/r244-publish-record.md`. B2 FIXED (lane G2 guard);
  B4 FIXED (T5); B3/B5/B6 advisory with dispositions on record; gates green.
```

## Edit 2 — B1 section: append the closure addendum (end of the B1 section,
## immediately after the `cross-ref` bullet, before `### B2`)

```markdown
- **CLOSED (2026-10-17, addendum — witness receipt
  `docs/jira/v26.10.17/receipts/r244-publish-record.md`)**. The close condition
  read: "ex4pm published to hex with a version satisfying smalt's pin; smalt
  `mix.exs` carries the hex pin; `mix hex.build` on the smalt subject exits 0."
  All three legs witnessed:

  1. **ex4pm 26.10.8 published to hex.pm** (operator action,
     `cd ~/ex4pm && mix hex.publish`). Evidence: `mix hex.info ex4pm 26.10.8`
     (or `mix deps.update ex4pm` resolving from `:hexpm`) — output embedded in
     r244.
  2. **smalt `mix.exs` hex pin flipped** (d-date 2026-10-17):
     `{:ex4pm, "~> 26.10.8", override: true}` now stands as the active pin
     (former `path: "../ex4pm"` line retired; the B1 activation comment block
     above it updated to past tense). `mix.lock` resolves
     `ex4pm 26.10.8` from `:hexpm`,
     checksum `7fdffeab74851d2e226c24bb3898ce6480c07184a38c5e600bbc7e28e2346c60`.
  3. **`mix hex.build` green on the smalt subject**: exit 0, no
     HEX_BUILD_REFUSED. Output embedded in r244 (build the dry-run command per
     the receipt template; record version/licenses/checksum line and the
     requirements block showing `ex4pm ~> 26.10.8` as a hex requirement).

  Note on checksums: ex4pm's own package checksum at G1 dry-build was
  `038d538135c9bfe5a9ac266ed5a87780dbe56ce91eb1a7cb188e1833726b9564`
  (468 files, zero plts/_build/deps leakage — lane G1); the hex-published
  26.10.8 tarball smalt resolves is `7fdffeab…` (mix.lock above). Any delta
  between the two is the publish-time metadata diff and is dispositioned in
  r244.
```

## Edit 3 — "Final verdict" section: replace the standing sentence

OLD:

```
**v26.10.16 hex.publish = TYPED-BLOCKED (B1 only).**
```

NEW:

```
**v26.10.16 hex.publish = PUBLISH-READY (B1 CLOSED 2026-10-17; B3/B5/B6 advisory).**
```

and append after the "B1 is the sole publish gate" bullet:

```markdown
- **2026-10-17 addendum**: B1 closed — ex4pm 26.10.8 is live on hex.pm; smalt
  `mix.exs` carries the hex dual-pin
  (`{:ex4pm, "~> 26.10.8", override: true}`, d-date 2026-10-17); `mix hex.build`
  exits 0 on the smalt subject (HEX_BUILD_REFUSED absent). Witness:
  `docs/jira/v26.10.17/receipts/r244-publish-record.md`.
```

## Edit 4 — "NEXT_WINDOW close conditions" list, item 1: strike

OLD:

```
1. ex4pm → hex publish, then smalt dual-pin (B1) — owned by ex4pm repo (**sole
   remaining refusal-class blocker**)
```

NEW:

```
1. ~~ex4pm → hex publish, then smalt dual-pin (B1) — owned by ex4pm repo (**sole
   remaining refusal-class blocker**)~~ — **DONE (2026-10-17)**: ex4pm 26.10.8 on
   hex.pm; smalt hex pin flipped; `mix hex.build` exit 0. Witness:
   `docs/jira/v26.10.17/receipts/r244-publish-record.md`.
```

## Edit 5 — "Receipt" section standing sentence

OLD (last line):

```
Standing: **PUBLISH-READY: NO — TYPED-BLOCKED on B1 only** (ex4pm hex auth, operator
action; package built + checksum on record). B2 closed with re-run evidence; B4 closed
at T5; B5/B6 advisory; gates green.
```

NEW (append after it, do not rewrite history):

```markdown
**2026-10-17 B1-closure addendum standing: PUBLISH-READY (B1 CLOSED)** — ex4pm
26.10.8 hex publish + smalt dual-pin (d-date 2026-10-17) + `mix hex.build` exit 0,
witnessed in `docs/jira/v26.10.17/receipts/r244-publish-record.md`. Applied only
after r244 carries real embedded output.
```

## Companion edits outside PUBLISH_RECORD.md (same flip, same gate)

- `docs/jira/v26.10.16/NEXT_WINDOW.md` §3 item 2 (release-gate carry
  "ex4pm hex auth + dual-pin flip (publish B1/B2)"): strike DONE — text in
  `docs/jira/v26.10.17/NEXT_WINDOW-3.2-item10-strike.draft.md`.
- `docs/jira/v26.10.17/RELEASABLE.md` gate 3 row and
  `docs/jira/v26.10.17/FINAL.md` top bullet: TYPED-BLOCKED → closed-per-r244
  (apply after r244 is filled; keep the version-bump block honest — gate 2 is
  still blocked on gate 1 and is NOT closed by B1).
