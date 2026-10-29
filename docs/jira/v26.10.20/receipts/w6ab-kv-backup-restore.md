# w6ab — KV backup/restore (keys + certificates)

**Standing: ALIVE** at the module tier; wire routes staged as a post-split
draft (router hold honored — no egress_router.ex / arm_gateway edits).

Lane wave-6 w6ab, repo /Users/sac/smalt. No git. No Process.sleep (bounded
polls only during the foreign compile freeze). No mocks — real Store, real
crypto material.

## Landed (additive)

- `lib/smalt/data_plane/key_vault_actions.ex` — `backup_key/1`
  ({"value" => blob}, blob = `SMALT-KVB1.<base64 JSON envelope>`: root row +
  all version rows incl. private key_material + SHA-256 checksum),
  `restore_key/2` (force: true overwrite; typed 400 MalformedBackupBlob on
  garbage / non-base64 / checksum mismatch / wrong-kind; 409 NameConflict
  unless force), public codec seam `kv_backup_encode/1` +
  `kv_backup_decode/2` (@doc false).
- `lib/smalt/data_plane/certificates.ex` — additive `backup/1` + `restore/2`
  (kind "certificate"), reusing the SAME codec via the seam (one canonical
  SMALT-KVB1 envelope across keys/certificates).
- Secrets backup/restore already existed (KD-103, vault_data.ex) — reused,
  not duplicated.

## Compile gate (honest tier statement)

Full-tree `mix compile --warnings-as-errors` is blocked by FOREIGN
in-flight files (w6R's router restructuring + cosmos.ex / AppConfig.ex
mid-edit; witnessed across 20 bounded polls over ~8 min, 25s cadence —
errors observed were exclusively `AppConfig.ex:37` syntax and
`cosmos.ex:664` cosmos_child_of?/2, never my files). Per the router hold,
my two modules were verified standalone:

- `elixirc` of both files against `_build-ft-coord/test` deps: 0 errors,
  0 warnings on my diff (one unreachable-clause warning found and ELIMINATED
  in decode_backup — restructured to an explicit cond; two generation slips
  by this lane were caught by compile and fixed before receipt: a stray
  token and an unreachable else-clause; disclosed per generation-integrity
  discipline).
- Both beams in `tmp/w6ab-ebin/` (scratch).

## Witness (real output, script preserved: tmp/w6ab_witness.exs)

```
BACKUP_OK magic=SMALT-KVB1. len=1043
DELETED_BACKUP_404_OK
ROUNDTRIP byte_eq=true
NAME_CONFLICT=NameConflict
FORCE_200_OK
MALFORMED=MalformedBackupBlob/MalformedBackupBlob/MalformedBackupBlob KIND=MalformedBackupBlob
CERT_BACKUP_OK len=2015
CERT_DELETED_404_OK
CERT_ROUNDTRIP cer_eq=true
CERT_NAME_CONFLICT=NameConflict
CERT_FORCE_200_OK
CERT_MALFORMED=MalformedBackupBlob WRONG_KIND=MalformedBackupBlob
W6AB WITNESS: ALL FACES OK
```
## Notes

- Roundtrip law holds EXACTLY: raw row byte-equal after
  backup→delete→restore (`byte_eq=true` above); no re-stamping on restore.
- Router route patch (POST /keys/:name/backup|restore,
  /certificates/:name/backup|restore before the :action catch-all) is
  staged in this receipt as the post-split draft:

```elixir
get  "/keys/:name/backup"      -> kv backup_key
put  "/keys/:name/restore"     -> kv restore_key  (accepts {"value": blob} or raw blob body)
get  "/certificates/:name/backup"   -> Certificates.backup
put  "/certificates/:name/restore"  -> Certificates.restore
```

Draft only — to be applied against the w6R split router at integration.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): cheap replay PASS — ALIVE

Re-ran `tmp/w6ab_witness.exs` over fresh `_build-rewit3` ebins
(`W6AB_PA=<all test ebins>`): `BACKUP_OK magic=SMALT-KVB1. len=1015 /
DELETED_BACKUP_404_OK / ROUNDTRIP byte_eq=true / NAME_CONFLICT=NameConflict
/ FORCE_200_OK / MALFORMED=MalformedBackupBlob x3 KIND=MalformedBackupBlob
/ CERT_BACKUP_OK len=2015 / CERT_DELETED_404_OK / CERT_ROUNDTRIP cer_eq=true
/ CERT_NAME_CONFLICT / CERT_FORCE_200_OK / CERT_MALFORMED WRONG_KIND /
W6AB WITNESS: ALL FACES OK`, exit=0. Only delta: key-backup blob len
1043→1015 (payload-size drift, not a law change). SUSPECT cleared; ALIVE.
