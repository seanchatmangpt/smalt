# Ash-Generation Wave 1 — Resolutions (2026-10-29)

Lane reports integrated; conflicts resolved; wave-2 readiness per file ownership.
Canonical KD register: ../v26.10.14/KNOWN_DIVERGENCES.md (183 rows; 5 OPEN: KD-168/174/177/178/179; mint from KD-187). Draft rows in section 4.

## 1. Landed this session (ALIVE receipts)

- `mix test test/smalt_ash_gen_test.exs` -> **5/5 passed** (exit 0), including:
  idempotent second-run zero-diff; real-Ash compile smoke + ETS roundtrip
  (upsert insert/update, read, get_by_arm_id, destroy under real Ash 3.36.1).
- `mix compile` exit 0; `MIX_ENV=dev mix compile --warnings-as-errors` exit 1
  with **zero warnings referencing the new files** (baseline main = exit 1,
  35 pre-existing warnings; recorded, not absorbed).
- ggen extraction at scale: **782 models / 548 parent rows** via
  GgenIgniter.Query.run (graphlaw), UNION+OPTIONAL, string-keyed plain rows.
- Full-scale dry-run (clean pass, L6): **638 new files / 751,540 bytes,
  pure-create landing** (0 updates/deletes), deterministic across 3 runs.
- `mix smalt.gen.ash` task ALIVE: positional ontology path, harmonized
  dual-vocabulary SPARQL (ggen.io + bicep vocab), framework --dry-run.

## 2. Lane decisions (integrated)

- **L1 CLOSED-WITH-RECEIPT** (landed before dispatch): idempotency root cause =
  Ash.Domain.Igniter.add_resource_reference -> list_domains reads
  Application.get_env(app, :ash_domains) -> [] (not :error) ->
  upgrade_plain_module_to_domain rewrites domains + injects config, breaking
  replay idempotency. Fix: self-contained membership-checked zipper
  (register_in_resources_block), documented rejection comment in generator.ex:65.
  get_by arm_id via Ash.Query.for_read + Ash.read/1.
- **L2 mount plan**: one-line `plug(Smalt.ArmGateway.CanonicalRouter)` after
  router.ex:81 (FunctionsRouter mount), before plug(:match):82. Five-clause
  claim guard: halted==false; method in PUT/GET/PATCH/DELETE; ARM rg shape;
  AshGen Registry lookup (longest-first type_path, case-insensitive fallback
  per find_admitted law); otherwise-404 exclusion list ([type], [type,name],
  [type,name,"providers"|_]). Code.ensure_loaded? guard degrades to
  pass-through when the generated registry is absent. Negative court: 16-corpus
  direct-dispatch tests + probe set (a)-(f). Drift contract: pre-:match seam
  means future deep-shape routes must extend the exclusion list.
  Corrections: FunctionsRouter IS mounted (router.ex:81); typed catch-all
  match _ -> RouteNotFound EXISTS at :8413-8422 (wave-0 premise corrected).
  Bonus: dead byte-duplicate DELETE route at :8115 (court item, not wave 2).
- **L3 decision**: NO config :smalt, ash_domains needed (dispatch resolves
  domain: at use-site; config-free roundtrip smoke is the standing proof).
  Route (a) ontology ConfigKey REFUSED by closed census law; route (c) REFUSED
  (no reader). Landed one-liner: domain_body emits
  `use Ash.Domain, validate_config_inclusion?: false` (matches 4 checked-in
  domains; prevents latent IO.warn under warnings-as-errors).
- **L4 classification**: cosmos etag-CAS and queue FIFO (ordered_set term-order
  + $seq counter row) must stay hand-rolled OR wait for a custom Ash.DataLayer
  wrapping Smalt.Store (design sketched: honest can?/2 surface, filter-CAS op
  generalizing compare_and_swap/4, custom Ash.Error carrying winner_etag for
  the 412+ETag echo). Blob gates: PARTIAL (validations map; ordered wire-error
  precedence + tail CAS stay). Ledger: REFUSED (append-only WAL).
  **New pre-existing defect**: appconfig kv etag-CAS is TOCTOU
  (egress_router.ex:1496-1548: Store.get -> check -> Store.put, no
  compare_and_swap) - the invariant gate's exactly-one-winner arm is
  probabilistic. Repair lane + KD row needed; egress_router.ex is another
  lane's in-flight file (blocked until theirs lands).
- **L5 authz design**: actor = verified bearer claims (bearer.ex discards them
  today - one disclosed additive seam: stash conn.private[:smalt_actor] or
  re-verify); threading via Ash.create opts actor: + context: (ash.ex:458);
  checks as Ash.Policy.SimpleCheck reading the RBAC named ETS tables directly
  (memoized by authorizer facts); policies evaluate BEFORE commit
  (create.ex:185->186, destroy.ex:150, update.ex:393). Stays out: bearer authn,
  api-version admission, graphlaw gate, SharedKey/Cosmos tokens,
  Policy.enforce receipt-writes.
- **L6 census**: registry {provider, type_path} collisions = 0 (structural).
  Module-name collisions: 782 models -> 621 distinct modules (99 colliding
  pairs; leaf-only naming + TTL case variants). **Fixed this session**
  (naming law: xes/es/ses split, case-variant dedup preferring camelCase;
  proof output: databases->Smalt.Sql.Database, publicIPPrefixes->PublicIPPrefix,
  dnsZones deduped to DnsZone). Formatter drift: 0 (trailing-newline artifact
  resolved; 639/639 byte-identical). Compile: 637 modules 62.3s serial, 0
  errors - full landing trivially CI-feasible. **CI bug**: --dry-run on >=1000
  line diffs prompts and crashes on non-tty (String.trim(:eof)) - fix: --yes
  in CI or non-tty auto-noop. Registry merge policy: read-modify-write union
  needed before slice 1 (current full-set overwrite would point at unlanded
  modules). First slice: --provider Microsoft.Network = 181 files.
- **L7 register drafts** (mint via kd-registrar; flips only via
  scripts/kd_flip.py --apply on PASS witness. RENUMBERED 2026-10-30 by the
  v26.10.31 wave-2 kd-registrar lane: these DRAFT ids were never minted in
  the canonical register, but the canonical ids KD-187/KD-188 have since
  been minted there (container-namespace disconnect CLOSED-OBSOLETE;
  managementPolicies route OPEN) — draft ids moved to KD-190/191/192 to
  keep the canonical register monotonic; original draft ids preserved in
  git history):
  scripts/kd_flip.py --apply on PASS witness): KD-190 (Ash-ETS volatile vs
  Store durability), KD-191 (shape-shallow synthesis; bicepRef dropped on the
  floor), KD-192 (no Ash policies yet; must map onto Bearer/STS fence per
  v26.10.16/ash-kudzu-integration.md:27), GAP(canonicalrouter-mount-absent)
  (PLANNED status). Hygiene: GAP(blob-comp-lease-absent) token closed-but-
  present at WIRE_PARITY.md:135 (machine grep over-counts by one); stale
  WIRE_PARITY:148 anchor in KD-19.

## 3. Wave-2 readiness + hazards

Ready (disjoint ownership):
- W1: DONE (this session; 5/5).
- W3: replay fence test (pattern:
  docs/jira/v26.10.18/burn/test/config_replay_identity_test.exs) - needs the
  slice landed first (W4) or runs --dry-run subprocess against staged ttl.
- W4: staged landing slice 1 Microsoft.Network (181 files) - BLOCKED on W2a
  task flags (--provider + registry merge + non-tty fix), which are in
  generator/task files owned by this lane; then census gate.
- W5: config flag :smalt, :ash_gateway default-off + L5 policy template -
  new files, safe.

Hazards (serialize, do not fan out):
- **router.ex is HOT**: another lane's in-flight edits (33 modified files at
  last census). W2 (CanonicalRouter mount) edits router.ex - must wait for the
  concurrent lane's landing or negotiate the seam; compile-freeze SLA applies.
- egress_router.ex (L4 appconfig-CAS repair) - same conflict class.
- appconfig TOCTOU defect: file a repair WO + KD draft row; do NOT fix inside
  wave 2 (different surface, hot file).

## 4. Register drafts (mint-ready, status DRAFT - UNVERIFIED)

| id | surface | divergence | close condition / falsifier |
|---|---|---|---|
| KD-190 | ash_gen ETS datalayer | Ash tables lack WAL/Heir/CAS/DETS | custom Ash.DataLayer wrapping Smalt.Store + restart falsifier |
| KD-191 | shape-shallow synthesis | arm_put admits payloads the ARM wire face refuses (GraphLaw 400 InvalidResourceShape) | bicepRef property-lift; same-payload two-faces probe |
| KD-192 | authz | no Ash policies; Bearer/STS fence only | policy lands mapping onto fence + non-vacuity court |
| GAP(canonicalrouter-mount-absent) | ARM dispatch | registry has no consumer; plugs unmounted (3 of 4) | mount + wire test byte-matching Ash face vs Store face |
