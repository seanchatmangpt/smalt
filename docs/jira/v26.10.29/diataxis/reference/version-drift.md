# version-drift

Three ggen identities disagree on version. What is pinned where, what was
verified this session, and the discipline for citing any of them.

## The three identities (re-read this session, 2026-10-29)

- **Installed binary** (`~/.local/bin/ggen`): self-reports
  `ggen 26.10.11` — `ggen --version`, exit 0, this session.
- **Skill pin** (`run-ggen/SKILL.md`): states `26.8.18` — SKILL.md
  header, "real version 26.8.18 as of this writing".
- **`~/ggen` source checkout**: `version = "26.10.12"` —
  `grep '^version' ~/ggen/Cargo.toml`, line 2, read this session.

Note the drift moved since SKILL.md was written: it records installed
26.8.18 vs source 26.8.12; today the same probe reads installed 26.10.11
vs source 26.10.12. The skill's numbers are as-of-its-writing, not a
standing claim.

## Same flag surface this session

The three identities' shared contract held for everything this guide
exercises: `ggen sync run --help` on the installed 26.10.11 returned the
flag surface in [the sync-run contract](ggen-sync-run-contract.md), and
every live run in this guide (E0013, TEMPLATE_VARIABLE_MISSING,
FM-WRITE-002, the two-row render, the /tmp/ggen-split render recorded in
run.json with `"actuator": "ggen@26.10.11"`) executed on that binary.

One surface delta vs the skill text: `--consumer-mode` exists on 26.10.11
and is absent from SKILL.md's flag list.

## Discipline

1. Treat the installed binary as ground truth for what WILL run; treat
   `~/ggen` source as one candidate future; treat skill/receipt claims as
   as-of-date.
2. Re-verify per version: `ggen --version` + `ggen sync run --help`
   before citing a flag or error code in a durable doc. This guide's
   contract page carries its verification date and binary version for
   exactly this reason.
3. Receipt-cited counts and versions are re-read at use time (the same
   law as receipt-cited counts in
   [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)).

## Related

- [the sync-run contract](ggen-sync-run-contract.md)
- [smalt-generation-pipeline](smalt-generation-pipeline.md)
