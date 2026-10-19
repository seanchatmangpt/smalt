# i29 — Canonical projection regen-verify (capabilities.json + THIRD_PARTY.md)

- **Standing**: PASS (byte-fresh)
Context: solo (residual verify lane; no other lane writes these two files)
- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ main (no git transitions; files rewritten in place)

## Method

`lib/smalt/projection/canonical.ex` exposes no check/dry-run form — only
`Smalt.Projection.Canonical.write/0` (unconditional `File.write!` of both
docs). So the sanctioned regen-compare path was used:

1. sha256 snapshot of both files → `/tmp/canon-before.txt`
2. regen
3. re-hash → compare

## Attempt log (why 3 runs)

1. `mix run -e 'Smalt.Projection.Canonical.write()'` — FAILED, no write.
   App boot aborted: `{Bandit, ...} :eaddrinuse` (default ports held by
   other lanes' beams on this shared checkout). The trailing
   "BYTE-IDENTICAL" printed after this attempt was **vacuous** — write
   never executed (file mtimes proved it: unchanged).
2. `MIX_ENV=test mix run -e ...` — also FAILED silently past `tail -5`
   (Smalt.Store `already started` — collision with concurrent lane beams
   sharing DETS/store paths). mtime check exposed it.
3. `MIX_ENV=test mix run --no-start -e 'IO.inspect(Smalt.Projection.Canonical.write())'`
   — SUCCESS. `write_result: {:ok, [docs/capabilities.json, docs/THIRD_PARTY.md]}`,
   exit 0, mtimes advanced to run time.

`--no-start` is lawful here: write/0 is a pure projection over the
compile-time registry + mix.exs deps; no listener/store needed.

## Verdict evidence

Before (step 1 snapshot) vs after (step 3 regen):

```
ed638180b3baba433c5a9dbf463834fc5d2f13b9be556e11562b0dfdaba254a7  docs/capabilities.json
a890e1f0eca1f44a7f74483c94a5ee7db2bb111dc895c745ef37edb59a336e71  docs/THIRD_PARTY.md
```

Both pre- and post-regen hashes identical, byte-for-byte.

**PASS** — tree was fresh; regen replay is byte-identical for both
`docs/capabilities.json` and `docs/THIRD_PARTY.md`.

## Notes for follow-ups

- Any headless regen/verify of these projections under concurrent lanes
  must use `mix run --no-start`; a plain `mix run -e` both collides on
  ports and can fail invisibly behind `tail`/pipes.
- Closes the i26 residual.
