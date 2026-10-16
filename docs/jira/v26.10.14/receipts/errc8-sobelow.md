# ERRC Lane 8 (Raise) — sobelow static security analysis

Date: 2026-10-15 · Repo: /Users/sac/smalt · Tool: sobelow (Hex, added `{:sobelow, "~> 0.13", only: :dev, runtime: false}` to mix.exs)
Run: `MIX_ENV=dev mix deps.get && mix sobelow --config` (non-blocking first pass, `just sobelow` records, does not gate)

## Summary

- **27 findings, 0 high-confidence, 0 medium-confidence, 27 low-confidence.**
- Zero Phoenix.Router surface (emulator is a raw Plug router on bandit), so no
  MissingCSRF / CSRF class findings at all. No templates (.eex), no Ecto query
  building in lib/ (ecto present only as an Ash transitive dep, never used for
  SQL construction) — SQL and XSS-template classes are structurally absent.
- Only wire-surface finding: **XSS.SendResp at lib/smalt/egress_router.ex:1980
  (blob_error_xml/4)** — see triage below.

## Triage table

| # | Finding (class, confidence) | Location | Verdict | Reason |
|---|---|---|---|---|
| 1 | XSS.SendResp, low | egress_router.ex:1980 `blob_error_xml/4` | **FALSE-POSITIVE** | Both interpolations (`code`, `message`) pass through `BlobService.xml_escape/1` (blob_service.ex) before interpolation; XML error envelope is escaped, not raw interpolation. No test covers a hostile `message` — kept as a KD-register candidate to add an escaping court, not a code fix. |
| 1b | — | blob_error_xml escaping court | KD CANDIDATE | Wire-visible surface; recommend an adversarial test asserting a payload like `<script>` in a blob error message renders escaped. Not remediated in this lane. |
| 2 | DOS.StringToAtom, low (x2) | runtime_contracts.ex:261,264 `contract_name_guess/2` | **FALSE-POSITIVE** | Input is a module atom from the contract list (not request-controlled); `String.to_atom(inspect(entry))` of an atom's inspect is bounded. Not reachable from the wire. |
| 3-5 | Traversal.FileModule, low (x3) | dspy/remediation.ex:207-212 | FALSE-POSITIVE | Paths from local dspy remediation state, not request-derived; local substrate, loopback-only. |
| 6-8 | Traversal.FileModule, low (x3) | ocel/deviation_admission.ex:72,73,83 | FALSE-POSITIVE | OCEL log paths from Application env, operator-configured, not wire input. |
| 9-10 | Traversal.FileModule, low (x2) | modules: projection/canonical.ex:63-64, projection/semantic_epoch.ex:161,307 | FALSE-POSITIVE | Projection/lock paths from config, not request-derived. |
| 11-12 | DOS.StringToAtom, low (x2) | runtime_contracts.ex:261,264 | FALSE- NOT WIRE-REACHABLE | duplicate listing of #2 (sobelow reports per-call-site) |
| 13 | Traversal.FileModule, low | store/dets_mirror.ex:98 | FALSE-POSITIVE | DETS dir from Application env, not wire input. |
| 14-16 | Traversal.FileModule, low (x3) | telemetry/ocel_ndjson.ex:61,62,118 | FALSE-POSITIVE | Telemetry log path operator-configured. |
| 17-27 | Traversal.FileModule, low (x11) | tls.ex:189,191,257,263,291-311 | FALSE-POSITIVE | Cert/key paths from config/fixtures; emulator is loopback TLS dev-cert writer, paths not request-controlled. |

## Severity honesty note

The emulator is stateless and loopback by design; "internet-facing" applies to the
wire-protocol surface only (a client that speaks Blob/Queue/ARM protocol). Under that
threat model: no TRUE-POSITIVE wire-relevant findings. The one wire-surface hit
(blob_error_xml) is already escaped. Severity of all 27 findings under an internet-facing
threat model: **none above Informational**; under a local-attacker model, still none rise
above Informational (no request-derived file paths or atoms).

## Wire-visible KD register candidates

1. blob_error_xml escaping court (adversarial `<script>` / CDATA payload in error message)
2. (none other — all other findings are non-wire config/fixture paths)

## Changes

- mix.exs: sobelow dep added (:dev, runtime: false)
- justfile.d/20-sobelow.just: new `just sobelow` recipe (records, does not gate)
- Justfile: import appended
- No lib/ changes in this lane.

## Verification

- `mix deps.get` exit 0; `mix sobelow --config` exit 0, 27 findings printed.
- `just sobelow` exit 0, scan completes, triage pointer printed.
