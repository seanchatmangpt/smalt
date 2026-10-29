# KD-32 ARM RG PATCH — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (face live; row OBSOLETE)
# Date: 2026-10-20

## Disposition: OBSOLETE (register row stale)

Row claimed `PATCH .../resourcegroups/{name}` (tags) 404 RouteNotFound.
`handle_rg_patch` route pair exists (router.ex :637/:637 region) and serves.

## Witness (live substrate 9443 + witness beam 39780, 2026-10-20)

    == PATCH /subscriptions/.../resourcegroups/k5rg?api-version=2021-04-01 {"tags":{"k5":"v2"}}
    200
    {"id":".../resourceGroups/k5rg", ... "tags":{"k5"...
    (beam 9443 live probe, pre-fix baseline identical)

Falsifier met (PATCH tags -> 200 with tags applied). No code change;
receipt-gated for flip.

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n 'defp handle_rg_patch' lib/smalt/arm_gateway/router.ex
662:  defp handle_rg_patch(conn, sub_id, rg_name) do
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

Route handler present and compiling; original wire witness (PATCH tags -> 200
with tags applied, 2026-10-20) stands. Standing unchanged: ALIVE (row
OBSOLETE). exit=0
