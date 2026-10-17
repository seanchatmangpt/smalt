# R177b — KeyVault probe parity + versioned DigestInfo

Standing: PASS

## Scope

KeyVault probe-parity landing plus the versioned `DigestInfo` fix in
`lib/smalt/data_plane/key_vault_actions.ex`: real RS256 requires the
EMSA-PKCS1-v1_5 DigestInfo ASN.1 wrapper; signing the raw digest alone
omits it. Versioned rows now get the prefix prepended before signing.
Markers: `lib/smalt/data_plane/key_vault_actions.ex:622-623` (comment) and
`:663` (`SHIM-COURT (R32): mirror do_sign — DigestInfo prefix + :none`).

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/data_plane/key_vault_actions_test.exs
Finished in 1.6 seconds (0.00s async, 1.6s sync)
44 tests, 0 failures
```

44/0 matches the claimed count exactly.
