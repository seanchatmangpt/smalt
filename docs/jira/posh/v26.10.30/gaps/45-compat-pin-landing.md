# G45 — compat-pin landing (lands G33's pin)

Status: ALIVE — pin + gate + flip, all executed this session.

## Receipt

- Subject: `/Users/sac/smalt/compat-pin.ttl` (pin),
  `/Users/sac/smalt/scripts/compat_pin_check.py` (gate),
  `/Users/sac/smalt/justfile.d/58-posh.just` (single disclosed block, appended;
  `compat-check` + `compat-court` recipes).
- Note: `gaps/33-compat-pin.md` did not exist on disk at dispatch time; the
  inline dispatch spec was the authority. All pin values were re-derived from
  source before pinning (see verification below) — every dispatch-listed
  version matched registry.ex exactly.
- Registry tops pinned (17 rows): the 13 dispatch-listed types plus
  networkInterfaces / NSG / vNets / subnets broken out individually (dispatch
  said "Network 2023-05-01"), each confirmed against `lib/smalt/registry.ex`
  `@api_versions` (post-C4 tops).
- Provider constants pinned (14) + 1 registered divergence:
  `ficAPIVersion` speaks 2023-01-31 in the provider vs registry top
  2023-08-01 — registered as a KD-45-1 divergence row rather than a failure
  (pass / registered-divergence / loudly-missing register pattern). Container
  app / CAE primaries (2024-03-01) ride alongside their pinned 2023-05-01
  fallbacks; KV fallback 2023-02-01 pinned.
- Payload laws (gate-checked evidence greps): managedEnvironmentId dual-key
  (`props["managedEnvironmentId"]` + `props["environmentId"]` in
  resource_container_app.go), numeric memory (`parseMemoryGiB` + the
  "memory NUMERIC on the wire" witness in live_f4_test.go), always-set
  location (`rawMap["location"] = loc`), TF floor >=1.14 <2 (provider README
  dev_overrides >= 1.14 note), kind cluster name `smalt`
  (justfile.d/52-kind.just `SMALT_KIND_CLUSTER` default).
- Surface counts 12/7 derived mechanically from the two
  `"azurerm_*": false,` inventory maps in server_test.go; census = count of
  `func Test` in internal/provider/*_test.go = 37.

## Commands / exits (this session)

- `python3 scripts/compat_pin_check.py` → exit 0, ALIVE:
  17 registry tops, 14 constants + 1 divergence, surface 12/7, census 37,
  5 payload laws, cluster=smalt, tf_floor=>=1.14, <2.0.
- `just compat-check` → exit 0 (Justfile parses; recipes listed).
- `just compat-court` → exit 0: mutated ACR→2024-03-01 temp copy flipped the
  gate to exit 1; real pin sha256
  6b54a122bf00c145120d249b70cc9dd1248a2945b9c0cd1e7d81bd3f82af6b28 identical
  before/after.

## Standing / falsifiers

- Gate exit 0 is clean against CURRENT truth at 2026-10-30; census=37 and
  surface 12/7 will flip the gate loud (exit 1) if concurrent lanes land
  tests/surfaces — that is the pin working, retire rows by re-derivation,
  not by loosening.
- FIC divergence row retires when the provider adopts 2023-08-01.
- Exit ladder: 0 clean / 1 divergence / 3 source-missing (loud skip).
