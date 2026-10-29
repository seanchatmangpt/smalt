# KD-31 ARM list-by-rg — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (face live; row OBSOLETE)
Context: solo
Date: 2026-10-20

## Disposition: OBSOLETE (register row stale)

Row claimed `GET .../resourcegroups/{rg}/resources` 404 RouteNotFound.
`handle_rg_resources_list` routes (both lower/upper ResourceGroups) exist and
serve.

## Witness (live substrate 9443 + witness beam 39780, 2026-10-20)

    == GET .../resourcegroups/k5rg/resources?api-version=2021-04-01
    200
    {"value":[]}
    (beam 39780) == KD-31 list-by-rg -> 200

Falsifier met. No code change; receipt-gated for flip.

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n 'defp handle_rg_resources_list' lib/smalt/arm_gateway/router.ex
705:  defp handle_rg_resources_list(conn, sub_id, rg_name) do
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

Route handler present and compiling; original wire witness (200 `{"value":[]}`,
2026-10-20) stands. Standing unchanged: ALIVE (row OBSOLETE). exit=0
