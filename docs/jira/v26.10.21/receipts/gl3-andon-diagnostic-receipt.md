# GL-3 — ANDON Diagnostic Receipt (lib/smalt/powl2/andon.ex)

**Standing: PASS (module compiled, 8/8 court tests green on exact subject)**
Context: solo

## Module

`lib/smalt/powl2/andon.ex` — `Smalt.Powl2.Andon`

- `format_andon(rule_id, diagnostic, context_snapshot, opts)` → typed receipt
  map: `rule_id`, `diagnostic`, `repair_hint`, `agent_message`
  (`"[ANDON <rule_id>] <diagnostic> — repair: <hint>"`), `context_digest`
  (sha256 over `term_to_binary(context_snapshot)` — same hash law as
  `Smalt.PPlan.ReceiptEngine` `delta_hash`), `ts` (ns, injectable), `session`
  (default node, injectable), `json_ld` (GL-3 refinement leg, from the
  concurrent GL-3 lane).
- `ntriples/1` — PROV-O serialization: receipt = `prov:Entity`
  `prov:wasInvalidatedBy` the refused activity (`urn:smalt:act:<session>:<rule_id>`,
  typed `prov:Activity`), digest as `xsd:hexBinary` `prov:value`, diagnostic +
  agent message as `xsd:string` `prov:value` literals, `prov:endedAtTime`.
  IRI conventions match `Smalt.PPlan.ReceiptEngine` (`urn:smalt:andon|act:...`).

## Courts

`test/internal/powl2_andon_court.exs` — **8 tests, 8 passed, 0 failures**
(`MIX_BUILD_ROOT=_build-gl3 mix test test/internal/powl2_andon_court.exs`, exit 0):

1. Format stability — same inputs + injected ts/session → identical receipt AND identical ntriples.
2. Digest binds context — digest == sha256(term_to_binary(snapshot)), 64 hex chars; perturbation flips it.
3. N-Triples well-formed — 7 lines, each ends `" ."`, balanced angle brackets, escaped quote literal.
4. Agent-consumable diagnostic — carries rule id, exact violation ("#8921"), repair hint; reachable from ntriples alone.
5. PROV vocabulary — receipt is `prov:Entity` invalidated by typed `prov:Activity`; `urn:smalt:` IRIs.
6–8. GL-3 JSON-LD leg (concurrent lane's tests): spec fields, byte-identical for identical injected inputs, repair-action override + shapeClass degradation.

Command output:

```
$ MIX_BUILD_ROOT=_build-gl3 mix test test/internal/powl2_andon_court.exs
........
Finished in 0.08 seconds (0.08s async, 0.00s sync)
Result: 8 passed
```

Toolchain: Elixir 1.20.4-otp-29 / Erlang OTP 29.1.2 (asdf, `.tool-versions` pin), `MIX_BUILD_ROOT=_build-gl3`.

## Compile-freeze disclosures (SLA minimal unblock fixes to other lanes' broken files)

Shared tree did not compile at `1deb200` HEAD + in-flight edits; `mix compile`
exited 1 for :smalt. I applied the minimal unblock fixes and disclose them per
the compile-freeze SLA:

1. `lib/smalt/pipeline/smalt_fond_powl_runner.erl:180` — guard
   `is_integer(R, 0, Max)` (no such Erlang guard) → `is_integer(R) andalso R >= 0 andalso R =< Max`
   (comment corrected; first attempt without `andalso` parens/semantics hit Erlang `and`-binds-tighter-than-comparison precedence — fixed in the same session, final form is the `andalso` chain).
2. `defguardp int_in(x, lo, hi) when :erlang.is_integer(x, lo, hi)` — nonexistent BIF — in
   `lib/smalt/data_plane/blob_storage.ex`, `cosmos.ex`, `cosmos_query_metrics.ex`,
   `file_share.ex`, `lib/smalt/egress_router.ex`, `lib/smalt/messaging/amqp10/frame_decoder.ex`
   → `when is_integer(x) and x >= lo and x <= hi` (6 files).
3. `lib/smalt/powl2/andon.ex` (concurrent GL-3 lane's in-flight addition to the
   file I own): removed redundant `json_ld/1` wrapper (conflicted with
   `json_ld/2` default arg) and duplicate `defp agent_message/3` shadowing the
   public `def agent_message/3`.
4. `lib/smalt/powl2/executor.ex` — broken mid-write edit by the concurrent
   executor lane; self-resolved by that lane within the SLA window (no fix
   applied by me). Shared compile reached exit 0 after waiting.

Post-fix: `mix compile` exit 0 (`/tmp/gl3_compile.log`), court exit 0.

## Falsifiers

- Court 1 fails on any receipt-field nondeterminism (ts/session leak in).
- Court 2 fails if the digest ever stops committing to the snapshot term.
- Court 3 fails on malformed triple syntax (caught the real rdf:type bracket bug pre-landing).
- Court 4 fails if the agent message drops rule id or repair hint.

## Boundaries

- `json_ld` requires the `jason` dep (present in mix.exs).
- `iso8601/1` truncates to seconds and falls back to the raw integer for
  out-of-range injectable ts (documented in-module).
- No bench result file was written (this is not a bench lane); no shared bench
  infra, REGISTRY.md, or justfile.d/15-bench.just touched.
