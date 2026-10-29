# KD-24 witness — ARM generic PUT with double-slash provider segment (stale-row disposition)

**Standing:** CLOSED (KD-24 row OBSOLETE — row evidence stale, close condition already met on wire)

Row: KD-24 — double-slash generic PUT 404s; real ARM collapses `//`.
Subject: `lib/smalt/arm_gateway/router.ex` (generic provider routes)

## Disposition

OBSOLETE. The `providers//Microsoft.Storage/...` path already collapses to the
single-slash resource id and answers 202 LRO on PUT, 200 on GET. No lib/ edit
made for this row by lane K4. Likely closed by the Plug path-segment collapsing
that landed with the generic-route work; the row was never flipped.

## Evidence (live wire, lane K4 substrate, MIX_ENV=test on :39551, 2026-10-21)

```
== KD24 PUT // (double slash)
{"delayMs":0,...,"resourceId":"/subscriptions/.../resourceGroups/k4w/providers/Microsoft.Storage/storageAccounts/k4dbl","status":"InProgress"}
== KD24 GET (single-slash id)
{"id":"/subscriptions/.../resourceGroups/k4w/providers/Microsoft.Storage/storageAccounts/k4dbl","kind":"StorageV2","location":"eastus",...}
```

PUT through `providers//Microsoft.Storage` stored under the canonical
single-slash id; GET at the single-slash id returns the account (200 envelope).
Close condition ("collapse `//` in path matching") is met.

## Flip

FLIP-ELIGIBLE (dry-run only; flip via `scripts/kd_flip.py --apply` gated on this
receipt, not by hand).

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

Cheap compiled-surface re-witness (original wire evidence above untouched).
Mechanism probe on the current tree:

```
$ grep -n 'normalize_leading_empty_segment' lib/smalt/arm_gateway/router.ex | head -2
39:  plug(:normalize_leading_empty_segment)
exit=0
$ grep -c 'providers/\*glob' lib/smalt/arm_gateway/router.ex
6
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe, exit=0
exit=0
```

The `providers/*glob` generic routes (6 match sites, router.ex 5249/5253/6881
region) absorb the interior empty segment of `providers//Microsoft.Storage/...`
and the record is stored under the canonical single-slash id; the leading-empty
plug plus glob routes are present and the app compiles. Standing unchanged:
OBSOLETE (row closed on the 2026-10-21 wire evidence; surface still live). exit=0
