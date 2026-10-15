# ashdspy-pack integration — smalt

## Verdict

**PARTIAL_ALIVE — INAPPLICABLE-RUNTIME.** The pack landed as OFFLINE tooling
only; it never runs in the smalt data path.

## Pack evaluation

Pack: `../ggen-marketplace/packs/ashdspy-pack` v0.1.0 (pack.toml, ontology.ttl,
4 violation-row gates, 1 template `templates/lattice_summary.json.tmpl`,
anti-vacuity fixtures). Non-Python; RDF-only. **It projects no Elixir modules**
— its only template emits `generated/lattice_summary.json`, so the "project
Elixir signature/prompt modules via ggen_igniter" branch of the task does not
apply. The honest landing is therefore a consumer-side, pack-conformant
deterministic implementation, not a ggen projection.

The pack is NOT Python-centric and does NOT require an LLM at runtime — the
opposite: its gate 030 (`030_known_implies_no_llm.rq`) makes an LLM-selected
route a **typed refusal** whenever a non-LLM implementation of the same
signature holds a passing court verdict. That law is exactly the smalt
constraint ("any LLM call is a typed refusal at runtime"), so the pack's
vocabulary is adopted as the contract for the offline tool and the runtime
refusal is stated in the pack's own terms.

## What landed (all within owned files)

| file | what |
|---|---|
| `lib/smalt/dspy/remediation.ex` | `Smalt.DSPy.Remediation` — typed signature struct (surface/http/code/source/meaning/hint), deterministic `parse/1`, `propose/1` (adopts real hints verbatim, flags generator-boilerplate rows as needs_review), `court_verdict/1` (ashdspy:CourtVerdict analogue: rung `:reuse`, determinism score 1.0, llm_residue 0.0, sha256 verdictDigest), `render_review/3`, `run/2`, `evidence_digest/1` (gate 040 evidenceDigest shape) |
| `lib/smalt/dspy/tasks/dspy.remediation.ex` | `mix smalt.dspy.remediation [--doc ... --out ...]` — full offline run, writes the review file, prints a one-line summary |
| `test/dspy_test.exs` | 8 deterministic unit tests (real doc file, real IO into a per-run tmp dir deleted on_exit; no mocks, no network, no LLM) |
| `tmp/dspy/remediation_review.md` | witnessed output (runtime artifact, generated) |

## Mix alias candidate (documented, NOT wired)

`mix.exs` is outside this lane's owned files, so the alias is documented here
only:

```elixir
# mix.exs aliases() — candidate, not applied:
"dspy.remediation": ["smalt.dspy.remediation"]
```

## Runtime refusal (standing law)

Any proposal to call an LLM for this signature at runtime is refused per
ashdspy gate 030: `Smalt.DSPy.Remediation` is a Reuse-rung (1/8) non-LLM
implementation holding a passing deterministic verdict, so Allocation_LLM = 0
for this signature. `Smalt.DSPy.Remediation` contains no LLM, network, or
clock anywhere in its code path (auditable in the file; nothing to disable).

## Receipt

- Subject: smalt @ docs/ERROR_CODES.md evidenceDigest
  `e583637b0fd6e871729eb3d8c057161ab2bac70a244ef84191dba1e7c2606864`
  (sha256 of the exact doc bytes at receipt time; no git HEAD available —
  this directory is not a git repository, so the doc digest is the identity
  anchor). Not a git repo → no commit/SHA; file identities above.
- μ (manufacture): handwritten Elixir, 3 files (~330 lines) + generated
  review file; generated-vs-handwritten = 0 generated source bytes from the
  pack (pack projects JSON only). No edits outside owned files.
- Commands / exits:
  - `MIX_ENV=test mix test test/dspy_test.exs` → **BLOCKED pre-existing**:
    `lib/smalt/graphlaw/shacl_projection.ex:206` — `target_display/1`
    undefined, project-wide compile abort. NOT introduced by this lane (file
    outside owned set; in-flight lane build roots `_build-ft-*` present).
    Compile-freeze SLA not exercised by this lane since the file is not
    owned here; disclosed to coordinator.
  - Standalone real gate instead: `elixirc lib/smalt/dspy/*.ex -o /tmp/dspy_ebin`
    → exit 0; `elixir -pa /tmp/dspy_ebin -e 'ExUnit.start(); Code.require_file("test/dspy_test.exs"); ExUnit.run()'`
    → **8 tests, 0 failures**.
  - `mix smalt.dspy.remediation` (standalone, real binary) → wrote
    `tmp/dspy/remediation_review.md`, 53 rows: 46 adopted, 7 needs_review,
    digest-bound to the exact doc bytes.
- Verification ladder: unit (8/0 green, standalone) → real end-to-end file IO
  witnessed. Full-project `mix test` BLOCKED by the pre-existing
  shacl_projection.ex compile abort, which is the one blocking hop for
  `mix test test/dspy_test.exs` specifically.
- Standing: PARTIAL_ALIVE (offline). Runtime stance: INAPPLICABLE-RUNTIME.
- Falsifiers (each runnable):
  1. Inject `| egress | 404` (4-cell row) into a copy of the doc → `parse/1`
     must raise `ArgumentError ~r/malformed ERROR_CODES row/` (test 4
     witnesses this).
  2. Mutate docs/ERROR_CODES.md by one byte → evidenceDigest in a re-run
     review file must change (sha256 over doc bytes).
  3. Introduce any LLM/network call in the runtime data path for this
     signature → gate 030 law refuses it; grep of lib/smalt/dspy/ for
     `Req|HTTPoison|:httpc|:ssl` must stay empty.
