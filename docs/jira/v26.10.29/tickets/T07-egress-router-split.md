# T07 — Split `Smalt.EgressRouter` (4945 lines)

- window: v26.10.29 · status: QUEUED (after T-R1 undock restore)

## Why

Second-largest file (4945 lines, 54 defs, plus an embedded
`defmodule Peers` inside the same file). Carries storage catch-alls, KV
routes, sync/journal, sbns, crypto faces — and the triage's #1 regression
(T-undock) lives here, so sequence AFTER the undock restore lands (T-R1).

## Split plan

- Hoist the embedded `defmodule Peers` into
  `lib/smalt/egress/peers.ex` (verbatim hoist first, later niceties).
- Split by route family into `Smalt.Egress.*` plug modules
  (`KvRoutes.ex` already exists as the pattern — same directory
  convention: `lib/smalt/egress/`).
  - `Egress.StorageCatchAll` (blob/queue/file `/{account}/...` arms)
  - `Egress.SyncRoutes` (/sync/journal/batch)
  - `Egress.SbnsRoutes` (/sbns REST face)
  - `Egress.CryptoFaces` (KV crypto face)
  - `Egress.Attestation` (/attest, /app, /dbs ... prefixes)
- Front `EgressRouter.call/2` becomes prefix dispatch + typed 404
  fallback, delegating via existing helpers (`safe_dispatch/2` restored by
  T-R1 is the seam).

## Constraints

- Byte-identical wire behavior; existing courts are the only gate; no test
  edits. NOTE: this file is currently the subject of the undock-restore
  lane (T-R1) — land T-R1 first, rebase this split on the restored router.
