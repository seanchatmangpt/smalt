
---

## Post-close note (2026-10-20, lane w6bk)

Audited this lane's `TableStorageRouter.route/1` during the w6bk plane-fence
fix: it is literal-`tables`-prefixed (every arm requires segs[0] == "tables"),
so it does NOT shadow reserved data-plane namespaces — no change needed. The
shadowing defect was confined to the file plane's multi-segment GET/DELETE
catch-alls (fixed by w6bk; see w6o receipt note). Table legs re-verified on
live wire post-fix: TABLE_PUT=201, TABLES_GET=200 odata value echo.

---

## SUPERSEDED-BY addendum (2026-10-22, lane BK-SUSP3)

The post-close note above is confirmed current and its cited successors are
on disk; the audited premise (literal-`tables` prefix, no namespace shadowing)
re-verified against the current router source.

SUPERSEDED-BY (for the fix the note audits): the w6bk plane-fence fix receipt
`docs/jira/v26.10.20/receipts/w6bk-plane-fence.md` and the audited-surface
receipt `docs/jira/v26.10.20/receipts/w6o-file-share.md` — both present.

On-disk verification (this addendum, real):

```
$ ls docs/jira/v26.10.20/receipts/w6bk-plane-fence.md docs/jira/v26.10.20/receipts/w6o-file-share.md -> both present, exit=0
$ grep -n 'segs\|"tables"' lib/smalt/data_plane/table_storage_router.ex
  -> lines 19-32: every arm is literal ["tables", ...]-prefixed with
     `when t != "tables"` guards, exit=0 (no reserved-namespace shadowing)
```

## Standing

**Standing:** ALIVE (post-close audit-note addendum — premises re-verified on disk with embedded ls + grep output, exit 0; the audited fix itself is SUPERSEDED-BY the w6bk-plane-fence and w6o-file-share receipts)
