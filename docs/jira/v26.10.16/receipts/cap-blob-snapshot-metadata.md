# Receipt: cap-blob-snapshot-metadata (KD-60 witness material)

**Standing**: PASS (witness material only — KD-60 register flip stays kd_flip-gated)
**Window**: v26.10.16, lane 524 (blob snapshot surface)
**Date**: 2026-10-16

## Scope

KD-60 wire registration for the Blob snapshot + metadata surface, three arms in
`lib/smalt/egress_router.ex`:

1. **PUT `?comp=snapshot`** — answers `201` with the `x-ms-snapshot` timestamp
   header. Legal hold / locked policy blocks the create arm with `409
   ContainerLocked` (create-arm convention, same as KD-52's engine arm).
2. **GET `?comp=metadata`** — `200` empty body echoing the stored `x-ms-meta-*`
   headers written by PUT `?comp=metadata`, plus `etag` / `x-ms-request-id` /
   `x-ms-version`.
3. **GET `?sharesnapshot=<ts>`** — serves the frozen point-in-time record from
   `:smalt_blob_snapshots` byte-exact; base-blob mutations after the snapshot
   stay invisible through the snapshot. Missing/stale timestamp → 404, loud.

Each arm carries `# KD-COVERS: KD-60` in `lib/smalt/egress_router.ex`
(lines ~1766, ~1866, ~1906).

## Engine defect fixed

`BlobStorage.ensure_snapshot_table/0` created `:smalt_blob_snapshots` lazily
inside the first request process (no `heir`), so the table died with that Bandit
request process: a snapshot stored over the wire answered 201, then the next
request read 404 — the table was gone. Fix: `:smalt_blob_snapshots` is now
Store-supervised (declared in `lib/smalt/store.ex`, table list ~line 29, with
the defect narrative in the adjacent comment). `ensure_snapshot_table/0` is now
an idempotent guard against the Store-owned table.

## Evidence (cited, not re-run — DoD lane, no build/test runs)

- `test/wire/egress_wire_test.exs` snapshot + metadata block (lane 524, ~line
  767 onward): "PUT comp=snapshot answers 201 with x-ms-snapshot timestamp
  header", "GET comp=metadata echoes the x-ms-meta-* written by PUT
  comp=metadata", "GET sharesnapshot reads back the frozen bytes byte-exact;
  later base mutations stay invisible", "snapshot create under an active legal
  hold answers 409 ContainerLocked" — recorded session run **22/0**.
- `test/data_plane/blob_hardening_test.exs` (KD-52 WORM snapshot/tier arms +
  full hardening suite) — recorded session run **116/0**. Note (W10 ledger
  row, `_LANES.md`): the stable full-suite count on the current tree is
  **112/0**; 116/0 was the mid-wave count and is cited here as-dispatched, not
  re-run.

Per `receipt_index.py` policy, a receipt with no embedded command output is
flagged SUSPECT — expected for this doc-lane witness receipt; the counts above
are re-runnable by the owning lane.

## KD-60 flip boundary

This receipt is **witness material only**. KD-60's register row flips only via
`scripts/kd_flip.py --apply` gated on a PASS witness receipt postdating the
shim file mtime. Record for kd_flip:

- Receipt path:
  `/Users/sac/smalt/docs/jira/v26.10.16/receipts/cap-blob-snapshot-metadata.md`
- KD-COVERS marker files: `lib/smalt/egress_router.ex` (KD-60, 3 tags)

No GAP token minted or flipped by this receipt. No register edit performed.
