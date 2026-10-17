# Receipt — R161 (wire_norm court no-op verdict)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

R161 was the wire-normalization re-verification pass: the landed
`scripts/shim_court/wire_norm_court.sh` legs (kd01/kd03/kd07) were re-run to
confirm the landed shapes still hold; verdict: no further change needed (no-op
on the lib surfaces, court-only re-run).

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ scripts/shim_court/wire_norm_court.sh all
[SHIM] kd07 BEFORE passed (old shape returns)
[SHIM] kd07 RESTORE verified byte-exact
[COURT] === kd03 (subject: lib/smalt/data_plane/blob_service.ex) ===
[SHIM] baseline sha256(lib/smalt/data_plane/blob_service.ex) = 77124a7c8cd9664f03fef4bc6d3714e3b9c769faaebb80d361847cbc0a264fcc
[SHIM] kd03 AFTER passed (Azure shape holds)
[SHIM] kd03 BEFORE passed (old shape returns)
[SHIM] kd03 RESTORE verified byte-exact
[COURT] WIRE-NORM COURT: ALL LEGS PASSED
exit=0
```

## W10 re-run (2026-10-16, docs lane W10)

```
$ scripts/shim_court/wire_norm_court.sh all
[COURT] === kd01 (subject: lib/smalt/egress_router.ex) ===
[SHIM] baseline sha256(lib/smalt/egress_router.ex) = 183761fb4aa8067321c9fc40266a4f0b1b43b019d230da9120dcc7e5d967f599
[SHIM] kd01 AFTER passed (Azure shape holds)
[SHIM] kd01 BEFORE passed (old shape returns)
[SHIM] kd01 RESTORE verified byte-exact
[COURT] === kd07 (subject: lib/smalt/egress_router.ex) ===
[SHIM] kd07 AFTER passed (Azure shape holds)
[SHIM] kd07 BEFORE passed (old shape returns)
[SHIM] kd07 RESTORE verified byte-exact
[COURT] === kd03 (subject: lib/smalt/data_plane/blob_service.ex) ===
[SHIM] kd03 AFTER passed (Azure shape holds)
[SHIM] kd03 BEFORE passed (old shape returns)
[SHIM] kd03 RESTORE verified byte-exact
[COURT] WIRE-NORM COURT: ALL LEGS PASSED
EXIT=0
```

No-op verdict reconfirmed on the current tree. Standing: PASS.
