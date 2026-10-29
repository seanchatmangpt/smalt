# Known Divergences — v26.10.25 (pointer)

Canonical KD register: [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
(the table is ground truth). Mint from KD-187 (highest minted id is
KD-186 — the wrap coordinator minted KD-182…KD-186 from the upstream
security-claim court handoff
(`docs/kd_register_integration_2026-10-24.md`), all mint-then-close
CLOSED-WITH-EVIDENCE with in-repo receipts under `receipts/`. This doc
REGISTERS; it does not close. Flips only via
`scripts/kd_flip.py --apply`, gated on a PASS witness receipt postdating the
shim mtime.

## Rows minted this window

- **KD-182** — Cosmos wrong-pk DELETE destroys cross-partition (cosmos lane;
  `lib/smalt/data_plane/cosmos.ex` `do_delete_doc/4`; upstream S7.5): the pk
  fence landed with the wave; court
  `test/data_plane/cosmos_pk_point_read_delete_test.exs` green at the census
  + landing SHA. Status: CLOSED-WITH-EVIDENCE (mint-then-close). Receipt:
  `receipts/kd182-cosmos-pk-delete.md`.
- **KD-183** — Cosmos point-read ignores the pk header (upstream S7.4): the
  pk fence landed; same court. Status: CLOSED-WITH-EVIDENCE
  (mint-then-close). Receipt: `receipts/kd183-cosmos-pk-point-read.md`.
- **KD-184** — KV "latest" resolved lexically-greatest, not last-write
  (upstream s19.3): `created_seq` version rows + latest pointer landed
  V20a/V20b; courts kds3_s4 + kdlith_w2 green. Status: CLOSED-WITH-EVIDENCE
  (mint-then-close). Receipt: `receipts/kd184-kv-latest-resolution.md`.
  Evidence: upstream s19/s10 courts witnessed 2026-10-25T06:05Z (s19 4/4,
  s10 4/4), handoff rows KD-R17-3/4/5.
- **KD-185** — KV superseded-version addressability (disjunctive-law
  note-row): collapses to one behavior with the version-history landing.
  Status: CLOSED-WITH-EVIDENCE (mint-then-close). Receipt:
  `receipts/kd185-kv-superseded-addressability.md`.
- **KD-186** — KV versions-list dropped the `version` member + V20b scoped-id
  leak (upstream s19(2b)/s10.4): V20a projection + V20b unscoped-id builder
  landed; courts kdlith+w2 + tenant_fence_blob_kv_queue green. Status:
  CLOSED-WITH-EVIDENCE (mint-then-close). Receipt:
  "receipts/kd186-kv-versions-list.md".
