# KD-30 ARM locations — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (face live; row OBSOLETE)
Context: solo
Date: 2026-10-20

## Disposition: OBSOLETE (register row stale)

Row claimed `GET /subscriptions/{sub}/locations` 404 RouteNotFound.
`handle_locations_list/2` exists (lib/smalt/arm_gateway/router.ex:702, route
at :3414) and the live face serves it.

## Witness (live substrate 9443 + witness beam 39780, 2026-10-20)

    == GET /subscriptions/00000000-.../locations?api-version=2021-04-01
    200
    {"value":[{"displayName":"East US","id":"/subscriptions/.../locations/eastus","name":"eastus","regionalDisplayName":"(US) East US"},...

Falsifier met (route serves 200). No code change; row is receipt-gated for
flip.

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n 'defp handle_locations_list' lib/smalt/arm_gateway/router.ex
720:  defp handle_locations_list(conn, sub_id) do
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

Route handler present and compiling; original wire witness (200 locations
envelope, 2026-10-20) stands. Standing unchanged: ALIVE (row OBSOLETE). exit=0
