# KD-29 ARM virtualNetworkLinks — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (face live; row OBSOLETE)
Context: solo
Date: 2026-10-20

## Disposition: OBSOLETE (register row stale)

Row claimed `privateDnsZones/virtualNetworkLinks` PUT 404s before the shape
gate ("type unreachable"). The face is fully live on the current substrate;
witnessed wire probes 2026-10-20.

## Witness (live substrate, port 9443, HTTP+STS bearer; then witness beam 39780)

    PUT parent zone (2018-09-01)            -> 201
    PUT .../virtualNetworkLinks/link1       -> 201 (envelope carries
      properties.registrationEnabled + virtualNetwork.id)
    PUT with missing parent zone            -> 404 ResourceNotFound
      ("The parent zone.local could not be found.")
    PUT with future-universe api-version    -> 400 InvalidApiVersionParameter
      (latest supported 2018-09-01 — KD-78 monotonic gate live)

Concluding witness (beam 39780):

    == KD-29 vnet link lifecycle
    201 201
    {"id":".../privateDnsZones/z.local/virtualNetworkLinks/l1","properties":{"provisioningState":"Succeed...

Falsifier met: PUT reaches the child-route face and stores a real record,
never 404-before-shape. No code change needed; row is receipt-gated for the
registrar's kd_flip/coordinator flip, not for implementation.

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -c 'virtualNetworkLinks' lib/smalt/arm_gateway/router.ex
14
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

The virtualNetworkLinks child face is present on the current tree (14 route/
record sites via handle_child_put) and the app compiles; original wire witness
(2026-10-20, 201 PUT / 404 parent-missing / 400 future api-version) stands.
Standing unchanged: ALIVE (row OBSOLETE). exit=0
