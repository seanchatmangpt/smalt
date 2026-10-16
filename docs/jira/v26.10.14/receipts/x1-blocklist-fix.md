# X-1 — Put Block List data-corruption fix (P0, from bench B-5)

- lane: X-1 (execution lane on /Users/sac/smalt)
- date: 2026-10-15
- subject: `lib/smalt/data_plane/blob_storage.ex`, `lib/smalt/egress_router.ex`
  (blob PUT/GET catch-all routes); court + witness under `scripts/shim_court/`;
  fences in `test/data_plane/blob_hardening_test.exs`
- inputs: bench B-5 receipt
  `docs/jira/v26.10.14/receipts/bench-05-python-mirror.md` (divergences 1+2)

## Defect (as found by B-5)

`PUT ...?comp=blocklist` fell into the generic Put Blob arm: the request XML
was stored as the blob body (7.5 MiB staged payload committed as a 390-byte
XML doc); SDK download silently returned wrong bytes. `Get Block List`
answered `application/octet-stream` (SDK DecodeError). `Put Block`
(comp=block) staged through put_blob (last staged block won).

## Fix

1. `BlobStorage.stage_block/7` — Put Block stages content under
   `:smalt_blob_blocks` keyed `account/container/blob<NUL>block-id`
   (NUL separator: slash-blob names are legal; "/" join would collide).
   Container-existence, block-id (1-64 bytes), content, and the 1 MiB
   per-request fence apply.
2. `BlobStorage.commit_block_list/6` — Put Block List resolves the ordered
   block refs (Latest/Committed/Uncommitted kinds parsed by
   `parse_block_list_xml/1`), concatenates the staged contents in blocklist
   order into the blob body, stores the committed list on the blob record,
   and honors WORM + If-Match/If-None-Match preconditions + the
   x-ms-blob-content-* headers. Missing referenced block → 400
   InvalidBlockList. Answers 201 + etag (Azure commit shape).
   Commit bypasses the 1 MiB per-PUT fence (per-BLOCK fence applies at
   staging; the concatenated blob may exceed 1 MiB).
3. `BlobStorage.get_block_list/3` + `block_list_xml/2` — Get Block List
   renders committed + uncommitted blocks as the Azure BlockList XML.
4. `EgressRouter.blob_block_arm/4` + GET comp=blocklist arm — dedicated wire
   arms BEFORE the generic Put Blob fallback / Get Blob fallback. Get Block
   List answers application/xml.

## Verification

- fences: `mix test test/data_plane/blob_hardening_test.exs
  test/data_plane/blob_service_test.exs` → **113 tests, 0 failures**
  (4 new X-1 fences: stage→commit→download byte-equality (600,000 bytes of
  random content), blocklist content-type application/xml + Committed/Uncommitted
  XML shape, 400 InvalidBlockList on a ghost block, x-ms-blob-content-type
  folded into stored headers).
- mutation court: `bash scripts/shim_court/blocklist_court.sh` → **PASS**
  (exit 0):
  - baseline sha256(egress_router.ex) =
    b8c28f1b38a0b21c38e3350fb1b5690a1b51eff61a461942be59868b452c5f1d
  - AFTER: `blocklist_witness.exs after` — wire stage (2×64 KiB) → commit →
    download byte-equal + Get Block List application/xml.
  - SHIM: one-line revert of the block-arm dispatch (`if false do
    # SHIM-COURT`), marker present.
  - BEFORE (shimmed): `blocklist_witness.exs before` — corruption
    re-witnessed (blob body == commit request XML).
  - RESTORE: sha256 byte-exact (b8c28f1b… verified).
- B-5 block-path measures: `scripts/bench/b5_python_mirror.py` has no block
  section (it routes around the block path per the B-5 receipt); nothing to
  rerun. The court witness is the wire-level equivalent (real router, real
  ETS store, no doubles).

## Standing

- KD-52 filed in
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — **CLOSED** by this receipt
  (census 51 → 52 registers, one CLOSED).
- No commits made (per lane contract).

## Contention note

Two mid-lane clobbers of `lib/smalt/egress_router.ex` by a concurrent KD lane
were detected and repaired (re-applied the same anchored patch twice; final
state verified by the court's sha256 restore gate and the green test run).
The court script carries a bounded compile-wait (compile-freeze SLA) so it
never shims onto a tree that is mid-edit.
