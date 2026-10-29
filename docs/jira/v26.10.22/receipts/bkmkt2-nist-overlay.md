# Receipt: bkmkt2-nist-overlay — NIST packs witnessed against the smalt k8s fact graph

**Standing: PARTIAL_ALIVE** — the two NIST packs' queries and all 22 gates were
actually executed against the union graph (pack ontologies + `priv/smalt-k8s.ttl`
+ new overlay facts `priv/smalt-nist-overlay.ttl`); technique inventory rows are
real outputs, every control mapping below is typed satisfied/partial/absent with
a named smalt receipt. The gates' empty result sets are themselves a typed
finding (vacuous-admission boundary), not a pass.

Context: solo. Lane BK-MKT2, v26.10.22, repo /Users/sac/smalt.

## What landed

| File | What |
|---|---|
| `priv/smalt-nist-overlay.ttl` | 16 triples asserting exactly two SP 800-160 Vol.2 techniques — `cr:PrivilegeRestriction` (both workloads, `cr:leastPrivilege true`, provenance = the BK-MKTG gate-020 negative control) and `cr:Segmentation` (backend only, pod-securityContext boundary) — each with `rdfs:seeAlso`/`prov:wasGeneratedBy` pointing at the witnessing receipt. Deliberately asserts nothing else. |
| `docs/jira/v26.10.22/receipts/bkmkt2-nist-overlay.md` | this receipt |

No `lib/`, `test/`, manifest, or register changes — zero test impact.

## Query execution (embedded output, full log `/tmp/bkmkt2/overlay_output.txt`)

Union graph: zta ontology 168 triples + cr ontology 386 + `smalt-k8s.ttl` 429 +
overlay 16 → 445 total. Runner: python3 + rdflib 7.6.0 (`ggen` 26.10.11 has no
bare `query` subcommand — `graph`/`law` only).

```
=== QUERY pack: 01_technique_crosswalk.rq  (cr pack, 14 rows)
AdaptiveResponse | AnalyticMonitoring | ContextualAwareness | CoordinatedProtection |
Deception | Diversity | DynamicPositioning | NonPersistence | PrivilegeRestriction |
Realignment | Redundancy | Segmentation | SubstantiatedIntegrity | Unpredictability
  (all prov:wasDerivedFrom NIST_SP_800_160_V2R1)

=== QUERY pack: 02_benchmark_surface.rq  (zta pack, 6 rows)
DERTR, DEZTR, GDPCR, OZTRR, VAR, VDECR — zta:BenchmarkMetric inventory

=== QUERY pack: 01_control_crosswalk.rq  → (empty result set)
typed: the zta crosswalk requires zta:sourceFragment on each ControlPattern;
the zta ontology declares 4 NISTDerivedPattern without fragments → the pack's
own crosswalk cannot render against its own ontology alone. Pack-level gap,
not a smalt gap.

=== QUERY pack: 02_generation_surface.rq → (empty result set)
typed: no cr:GenerationalResiliencyProfile exists anywhere in the union —
smalt deliberately does NOT fake one (a profile demands digest-bound
generation identity smalt does not carry).
```

Gate execution (all 7 zta gates + all 15 cr gates): **every gate returned an
empty result set.** Typed honestly: an empty set is *admission at that gate
only*, and it is vacuous here — smalt asserts none of the gated classes
(`zta:VerifiedCompletion`, `zta:TrustedBuild`, `cr:GenerationalResiliencyProfile`
…), so there is nothing to refuse. The overlay's `cr:hasPolicy` statements sit
below profile granularity, so gate 10 (segmentation/privilege) cannot see them.
The overlay assertions are witnessed by receipts, not gate-enforced; the only
*mechanical* enforcement in the chain remains kubernetes-workload-pack gate 020
over `priv/smalt-k8s.ttl` itself.

## Control mapping (control → smalt evidence, honest)

The packs anchor to SP 800-207 / 800-207A (zta) and SP 800-160 Vol.2 Rev.1 (cr:
14 techniques). BK-MKTG named the 800-53-class follow-ups (AU/SC-7/CP-9/
IA-5(1)/RA-5); mapping those onto the packs' vocabulary:

| Control class | Pack surface | Status | Smalt evidence |
|---|---|---|---|
| Least privilege (AC-3/AC-6-adjacent, 800-207) | cr:PrivilegeRestriction; zta gate 04 `leastPrivilege` | **SATISFIED by construction** | k8s securityContext (runAsNonRoot 65534, drop ALL, allowPrivilegeEscalation:false) admitted as facts; **mechanical**: pack gate 020 refuses regressions — negative control witnessed (FM-PACK-013, sync exit nonzero) — `bkmktg-pack-render.md` |
| Segmentation (partial, SC-7-adjacent) | cr:Segmentation | **PARTIAL** | pod-level nonroot/fsGroup boundary only (BK-K8SM, kind-validated); no NetworkPolicy facts exist — SC-7 proper is ABSENT below |
| CM-class drift control (CM-2/3/6) | cr:SubstantiatedIntegrity (`immutableSourceDigest`) | **SATISFIED (docs/projection layer)** | manifests are render outputs of a BLAKE3-hashed graph (`graph_hash_hex` per sync, `bkmktg-pack-render.md`); citation drift fence witnessed ALIVE — `bkciteg-citation-fence.md` |
| AU-class auditing | cr:AnalyticMonitoring / cr:ContextualAwareness | **PARTIAL** | fault-free fallback envelopes on EgressRouter/ArmGateway/Mcp witnessed — `bkegs1-fallback-fence.md`; telemetry semconv registry exists; **no control-plane audit-log surface** (AU-2 class) |
| CP-class recovery | cr:Redundancy / cr:NonPersistence | **PARTIAL** | crash-fallback timeline + quiet-window rerun green — `bkgwsq-discharge.md`; swarm court witnessed `{:node_down, B}` with A/C serving + fresh B re-join (`bkswarm-court.md`); **no CP-9 backup/restore path** (no PVC, no snapshot court) |
| SC-7 (boundary protection) | cr:Segmentation policy | **ABSENT** | no NetworkPolicy in fact graph or manifests; pack backlog; hand-written manifests carry none |
| IA-5(1) credential management | zta gate 03/04 identity | **ABSENT** | `RELEASE_COOKIE` Secret is `replace-me-before-apply` (typed in `bkk8sm-manifests.md`); no rotation mechanism |
| RA-5 vulnerability scanning | zta gate 06 `securityValidationDigest` | **ABSENT** | no trivy/kubescape wired; no scan receipt |
| Trusted build (zta gate 06) | cr:SubstantiatedIntegrity digests | **ABSENT** | no SBOM, no independent rebuild, no build provenance digest in any smalt receipt |
| zta terminal evidence (gate 01) / verified answer (05) | — | **ABSENT (out of scope, honestly)** | these gate data-engineering/OLAP workflows smalt does not run; not a defect — a boundary |

## Typed work items for the ABSENT controls (real mechanisms, no doc-theater)

| # | Control | Minimal real mechanism |
|---|---|---|
| W1 | SC-7 | Add `k8s:networkPolicyBlock` facts for both workloads + a new pack-style gate `030_networkpolicy_required.rq` refusing any `k8s:Workload` without one; render into manifests. Default-deny becomes gate-checked like privilege. |
| W2 | IA-5(1) | Replace the placeholder cookie: `k8s:envFromSecret`/secretKeyRef fact wired to a generated Secret (smalt's existing per-host SAS derivation pattern), plus a gate refusing the literal `replace-me-before-apply` in any admitted fact. |
| W3 | RA-5 | `just scan` recipe: trivy over `smalt:local`/`smalt-console:local`, output a dated receipt; sync gate refusing manifest regeneration when the newest scan receipt predates the image fact. Receipt-gated, fail-closed. |
| W4 | CP-9 | Snapshot court in the shim-court pattern: real snapshot → restore → sha256 byte-exact (state tables), RESTORE fail-closed — reuses `scripts/shim_court/lib.sh`; a restore that cannot flip a write is a vacuous court. |
| W5 | AU | Feed k8s control-plane events into smalt's existing OCEL tap (primitive F, `zcode-cli:src/ocel-tap.ts` pattern / `xaas` OCEL-NDJSON) instead of minting a second audit subsystem. |
| W6 | zta gate 06 class | syft SBOM digest + independent-rebuild digest recorded per release in the milestone receipt; law-graph `cr:SubstantiatedIntegrity` facts only when both exist. |

Sequencing: W1/W2 are fact+gate work in the existing graph (cheapest, same
shape as gate 020); W3–W5 are new recipes/courts; W6 rides a release.

## Falsifiers / boundary

- F1: `priv/smalt-nist-overlay.ttl` asserts a technique whose witnessing
  mechanism is later removed from `priv/smalt-k8s.ttl` → overlay is stale; a
  successor gate over the union should refuse overlay assertions whose
  `k8s:` support triple is gone (not built this lane — typed follow-up).
- F2: any ABSENT row above becomes SATISFIED without a new mechanism/receipt
  = overclaiming; each flip needs the named work item landed.
- Boundary: no live cluster this session — no in-cluster dry-run; the overlay
  is graph + receipt only. Pack queries/gates ran over the union graph via
  rdflib; `ggen sync` was not re-run (facts unchanged).
