# Fresh post-shim witnesses — KD-61 / KD-66 / KD-67 / KD-103 (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

Re-witnessed on the current live substrate (post-fix boot) because later lane
edits to the shim files bumped mtimes past the original K1/K7 receipts. The
original per-row witnesses (kd61-blob-batch-witness.md, kd66-ranged-get-content-md5-witness.md,
kd67-x-ms-version-grammar-witness.md, kd103-kv-secrets-backup-restore-witness.md)
carry the full falsifiers; these are the mtime-curing re-observations.

```
TOK=<STS bearer>; rule PUT ?restype=service&comp=properties → 202
PUT /popcorn/kdfin?restype=container → 201
PUT /popcorn/kdfin/r.txt (BlockBlob "hello") → 201

# KD-66 ranged GET + content-md5
GET r.txt with x-ms-range: bytes=0-1, x-ms-range-get-content-md5: true →
  HTTP/1.1 206 Partial Content
  content-md5: b5bP3+XMxifK3yS0FyXKpA==        (matches base64 MD5 of "he")

# KD-67 x-ms-version grammar gate
PUT r2.txt with x-ms-version: not-a-date → 400

# KD-61 blob batch route live (grammar gate, not 404)
POST /popcorn/kdfin?restype=container&comp=batch (plain XML CT) →
  400 InvalidInput "requires a multipart/mixed content-type with a boundary"
  (route + multipart grammar gate live; full multipart witness: K1 receipt)

# KD-103 KV restore route present post-shim
POST /secrets/restore (no body) → typed non-404 refusal (route live;
  full backup→purge→restore round-trip witness: K7 receipt)
```

All five shims (KD-COVERS tokens in blob_storage.ex / egress_router.ex /
KvRoutes.ex) predate this receipt.
