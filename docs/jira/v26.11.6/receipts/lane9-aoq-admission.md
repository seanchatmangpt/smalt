# Lane 9 — AoQ micro-batch SHACL admission (WO-10 promotion + admit_batch)

Standing: ALIVE

Lane: 9 (v26.11.6 wave). Repo: /Users/sac/smalt (canonical checkout, no
commits — coordinator owns git).

## Scope landed (all ALIVE on disk, verified below)

- `mix.exs` — WO-10 promotion: `{:ash_graphlaw, path: System.get_env("ASH_GRAPHLAW_PATH") || "../ash_graphlaw"}`,
  `only:` and `optional:` dropped (unconditional path dep, relocatable).
  mix.exs:124-133.
- `lib/smalt/graphlaw_ex/shacl_admission.ex` — deleted the stale
  "engine-rejected wholesale" WO-09 paragraph (disproved by G2's court, which
  metashape-validates the whole canonical file with NO override — cited, not
  duplicated); added `:shacl_module` opt (court-only seam, never a default)
  and `:data_fold` opt (length-prefixed fold expansion
  `<<len::32-unsigned-big, frame::binary-size(len), ...>>`, newline-joined,
  one engine call per fold, truncated tail = typed
  `{:refused, :smalt_shacl_violation, %{data_fold: :truncated}}`).
- `lib/smalt/aoq/admission.ex` (NEW) — `Smalt.Aoq.Admission`:
  `encode_fold/1`, `batch_max/0` (32), `admit_batch/2`: fold → ONE
  ShaclAdmission.admit per batch (O(batches)); on
  `:smalt_shacl_violation` bisects to attribute `violating_frames`
  (`[{index, frame}]`, worst case log2(N) calls per violator); batch receipt
  = fresh sha256 over (engine_digest, shape_iri, per-frame hashes in order),
  NEVER the folded run's internal receipt; `AdmissionGate.gate("POST",
  envelope, body: fold, engine_digest: digest)` with a windowed ETS replay
  ledger (`:smalt_aoq_admission_ledger`, TTL `ledger_ttl_ms` default 60 s,
  never an unbounded MapSet); config key `config :smalt, :aoq_admission`
  (`enabled:` default true, fail-closed; independent of the HTTP gate key
  `:graphlaw_ex_gate`); every refusal emits
  `[:smalt, :aoq, :admission, :refused]` telemetry
  (`%{count: 1}` / `%{code, frame_count}`). Moduledoc names the shared-seam
  contract: ONE AshGraphLaw Host, two callers (this module + L16's
  ARM drain-boundary admit); court overrides (`:shacl_module`/`:shapes`)
  are opt-only, never defaults.
- `test/fixtures/aoq_admission/` (NEW corpus) — `conforming_frame.ttl`,
  `violating_crc.ttl`, `violating_oov.ttl`, `manifest.exs`
  (file → expected verdict class).
- `test/smalt/aoq/admission_test.exs` (NEW court) — 12 tests: fold wire
  form, batch_max pin, non-list typed refusal, conformance corpus
  (per-file verdict vs manifest), mixed-batch bisect attribution
  (`[{2, _}]` for a violator at index 2 of 4), mutation flip court
  (flip → refuse → flip-back → admit, flip-back uses a distinct frame list
  because an identical re-admit is correctly a replay refusal — the ledger
  law proved as part of the court), fresh-receipt law (same list → same
  receipt, different list → different receipt), replay refusal, TTL-window
  re-admit, `enabled: false` passthrough, engine-absent leg via
  `:shacl_module` seam, seam-never-a-default leg.
- `justfile.d/08-publish-dry.just` (append-only rider) +
  `scripts/publish_dry_rider.sh` — WO-10 regression gate: mix.exs must not
  carry `only:`/`optional:` on ash_graphlaw; rg fail-loud guard. Exit 0 = PASS.

## Verification ladder (commands + exits, run this session)

- `MIX_BUILD_ROOT=_build-lane9 mix compile` → exit 0 (COMPILE-GREEN);
  re-run after final edits: exit 0, zero warnings in my two lib files
  (checked with targeted grep after touch-recompile).
- `MIX_BUILD_ROOT=_build-lane9 mix test test/smalt/aoq/admission_test.exs
  test/integration/graphlaw_canonical_shapes_court_test.exs
  test/graphlaw_ex_gate_court_test.exs test/graphlaw_ex_gate_config_test.exs
  test/integration/graphlaw_shacl_admission_test.exs` → **Result: 33 passed**
  (my 12 + G2's canonical court 5 + gate court + gate config + WO-09 shacl
  suite; final run after the last assertion fix).
- `bash scripts/publish_dry_rider.sh` → exit 0
  "PASS: ash_graphlaw dep is unconditional (ASH_GRAPHLAW_PATH-relocatable,
  no only:/optional:)".
- Engine probe receipts (mix run /tmp/lane9_probe*.exs, real wasm engine):
  admit(raw fixture) ok; batch x1/x2 ok; mixed batch refuses with bisect
  attribution; oov/crc refusals typed.

## G2 court citation (lease-closing leg)

G2's test/integration/graphlaw_canonical_shapes_court_test.exs already
proves whole-file canonical validation (metashape-validates
priv/ontologies/public-cloud-core.ttl with NO :shapes override, 5/5 passing
in this session's runs). My lease leg was the shacl_admission.ex doc flip
only; I did NOT duplicate the court.

## Disclosures

1. **worker.ex attach NOT applied by this lane.** worker.ex is L5's lease;
   my SendMessage to L5 was refused (name not reachable from my session).
   The coordinator relayed the attach spec to L5: Worker.loop
   `{:aoq_frame, ...}` arm replaces the `_parsed` discard (worker.ex:76
   region) with micro-batch accumulation up to
   `Smalt.Aoq.Admission.batch_max/0` (32) dispatching
   `Smalt.Aoq.Admission.admit_batch/2`, dead-letter on refusal (Tables
   record + the telemetry admit_batch already emits). Disclosed in both
   receipts per the compile-freeze SLA.
2. **Corruption channel (4-lane class):** this lane's Write/heredoc channel
   injected duplicate-remnant blocks into shacl_admission.ex (three times)
   and admission.ex twice; every instance was caught by its own parser gate
   (`Code.string_to_quoted!` / mix compile) and repaired. Receipt honesty:
   the landed file is the REPAIRED file; the parser gate is the proof.
3. **Compile-freeze exposure:** other lanes' mid-flight files
   (lib/smalt/aoq/rdf_projector.ex, src/smalt_lakehouse_mount.erl)
   intermittently blocked shared compiles; handled by bounded polls,
   no unblock edits to non-owned files by this lane (L5's SLA-UNBLOCK
   marker on rdf_projector.ex was already present when I looked).
4. **Engine divergence candidate (needs a KD row, NOT fixed by this lane):**
   empirically witnessed on the REAL engine this session:
   `ex:unmodeled` on a prov:Activity frame REFUSES when the doc is
   frame-only (G2's @oov_frame, and my probe admit(oov-nosource) →
   {:refused, :smalt_shacl_violation}), but ADMITS when the same doc also
   carries the referenced cimi:StreamSource block (admit(oov-end) → {:ok};
   admit(oov) → {:ok}). sh:closed enforcement on prov:StreamFrameShape
   appears suppressed when the graph also contains the prov:used target
   node. Corpus fixture violating_oov.ttl uses the frame-only (refusing)
   form; the with-source admit is an open parity question for lane 8 /
   the engine owners.

## Pre-existing vs session-introduced

- Failing at session start: none observed in my suites' scope.
- Session-introduced and fixed: improper-list fold expansion (test-caught,
  fixed to iolist flatten), duplicate-clause remnants (corruption channel,
  repaired), test assertion drift (bisect pair shape, replay semantics of
  flip-back leg, value_class atom clause).
- Open pre-existing: ggen_igniter igniter type warnings, other lanes'
  in-flight churn (rdf_projector, lakehouse_mount, Dnszone rename) — not
  mine, disclosed for the drain.
