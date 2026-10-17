# how-to-develop-native

The developer inner loop for the native (in-process) surface: edit, test,
repeat, without any external substrate or terraform.

## The loop

```bash
just doctor          # preflight: deps/ports/certs/toolchain (~2s)
# ... edit lib/ or test/ ...
just test-native     # Hcl parse -> Engine apply -> plan (zero drift) -> destroy + residue gate
mix test             # offline suite (self-boots app on EPHEMERAL ports, no substrate needed)
```

`just test-native` runs the full native lifecycle against
`test/terraform_fixture/main.tf` on a dedicated beam, private ports
29445-29450 (mcp included — the shared substrate holds 9545), under a private
flock with the lock fd closed on spawn (`9>&-`, fan-out law 4). It boots the
full `Smalt.Application` (Store, broker, endpoints) with `auth_mode
:anonymous`, then:

1. `Smalt.Enclave.Hcl.parse/1` parses the fixture HCL to resource terms.
2. `Smalt.Enclave.Engine.apply/2` provisions through the in-process ARM router
   (no terraform binary).
3. `Smalt.Enclave.State.plan/1` must report zero drift after apply.
4. `Smalt.Enclave.State.destroy/1` cascades and verifies 404 per resource.
5. Residue audit: every resource-bearing Store table must come back empty
   (metadata tables excluded — LRO ops history, subscriptions, locks, tokens,
   sessions, checkpoints are bookkeeping, not residue). Non-empty residue is
   `RESIDUE NONZERO` exit 1. This is the engine's non-vacuity surface: a
   broken Engine/Hcl/State/router shows up as DRIFT, failed cascade, or
   residue.

Exit codes: 0 pass; 1 drift/cascade/residue failure; 3 lock not acquired.

## Other lifecycle recipes

```bash
just apply                    # provision, write tmp/native-enclave-state.json
just verify # state-file parity + zero drift + blob/secrets/cosmos read-your-write + console harness
just destroy # parity-check ids, cascade destroy, residue gate (SKIP-LOUD exit 3 without prior
  apply)
just audit-residue            # apply + destroy + per-table residue audit
```

`verify` requires `tmp/native-enclave-state.json` from a prior `just apply`;
missing/empty state is a loud `SKIP-LOUD` exit 3, never a fake pass. Honest
destroy: the store is in-memory ETS per beam, so destroy re-applies in the
same beam and parity-checks the recorded deterministic ids before deleting.

## The e1 lane

`just enclave-loop` runs the e1 bench lane (`scripts/tf_enclave_loop.sh`):
terraform-enclave provision, data-plane + console legs, residue audit, emits
`docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl`. Loud-skip exit 3 when
terraform/prereqs are missing. No `e2` lane artifact exists on disk — do not
cite an e2 lane as landed (see `docs/jira/v26.10.16/FINAL.md`).

## In-process lifecycle for tests

`mix test` self-boots the application on port 0 (ephemeral) — tests never
depend on, and never collide with, a live substrate on 9443/8443/9545. The
same pattern is used by `mix smalt.doctor` (pins all ports to 0 before
`app.start`). For per-test isolation use a fresh Store snapshot + strict ETS
baseline identity — the pattern extracted into the doctor's store-invariants
check and `test/smalt_ets_baseline_identity_test.exs`. For a private build
root on a shared checkout set `MIX_BUILD_ROOT=_build-lane<N>` (see
[how-to-clean.md](how-to-clean.md)).

## Targeted runs

```bash
scripts/fast_test.sh test/foo_test.exs[:LINE]     # per-hash private build root (_build-ft-<hash>)
MIX_BUILD_ROOT=_build-lane7 mix test test/wire
```

See Also: [how-to-run-wire-parity.md](how-to-run-wire-parity.md) ·
[how-to-clean.md](how-to-clean.md)
