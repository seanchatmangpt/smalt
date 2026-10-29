# Receipt: bkmkt1-pack-facts — the deployable k8s manifests become pack facts

**Standing: ALIVE** — the full deployable set (Secret, ConfigMap, headless/ClusterIP/NodePort Services, StatefulSet) renders from admitted facts through real refusal gates, set-equal (modulo typed ordering) to BK-K8SM's hand-written deployable manifests, `kubectl apply --dry-run=client` AND `--dry-run=server` green on the live kind-smalt cluster (2 nodes, v1.34.0).

Context: solo. Lane BK-MKT1, v26.10.22, repo /Users/sac/smalt.

## Decision (task step 2): option (b), per the pack's own README philosophy

The kubernetes-workload-pack exists because hand-authored manifests re-drift — its README's whole "Why this exists" section. The deployable set must be a render output of admitted facts NOW, not after an upstream PR cycle. So: **smalt-local pack** (`packs/smalt-k8s-pack/`) extends the upstream pack; the template + ontology + gates here are simultaneously the **prepared upstream v0.3.0 contribution** (typed in `pack.toml`; the same files apply as the patch). The upstream PR is not filed from this lane (ggen-marketplace is a separate repo, not this lane's lease).

## What landed

| File | What |
|---|---|
| `packs/smalt-k8s-pack/pack.toml` | smalt-local pack, v0.1.0, typed as the upstream v0.3.0 contribution |
| `packs/smalt-k8s-pack/ontology.ttl` | extends the k8s: vocabulary: `k8s:StatefulSet`, `EnvVar` (envOrder), `ContainerPort`, `ServicePort`, `VolumeMount`, `Service`, `Secret`, `ConfigMap` classes + properties. Schema-only (dspy-pack contract): zero individuals |
| `packs/smalt-k8s-pack/templates/statefulset_and_services.yaml.tmpl` | renders the FULL deployable set per StatefulSet; same self-contained to:/sparql:/for_each: format + reindent macro as the upstream template |
| `packs/smalt-k8s-pack/gates/010_required.rq` | required facts for the extended shapes (StatefulSet/ContainerPort/EnvVar/Service/ServicePort/VolumeMount/Secret/ConfigMap) |
| `packs/smalt-k8s-pack/gates/030_antiaffinity_required.rq` | multi-replica StatefulSet requires podAntiAffinityBlock with real podAntiAffinity content (inert block = `ANTIAFFINITY_BLOCK_INERT`) |
| `packs/smalt-k8s-pack/gates/040_headless_required.rq` | StatefulSet serviceName must name an admitted headless Service (`clusterIP "None"`) — per-pod DNS is the BEAM discovery mechanism |
| `packs/smalt-k8s-pack/gates/050_dist_port_range.rq` | BEAM dist range pinned: `erl-dist` = 9000 + ERL_AFLAGS `inet_dist_listen_min 9000 … max 9009` (EnvVar or backend-env ConfigMap) |
| `priv/smalt-k8s.ttl` | backend retyped k8s:Workload → k8s:StatefulSet + full deployable facts: 7 named container ports, 3 ordered env vars (fieldRef/secretKeyRef/value), 3 Services, 15 ServicePorts, 2 VolumeMounts, Secret + ConfigMap blocks. Console unchanged (Deployment via upstream pack) |
| `ggen.toml` | wires `smalt-k8s-pack = { path = "packs/smalt-k8s-pack" }` |
| `ggen.lock` | re-locked (blake3 smalt-k8s-pack `36e832e6…`) |
| `k8s/smalt-backend.gen.yaml` | now the deployable render: 6 docs — Secret, ConfigMap, 3 Services, StatefulSet |

## Embedded output — render (clean graph)

```
$ ggen sync run
"decisions": { "k8s/smalt-backend.gen.yaml": "written",
               "k8s/smalt-console.gen.yaml": "skipped: unchanged: content identical" }
"graph_hash_hex": "c193dcec67f9a82a14076983458e3aec2211def39b357a23ff487c3560709ace"
"packs": { "kubernetes-workload-pack": "38993abe…",
           "blake3 smalt-k8s-pack": "36e832e6…" }
"written": [k8s/smalt-backend.gen.yaml]     exit 0
```

Deterministic replay: re-run → `written: []` (content identical).

## Embedded output — kubectl dry-run (live kind-smalt, 2 nodes v1.34.0)

```
$ kind get kubeconfig --name kind-smalt > /tmp/kc-smalt.yaml
$ KUBECONFIG=/tmp/kc-smalt.yaml kubectl apply --dry-run=client --validate=strict -f k8s/smalt-backend.gen.yaml
secret/smalt-release-cookie created (dry run)
configmap/smalt-backend-env created (dry run)
service/smalt-backend created (dry run)
service/smalt-backend-headless created (dry run)
service/smalt-backend-nodeport created (dry run)
statefulset.apps/smalt-backend created (dry run)

$ KUBECONFIG=/tmp/kc-smalt.yaml kubectl apply --dry-run=server -f k8s/smalt-backend.gen.yaml
… created (server dry run) — exit 0
(Warning: spec.SessionAffinity is ignored for headless services — informational)
```

## Embedded output — gate non-vacuity (real mutations, real refusals, restore sha-verified by re-render identical)

```
MUT1 delete podAntiAffinityBlock triple → FM-PACK-013 smalt-k8s-pack gate
     030_antiaffinity_required.rq: violation = ANTIAFFINITY_MISSING   → sync refused
MUT2 svcHeadless loses serviceClusterIP "None" → gate 040_headless_required.rq:
     violation = HEADLESS_SERVICE_NOT_ADMITTED                        → sync refused
MUT3 erl-dist 9000 → 9001 → gate 050_dist_port_range.rq:
     violation = DIST_PORT_NOT_PINNED_9000                            → sync refused
RESTORE cp /tmp/smalt-k8s.ttl.bkmkt1.bak → ggen sync run → written: [] (identical)
```

Upstream gate 020 (SEC-PRIV-001) still covers the backend container (matches k8s:Container/k8s:inWorkload regardless of workload kind) — witnessed refusing during development: a multi-line `volumeMountsBlock` literal on the Container tripped its SCALAR_LINE_BREAK clause. That is a real upstream finding: **gate 020's allowlist needs the new block properties at v0.3.0** — currently the patch models volume mounts as typed `k8s:VolumeMount` individuals (single-line scalars) instead, which is the strictly typed form.

## Rendered-vs-handwritten diff (typed — the subsumption proof)

Parsed both files (python3 yaml), per-object field comparison:

- **Doc sets equal** (6 docs, same kind+name each): `set(gen) == set(hand) == True`.
- **Set-equal modulo ordering: True.** Service ports, container ports, volumeMounts, env compare name-keyed EQUAL as sets.
- Ordering differences (typed, all render-order only):
  1. Ports/volumeMounts render in SPARQL ORDER BY (numeric/by-name), not hand-written declaration order — set-identical, YAML maps-of-lists under key `name`, semantics unchanged.
  2. **env order deliberately corrected: POD_NAME before RELEASE_NODE** — `$(POD_NAME)` expands only when defined earlier (BK-SWARM typed note; hand-written carries the hazard order, render fixes it).
  3. Headless Service renders explicit `type: ClusterIP` where hand-written omits `type` — identical default.
  4. Secret's host-side overwrite comment preserved inside the stringData block; StatefulSet explanatory comments are provenance-header + facts-file comments (comment prose is not a k8s object).
- Zero objects only-in-handwritten; zero semantic field differences.

**Verdict: the render subsumes the hand-written deployable set.** `k8s/smalt-backend.yaml` (hand-written) can be retired to validation-reference status; not deleted this lane (coordinator-owned file surface; explicit successor WO: repoint consumers, delete or mark deprecated).

## Boundary / falsifiers

- BK-SWARM's scratch `/tmp/bkswarm/smalt-swarm-sts.yaml` was scratch; this lane's render is the committed form of the same deployable shape.
- Drift falsifier: any hand-edit to k8s/smalt-backend.yaml now diverges from the fact graph — the next sync doesn't overwrite it (different path), so the divergence is visible by diff, killable by retiring the hand-written file.
- No lib/ changes — zero test impact. `written: []` replay confirms no render nondeterminism.
- kubectl on the default kubeconfig fails with `unable to load root certificates` (redacted certificate-authority-data in ~/.kube/config — pre-existing, unrelated); the kind-exported kubeconfig is the working path.

## Upstream PR packaging (typed, prepared)

`packs/smalt-k8s-pack/` (pack.toml, ontology.ttl, template, 4 gates) applies to kubernetes-workload-pack as v0.3.0: StatefulSet/headless/multi-port/env/volumes modeling + gates 030/040/050 + gate 020 allowlist extension for block properties (or the VolumeMount-individual form, which needs no 020 change). Not filed this lane (cross-repo, not this lane's lease).
