# GAP-04: Neutral-Core Diagnostic Vocabulary (v26.10.31)

Lane 4 of 17, unification-dialect migration. Reads: `00-unification-dialect-decision.md`,
gaps/57+70 (error ergonomics audits, v26.10.30), gaps/26 (turnstile fence), gap-01
(STS classification). Scope: the typed refusal classes the neutral core must own, the
wire envelope dialects project into, and which existing diagnostics re-shape.

Status: **PARTIAL → ALIVE (Go wire layer landed; BEAM projection pending post-strip)** —
pre-strip witness court landed: `smalt:test/internal/diagnostic_envelope_court_test.exs`
(falsifier `MIX_BUILD_ROOT=_build-lane-g04 mix test test/internal/diagnostic_envelope_court_test.exs`
→ exit 0, 11/11 passed, 2026-10-30). Close-conditions 1–7 carry a verified residual
table below (file:line re-grepped this session). **W1–W4 landing site (from gap-10's
law register, gaps/10-spike-residuals.md:54-73)**: the four NEUTRAL-CORE wire laws
land HERE —
— the six neutral classes are now a Go wire type at `posh/internal/diag/wire.go`
(`Class`, closed 6-value set, `NewRefused` typed constructor reusing
`api.NewRefusedEgress` semantics — no new wire codes; ENRICHMENT_GAP rides
`api.CodeUpstream` via `NewGap`; `ParseClass` byte-exact, unknown/mutated classes
refuse; `Envelope`/`EnvelopeOf` project the gap-doc JSON envelope with `code`
kept as the dialect compatibility literal). Falsifier:
`cd posh && go build ./internal/diag/... ./internal/api/... && go vet ./internal/diag/... && go test ./internal/diag/... -count=1`
→ exit 0, 9/9 tests pass incl. `TestClassesDistinctStableWireStrings`
(distinct stable wire strings + JSON round-trip) and `TestUnknownClassRefuses`
(mutated/whitespace/case/unknown all refuse; the strictness flip was itself
witnessed: a first draft of ParseClass trimmed input and the table test failed
it before the fix). Full `go build ./...` is blocked by
`posh/internal/tui/script_source.go` (unused imports, untracked dir owned by
another lane — pre-existing to this lane, not caused by diag). Remaining for
full close: close-conditions 1–7 below are BEAM-side (send_core_error helper,
fence detail promotion, harness class assertions, MCP mount 501, coverage
compiler DIALECT_DRIFT, envelope validator court, byte-compat witness).

**Post-strip wiring point (projection note)**: `lib/smalt/arm_gateway/plug/common.ex:148`
`send_arm_error/5` (READ ONLY — not edited by this lane) consumes the neutral
envelope post-strip by extending its body with the three additive fields the
Go `diag.Envelope` now fixes: `class` (from `EnvelopeOf`'s class, one of the
six), `dialect` (closed set: core/azure-arm/identity/smalt-cli/harness-ts,
validated by `diag.DialectIsKnown`), `receipt` (turnstile hex or loud-absent
`nil`). The BEAM side keeps `code`'s existing literal byte-for-byte
(`AdmissionRefused`, `InvalidApiVersionParameter`, …) so the fence-court grep
at `justfile.d/58-posh.just:281` and `SmaltVersionError.fromResponse`
(caai `apps/web/test/harness/version/lib.ts:160`) survive unchanged;
`UNSUPPORTED(tls-variant-absent)` (mcp/router.ex:79) is promoted from
doc-register to `diag.NewRefused(ClassUnsupportedFace, …)` — wire shape is the
neutral 501 envelope, class `UNSUPPORTED_FACE`.

## Evidence base (all read this session)

- `smalt:lib/smalt/arm_gateway/plug/common.ex:148` — `send_arm_error/5`, the ARM
  envelope builder: `{"error": {code, message, target?, innererror:{}, details?}}`.
- `smalt:lib/smalt/arm_gateway/plug/receipt_turnstile.ex:139-158` — fence refusal
  already emits a typed 400 `AdmissionRefused` envelope with `{:shape_violation,
  violations}` folded into `message` as prose.
- `smalt:lib/smalt/mcp/router.ex:79` — `UNSUPPORTED(tls-variant-absent)`: today a
  doc-comment register, not a wire type.
- 400 `InvalidApiVersionParameter` emit sites (VERSION_CEILING class):
  `container_apps_router.ex:428`,
  `container_groups_router.ex:295`, `activity_log.ex:188`, `plug/resource_providers.ex:809`,
  `acr_router.ex:39,527`, plus the generic `router.ex:114` gate.
- `caai:apps/web/test/harness/version/lib.ts:127-164` — `SmaltVersionError.fromResponse`
  parses the 400, requires the body to name the latest supported version; harness-side
  carrier of the same class.
- `caai:apps/web/test/harness/vault/lib.ts:13,168` — `MissingSecretError(name, status,
  body)`: fail-closed typed error, no neutral class today.
- `smalt:justfile.d/58-posh.just:281-282` — the fence court greps for the literal
  `AdmissionRefused` in the 400 body: a byte-compatibility constraint on any re-shape.
- `smalt:scripts/posh_invariant_gate.py:17` — `[INVARIANT-GATE-SKIP]`: loud skip as a
  first-class outcome.

## Taxonomy — 6 neutral classes

Every core diagnostic carries four fields: `class` (the only dispatchable field),
`dialect` (which projection emitted it), `fix` (remediation named in-message — the
gaps/57+70 law), and `receipt` (turnstile hex when the refusal was settled into the
event log; absent/null = unstamped path, loud).

| # | class | meaning | closest existing shape |
|---|---|---|---|
| 1 | ADMISSION_REFUSED | mutating delta refused by admission | 400 `AdmissionRefused` (turnstile fence, receipt_turnstile.ex:158) — model row; core class name = existing wire code |
| 2 | VERSION_CEILING | requested api-version outside the supported ladder | 400 `InvalidApiVersionParameter` at the 7 sites above + harness `SmaltVersionError` |
| 3 | SHAPE_VIOLATION | payload failed the resource shape at a supported version | fence `{:shape_violation, violations}` — currently prose inside `message` |
| 4 | UNSUPPORTED_FACE | surface exists but no implementation for this variant | `UNSUPPORTED(tls-variant-absent)` register (mcp/router.ex:79) — doc-only today |
| 5 | ENRICHMENT_GAP | observation returned but a required enrichment is absent | no wire shape today; harness `MissingSecretError` is the nearest semantic (required input absent, fail-closed) |
| 6 | DIALECT_DRIFT | projection drifted from the core vocabulary | no wire shape today; kin of gaps/19 vocabulary-drift and gaps/16 allowlist-graph skew |

### Class boundary laws

- **VERSION_CEILING vs SHAPE_VIOLATION**: VERSION_CEILING owns the api-version ladder
  only. A payload-shape failure at a supported version is SHAPE_VIOLATION. Gate order:
  version before shape — this matches the existing router order
  (InvalidApiVersionParameter fires before the ACR pass-through, acr_router.ex:39).
- **ADMISSION_REFUSED vs SHAPE_VIOLATION**: the fence's `{:shape_violation, _}`
  reason is a SHAPE_VIOLATION carrying ADMISSION_REFUSED as its envelope class only
  when the class field is unavailable; under the neutral taxonomy the fence emits
  SHAPE_VIOLATION with `code: "AdmissionRefused"` kept as dialect code. The court at
  58-posh.just:281 greps `AdmissionRefused` and still passes (the `code` field keeps
  the literal).
- **ENRICHMENT_GAP vs UNSUPPORTED_FACE**: ENRICHMENT_GAP = the request was admissible
  and served, but a required enrichment (secret, label, tag, cross-resource read) was
  absent. UNSUPPORTED_FACE = the request was not admissible at all (no variant).
  `MissingSecretError` maps to ENRICHMENT_GAP-with-severity (missing input), not
  UNSUPPORTED_FACE.

## Wire envelope

Superset of the ARM envelope (`send_arm_error/5`), so dialect #1 stays wire-compatible
byte-for-byte where today's bodies already exist:

```json
{
  "error": {
    "class": "ADMISSION_REFUSED",
    "code": "AdmissionRefused",
    "message": "payload violates the arm.request shape: [...] — re-render with: just posh-generate",
    "target": "/subscriptions/.../resourceGroups/rg/providers/...",
    "innererror": {},
    "details": [],
    "dialect": "azure-arm",
    "receipt": "a1b2...",
    "skip": null
  }
}
```

- `code` keeps the dialect's existing literal (`AdmissionRefused`,
  `InvalidApiVersionParameter`, …). This is the compatibility face: the fence court
  grep and `SmaltVersionError.fromResponse` keep working unchanged.
- `class` is the neutral dispatchable field; dialects may not mint new class values.
  New behavior = new class in the core, not a new dialect code.
- `dialect` is one of `core`, `azure-arm`, `identity` (dialect #0 per gap-01),
  `smalt-cli`, `harness-ts`.
- `receipt` is the turnstile receipt hex when the path is stamped; `null` on unstamped
  paths (loud absence, never a fake hex).
- `skip` is non-null only on gate/court diagnostics (non-wire): `{"reason": "..."}`.
  On the wire, a skip never renders as a 2xx — a would-be skip is UNSUPPORTED_FACE or
  ENRICHMENT_GAP. (Loud-SKIP as a class is gate-tier, not wire-tier.)

## Mapping table — existing diagnostics → classes

| Existing diagnostic | Tier | Site | Class | Re-shape needed |
|---|---|---|---|---|
| 400 `AdmissionRefused` fence body | wire (smalt) | receipt_turnstile.ex:139-158 | ADMISSION_REFUSED (or SHAPE_VIOLATION detail) | add `class`/`dialect`/`receipt` fields; keep `code` literal |
| fence `{:shape_violation, violations}` prose | wire (smalt) | receipt_turnstile.ex:139-141 | SHAPE_VIOLATION | promote `violations` into `details[]` |
| 400 `InvalidApiVersionParameter` (x7) | wire (smalt) | sites in evidence base | VERSION_CEILING | route all 7 through one helper emitting the neutral envelope; keep code literal |
| `UNSUPPORTED(tls-variant-absent)` | doc-register (smalt) | mcp/router.ex:79 | UNSUPPORTED_FACE | promote to wire envelope on the MCP mount (501 with the neutral body) or keep as gate-tier skip with `skip.reason` |
| `[INVARIANT-GATE-SKIP]` | gate (smalt) | posh_invariant_gate.py:17 | gate-tier loud skip (`skip.reason`) | add `skip.reason` to the emitted row; class field optional at gate tier |
| `[SLA-REFUSE]` / `[POSH-*]` / `[TF-*]` justfile families | gate (smalt) | justfile.d/57+58+59 (gap-70 tables) | gate-tier; no wire class | bracket tags stay; optionally append `class=` token for the coverage compiler |
| `SmaltVersionError` | harness (caai) | apps/web/test/harness/version/lib.ts:127 | VERSION_CEILING | map cleanly — add a `class: VERSION_CEILING` assertion to fromResponse |
| `MissingSecretError` | harness (caai) | apps/web/test/harness/vault/lib.ts:13 | ENRICHMENT_GAP (missing-input severity) | add `class: ENRICHMENT_GAP` field on the TS class; no behavioral change |
| disjunctive-law asserts / KD rows | court (smalt) | KNOWN_DIVERGENCES.md + sdk_coverage.py | registered-divergence cells; DIALECT_DRIFT when a row's close condition fires | no re-shape; DIALECT_DRIFT is the class the coverage compiler raises when a KD row's evidence goes stale |
| GraphLaw 400 bodies | wire (smalt) | graphlaw validator/sql_row_gate | SHAPE_VIOLATION | emit the neutral envelope with `code` = existing GraphLaw literal |
| TF `error_message` validations | infra (caai) | infra/modules/tenant-apps/variables.tf:7, secrets.tf:79 | gate-tier; gaps/57 rows 21-22 | no class field; close per gaps/57 open rows |

## Audit — what needs re-shaping vs maps cleanly

**Maps cleanly (additive only)**: fence `AdmissionRefused` (add 3 fields, keep code),
harness `SmaltVersionError`/`MissingSecretError` (add class field), GraphLaw bodies
(same helper), the 7 InvalidApiVersionParameter sites (one shared helper). None of
these break the fence court grep or the harness fromResponse parser.

**Needs design work, not just fields**: UNSUPPORTED_FACE (no wire site today — must
pick the first live mount and a status code; MCP mount is the named candidate),
ENRICHMENT_GAP (no wire site; first consumer is the vault read path in the harness
tier), DIALECT_DRIFT (lives in the coverage compiler, not on a wire — its "wire" is
the coverage report cell).

**Compatibility constraints witnessed**: the fence court greps `AdmissionRefused`
(58-posh.just:281); `SmaltVersionError.fromResponse` requires the 400 body to name
the latest supported version in prose (version/lib.ts:160). Both survive the re-shape
because `code` and `message` keep their literals; `class` is additive.

## Close conditions

### Residual table (close-conditions 1–7, file:line re-verified 2026-10-30)

| # | Residual | Verified sites | Diff sketch (post-strip lane applies mechanically) |
|---|---|---|---|
| 1 | Shared helper `send_core_error/5` | `lib/smalt/arm_gateway/plug/common.ex:148` (send_arm_error/6 head); emit sites: `common.ex:243` (MissingApiVersionParameter), `common.ex:290` + `common.ex:309` (InvalidApiVersionParameter), `plug/resource_providers.ex:807-811`, `providers/container_apps_router.ex:428`, `providers/container_groups_router.ex:293-297`, `activity_log.ex:186-191`, `providers/acr_router.ex:39,527` (pass-through — keep delegating to the generic gate) | Add to Common: `def send_core_error(conn, status, code, class, dialect, message, target \\ nil, details \\ [], receipt \\ nil)` that delegates to send_arm_error then extends the error map with `"class"`, `"dialect"`, `"receipt"`. Convert each site: `send_arm_error(conn, 400, "InvalidApiVersionParameter", msg)` → `send_core_error(conn, 400, "InvalidApiVersionParameter", "VERSION_CEILING", "azure-arm", msg)`. Keep `code` literal byte-for-byte. acr_router delegates to check_api_version — no local builder exists (grep: only doc comments at 39/527), so rows collapse into the generic gate automatically. |
| 2 | Fence detail promotion | `lib/smalt/arm_gateway/plug/receipt_turnstile.ex:144-152` (reason_text prose fold), `:156` (send call) | Replace the `{:shape_violation, %{violations: vs}}` prose arm: `details = Enum.map(vs, &%{"violation" => inspect(&1)})`; emit `send_core_error(conn, 400, "AdmissionRefused", "SHAPE_VIOLATION", "azure-arm", "payload violates the arm.request shape", conn.request_path, details)` — keep the prose prefix in `message` (fence-court grep at `justfile.d/58-posh.just:281` greps `AdmissionRefused`, which is the `code`, so it survives) and keep the `{:shape_violation, _}` prose arm as fallback for non-shape reasons (`other` arm keeps class ADMISSION_REFUSED). |
| 3 | Harness class assertions | `/Users/sac/cai/courtroom-platform-az/apps/web/test/harness/version/lib.ts:127` (class SmaltVersionError), `:145` (fromResponse), `:158-161` (latest-naming throw); `/Users/sac/cai/courtroom-platform-az/apps/web/test/harness/vault/lib.ts:13` (class MissingSecretError) | version/lib.ts: add `readonly neutralClass = "VERSION_CEILING";` to SmaltVersionError; in fromResponse after decoding the 400 body assert `body.error.class === "VERSION_CEILING"` when present (additive — absent pre-strip is not a failure). vault/lib.ts:13: add `readonly neutralClass = "ENRICHMENT_GAP";` and a test asserting it. Falsifier guard: the existing fromResponse 400-parse test still passes with `class` absent (additive law). |
| 4 | UNSUPPORTED_FACE first wire site | `lib/smalt/mcp/router.ex:73-79` (doc register `UNSUPPORTED(tls-variant-absent)`); MCP mount is `use Plug.Router` — the 501 emitter goes in the `plug` pipeline before dispatch or a `match _` clause | In mcp/router.ex add a `match _` fallback (after existing routes): `defp tls_variant_absent(conn) do send_resp(conn, 501, Jason.encode!(%{error: %{class: "UNSUPPORTED_FACE", code: "TlsVariantAbsent", message: "no TLS variant for the MCP mount (UNSUPPORTED(tls-variant-absent)); recorded at router.ex:79", target: conn.request_path, innererror: %{}, dialect: "core", receipt: nil}})) end` — then update the doc register at :73-79 to cite the wire site. Falsifier (gap doc): register text and wire must agree on the class. |
| 5 | DIALECT_DRIFT emission | `scripts/sdk_coverage.py:685-700` (KD-annotation cells loop; `kd_cells` builder) | In the KD cell loop after resolving `row` and `paths`: add staleness check — if the row's close-condition references a shim (`KD-COVERS` grep of `lib/` for `# KD-COVERS: #{kid}` mtime) newer than the witness receipt mtime, render the cell `DIALECT_DRIFT` (exit 1 loud) instead of SIM-PASS. Falsifier: a stale KD row renders DIALECT_DRIFT, never a silent pass. |
| 5b | Envelope validator (close-condition 6) | `test/internal/diagnostic_envelope_court_test.exs` (this lane, landed) — post-strip extension point: the "no BEAM wire emitter carries a class field yet" test | After residual 1 lands, flip the pre-strip baseline test to assert the additive fields: `assert error["class"] in @classes`, `assert error["dialect"] in ~w(core azure-arm identity smalt-cli harness-ts)`, `receipt` binary-or-nil. Falsifier: a provider route emitting an error body without `class` fails the court (exit 1). |
| 6 | Byte-compat witness (close-condition 7) | `justfile.d/58-posh.just:275-282` (fence probe greps `AdmissionRefused` at :281) | After 1+2 land: `just posh-smalt-wire` must still exit 0 — the `code` literal survives the re-shape, so the grep holds with no justfile edit. If it fails, the re-shape broke byte-compat: revert, the class field must be additive-only. |

### W1–W4 law register (NEUTRAL-CORE wire laws, absorbed from gap-10 per lane-4 lease)

Landed HERE per gap-10's close condition ("Closing the landing site is a docs-only
edit... remains with lane 4's owner"). Source:
`gaps/10-spike-residuals.md:54-73`; dispositions and witnesses at
`gaps/10-spike-residuals.md:42-51`.

| Law | Definition (dialect-independent, binds any TF protocol-6 face) | Spike provenance | Go-membrane standing |
|---|---|---|---|
| **W1** | Unknown sentinel encodes as msgpack fixext1 `D4 00 00` (ext type 0, one-byte payload `<<0>>`), never the long-form ext header `C7 05 00 "value"` (TF rejects: `unsupported extension type 0x00 with len 5`). The fix lives in the provider's encoder, never a mid-wire shim (byte-shim REJECTED witness — length rewrite corrupts HTTP/2 DATA framing). | fix 1, `10-spike-residuals.md:42` | satisfied by construction (framework-owned encoder); `go build ./...` exit 0, 2026-10-30 |
| **W2** | Attr types round-trip the cty JSON type exactly: bool/number/map/list preserved, no flattening to string, no double-wrap under `:type`. Both failure shapes witnessed in the spike (fixes 5+6). | fixes 5+6, `10-spike-residuals.md:46-47` | satisfied by construction (framework schema serialization) |
| **W3** | Diagnostics-only error channel: state-adjacent payloads and errors ride the proto diagnostics field; private/tuple channels are not wire-proven. ARM errors surface as TF diagnostics, never as opaque wire errors. Pairs with lane 4's envelope (class/dialect/fix/receipt). | fixes 4+9, `10-spike-residuals.md:50` | mechanism died with the spike; law binds the core docs (this section) |
| **W4a** | A null/empty msgpack DynamicValue on the destroy face decodes to nil state, never raises. | fix 7, `10-spike-residuals.md:48` | satisfied by construction |
| **W4b** | Proto bytes fields take a single binary, never an iolist (`Msgpax.pack!(nil)` iolist in a `:bytes` field was the spike destroy-plan encode failure). | fix 8, `10-spike-residuals.md:49` | satisfied by construction |

W1–W4 are protocol-6/go-cty law — they bind any future dialect face speaking TF
protocol 6; the spike mechanisms (Elixir clause sets, tuple normalization,
`IO.iodata_to_binary/1`, `to_diag/1`) died with the spike; only these laws
migrate. Landing receipt: this edit (2026-10-30, lane g04) closes gap-10's six
LANDING-SITE OPEN rows (1, 4-law, 5, 6, 7, 8-law, 9-law) as a side effect.

2. **Fence detail promotion**: fence emits SHAPE_VIOLATION with `details[]` carrying
   the violations; court at 58-posh.just still exits 0. Falsifier: court fails on the
   re-shaped body, or violations remain prose-only.
3. **Harness class assertions**: `SmaltVersionError` gains `class: VERSION_CEILING`,
   `MissingSecretError` gains `class: ENRICHMENT_GAP`; tests assert the field.
   Falsifier: a test asserting only the instanceof still passes with class absent.
4. **UNSUPPORTED_FACE first wire site**: MCP mount emits the neutral envelope (501)
   for the tls-variant-absent case; the doc register cites the wire site. Falsifier:
   the register text and the wire disagree on the class.
5. **DIALECT_DRIFT emission**: the coverage compiler (sdk_coverage.py) raises a
   DIALECT_DRIFT cell when a KD row's evidence receipt predates a `lib/` shim it
   covers (KD-COVERS flip law, testing-chicago-style rule). Falsifier: a stale KD
   row renders pass instead of DIALECT_DRIFT.
6. **Envelope validator**: a court asserts every wire error body in the ARM gateway
   has a `class` field in the 6-value enum. Falsifier: a provider route
   emits an error body without `class` and the court exits 0.
7. **Byte-compat witness**: re-run `just posh-smalt-wire` after the re-shape; the
   fence court greps still pass. Falsifier: the grep at 58-posh.just:281 fails.

## See Also

`00-unification-dialect-decision.md` · gap-01 (STS dialect #0) · v26.10.30 gaps/57+70
(error ergonomics) · gaps/26 (turnstile fence) · `[[testing-chicago-style]]`
(KD-COVERS/KD rows) · `[[no-sleep-testing]]` (skip is loud, never a sleep)