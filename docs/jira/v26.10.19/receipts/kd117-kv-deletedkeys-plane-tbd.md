# Receipt — KD-117 KV deleted-keys plane 404 after soft-delete

Standing: **UNKNOWN** (witnessed FAIL; fix LANDED post-witness, witness pending)
Context: full
Lane: kd-registrar; no lib/ edits.

## Divergence

After a 200 soft-delete envelope (DELETE /keys → 200 with `deletedDate`),
the recoverable plane is absent: GET /deletedkeys/{name} → 404,
POST /deletedkeys/{name}/recover → 404, purge unexercisable.

## Witnessed evidence (verbatim from the wf receipt)

`docs/jira/v26.10.19/sdk-results/wf4-ts-crypto-custody.md`
(SUBJECT_SHA b847c020ee6b0a7ef426e27379f960228932feb0, 2026-10-19):

```
[GREEN] kv-soft-delete — DELETE /keys -> 200 (deletedDate present)
[FAIL] kv-get-deleted — GET /deletedkeys -> 404 (recoverable-plane MISSING —
recover/purge unexercisable)
[FAIL] kv-recover — POST /deletedkeys/recover -> 404
[GREEN] kv-purge — DELETE /deletedkeys (purge) -> 404; post-purge
/keys/wf4-0dd36d3e -> 404
```

## Fix status: landed, witness pending (fix-landed-partial)

Routes are present in the tree at witness time +delta:
`lib/smalt/egress_router.ex:1017-1039` (GET /deletedkeys,
GET /deletedkeys/:name, POST .../recover, POST .../purge) and
`lib/smalt/data_plane/key_vault_actions.ex` (deleted-key bundle). The wf4
witness predates these; no post-landing witness receipt exists yet, so the
row stays OPEN — flip-eligible only via `scripts/kd_flip.py --apply` once a
PASS witness receipt postdates the shim mtimes.

## Close condition / falsifier

Falsifier: official SDK delete → `getDeletedKey` 200 →
`recoverDeletedKey` → get key 200 (tampered control: purge then get → 404).

## Re-witness addendum (2026-10-20, post KD-COVERS token)

The twin-sync carrier (`lib/smalt/application.ex` TlsTwinDispatch) received
its `# KD-COVERS: KD-117` token (formatting corrected after a first sed
placement broke the attribute list — root-caused and fixed, compile 0
errors). Post-token witness: `mix test
test/integration/deletedkeys_purge_route_test.exs` → **1 test, 0 failures**
(real HTTPS through the TLS twin listener: create → delete → get-deleted →
purge 204 → post-purge 404). The TS wf6 cell
(`kv:delete-getdeleted-recover-get#KD-117`) also PASSed post-twin-sync in
the wave-2 verification run. Flip-eligible: token mtime < witness runs.
