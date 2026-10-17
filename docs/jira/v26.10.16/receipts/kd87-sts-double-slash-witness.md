# KD-87 witness receipt — STS token path double-slash tolerance

Standing: **PASS** (witness green, 2026-10-17, lane I3)

- Surface: `normalize_leading_empty_segment/2` plug, lib/smalt/arm_gateway/router.ex:85 (`# KD-COVERS: KD-87`); bearer.ex exempt-path tolerance (`# KD-COVERS: KD-87` at lib/smalt/auth/bearer.ex:180).
- Divergence: azurerm 4.54 POSTs `//{tenant}/oauth2/v2.0/token`; Plug.Router cannot match the leading empty segment → fell through to the bearer guard → 401 MissingBearerToken.
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/kd87_sts_leading_empty_segment_test.exs` (plus the joint run below)
- Output: `2 tests, 0 failures`, **exit 0**; joint run `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/fr5_tf_divergence_closures_test.exs test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs` → `24 tests, 0 failures`, **exit 0**, 2026-10-17.
- Falsifier leg: STS token POST on wire path `//00000000-0000-0000-0000-000000000000/oauth2/v2.0/token` → 200 + access_token; control single-slash leg → 200. (An interior-`//` leg was dropped: Plug's own router segment matching, not the smalt plug, governs that case — out of the KD-87 falsifier's scope.)
- Coverage tokens retokenized 2026-10-17 (router.ex:77, bearer.ex:180) to this row's id; provenance note landed in the canonical row.
- Supersedes the non-durable `/tmp/reh-plan2.log` TF_LOG receipt and `/tmp/rehearse3.sh` transcript named in the KD-87 row.
