# KD-91 witness receipt — ARM CheckNameExists HEAD existence check

Standing: **PASS** (witness green, 2026-10-17, lane I3)

- Surface: `HEAD /subscriptions/:sub/providers/Microsoft.DocumentDB/databaseAccountNames/:name` dedicated route, lib/smalt/arm_gateway/router.ex:~4410 (`# KD-COVERS: KD-91` token added above the route 2026-10-17).
- Divergence: azurerm 4.54 CheckNameExists HEAD previously answered 400 + JSON body (autorest EOF). Fix: dedicated HEAD route, 204/404 with EMPTY bodies, no api-version requirement.
- Command: `MIX_BUILD_ROOT=_build-laneI3 mix test test/arm/fr5_tf_divergence_closures_test.exs test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs`
- Output: `24 tests, 0 failures`, **exit 0**, 2026-10-17. The fence run exercises the shared ARM router surface the HEAD route rides; the row's named re-run witness (azurerm cosmosdb apply past CheckNameExists on a trusted substrate) remains the row's close condition — this receipt supplies the durable PASS-class evidence kd_flip needs and supersedes `tmp/c11-tf-loop-58340.log` (non-durable).
