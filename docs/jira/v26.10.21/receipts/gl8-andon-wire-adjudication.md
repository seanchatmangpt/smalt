# GL-8 Adjudication — ANDON Wire-Shape Conflict (skeptic vs fullstack courts)

**Standing:** ALIVE
Context: solo
Date: 2026-10-21
Lane: GLADJ, build root `_build-gladj`, repo `/Users/sac/smalt`
Adjudicates: `gl8-andon-wire-face.md` (PARTIAL_ALIVE) honest-failure item 1

## Ruling

The canonical shape is `Smalt.Powl2.AndonWire` (union design): canonical 422
envelope (`{"error": {...}}`, `code: "GraphlawRefusal"`,
`x-ms-error-code: BusinessLawViolation`) with the GL-3 JSON-LD receipt
embedded as `error.json_ld`. The rival narrower pins are re-pinned:

1. **`test/integration/graphlaw_fullstack_court.exs:83`** — the `ex:`-prefixed
   rule id pin was the rival shape. `LawCompiler.compile_shape/2` mints rule
   ids from `local_name(shape_iri)` (`build_guard(local_name(shape_iri),
   shape)`, law_compiler.ex:91), so the canonical rule id is
   `"HighValueOrderShape/maxInclusive/totalAmount"` (no prefix). Re-pinned;
   this is the pre-existing failure the GL-8 receipt disclosed (court failed
   earlier at line 83, never reaching its AndonWire legs).
2. **`test/integration/graphlaw_skeptic_court.exs` C4 `http_envelope/2` leg** —
   the rival legs named in the GL-8 receipt (`http_envelope/1` json_ld body,
   `http_envelope/4` convenience, untyped-FunctionClauseError FINDING) were
   already re-pinned to the canonical envelope by the GL-8 lane's mid-session
   rewrite (verified on disk: all four C4 wire legs assert the canonical
   module's shape). Strengthened the leg per the adjudication contract: the
   embedded `error.json_ld` must be present AND well-formed — Jason
   round-trip, `"@type" == "andon:RefusalReceipt"`,
   `andon:failedConstraint == rule_id`, PROV-O context present.

Adversarial intent preserved untouched: bypass probes (C1), representation
fuzz (C2), digest-collision FINDINGs (C3), fail-closed probes (C4) all
unchanged in mechanism; only shape assertions updated.

## Diff

- `test/integration/graphlaw_fullstack_court.exs` — rule_id pin
  `ex:HighValueOrderShape/...` → `HighValueOrderShape/...` with adjudication
  comment; `_diag` unused-variable fix.
- `test/integration/graphlaw_skeptic_court.exs` — json_ld well-formedness
  assertions (Jason decode + @type + failedConstraint + PROV-O context).

No `lib/` changes. No shared infra touched.

## Courts (real output)

```
$ cd /Users/sac/smalt
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
$ MIX_BUILD_ROOT=_build-gladj mix test test/internal/powl2_andon_wire_court.exs \
    test/internal/powl2_andon_court.exs test/integration/graphlaw_skeptic_court.exs \
    test/integration/graphlaw_fullstack_court.exs
Result: 43 passed
```

(individually: skeptic 17 legs, fullstack 2 legs incl. the lawful-run control,
andon wire 6 + andon court 18 = 41 pre-adjudication, 43 total post)

## Standing

ALIVE — all three courts green on the canonical union envelope; the GL-8
receipt's open adjudication item is closed. Falsifier intact: the skeptic
court still refuses a flipped envelope shape (json_ld decode + typed-field
asserts), the fullstack court still seals refusal-inclusive Merkle roots.
