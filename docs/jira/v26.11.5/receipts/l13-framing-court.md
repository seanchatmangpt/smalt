# L13 — AoQ Framing Law Court

Standing: ALIVE

Lane: L13. Program: AoQ-on-BEAM. Spec:
`docs/jira/v26.11.5/aq-architecture-spec.md` §2/§3 (commit 25dd40df).

## Delivered

| path | role |
|---|---|
| `lib/smalt/aoq/frame.ex` | `Smalt.Aoq.Frame` codec — 64B header + ≥1B body; `split/1` refuses sub-65B frames as `{:error, :short_frame}`; `encode/2` returns iolist `[header, payload]`, refuses empty payload (`{:error, :empty_payload}`) and short/ill-typed headers (`{:error, :short_header}`) |
| `test/courts/aoq_framing_court.exs` | byte-fidelity court: header==64, body≥1, total ≥65B (RefcBinary territory, never HeapBin), zero-payload refused, short-header refused, split round-trip + sub-65B refusals, iolist-vs-`<>` reference byte fidelity, payload sizes 1..4096 spanning the 64B boundary |
| `scripts/aoq_egress_fence.sh` | rg-backed fail-closed fence over `lib/smalt/aoq/**`; fail-loud on missing rg (exit 2, no fake-pass); comment-line + error-string-concat file exemptions documented in-script; per-site `# AOQ-FENCE-OK:` marker supported |

## Verdicts (final, this session)

- `bash scripts/aoq_egress_fence.sh` → `0 violation(s), 15 allowlisted exemption(s)`, rc=0 (rerun immediately before commit). Non-vacuity: a shim `header <> payload` egress line in a /tmp copy of the tree flips the fence to 1 VIOLATION / rc=1 while `<<>>` empty-binary literals do NOT match (PCRE adjacency pattern `(?<![<])<>(?![>])`) — the flip IS the proof, the near-miss class does not false-positive.
- `MIX_BUILD_ROOT=_build-lane13 mix test test/courts/aoq_framing_court.exs` → **24 tests, 24 passed, 0 failures** (Elixir 1.20.4-otp-29 per .tool-versions pin; Homebrew 1.19.5 refused by the pin).

## Compile-freeze disclosures (SLA minimal-unblock / cross-lane)

- `lib/smalt/aoq/frame.ex` is lane-owned by L13; lane C6 extended it mid-flight (Frame struct, `encode_frame/2`, `decode/1` 3-stage). Two defects in C6's in-flight additions were repaired by L13 and disclosed here: (1) `stage3_fields/2` matched a fixed 32-byte pattern against the full wire binary — a pattern with no rest segment must consume the whole binary, so every decode returned `:bad_header`; fix adds `_rest::binary`. (2) `lawful_wire/1` in the court matched `<<_::binary-size(4)>> =` against a 40-byte prefix (MatchError); fix drops the bogus match annotation.
- Court test bodies at lines 151/162/174/253 piped `payload |> frame(opts)` (frame/2, undefined); fixed to direct `frame(opts)` calls; two missing `|> ok_iolist()` / `payload_len:` mismatches repaired. DBG prints left by C6 were observed mid-session and were removed by C6 before landing (verified by grep).
- Fence file exemptions `tables.ex`, `frame.ex`, `transport.ex` were extended as those lanes landed files; every exemption is loud (ALLOWED line) and documented in-script.

## Exemptions (known-by-design, loud)

- `lib/smalt/aoq/flags.ex:36,41,46` — `<>` inside raise/log prose strings only; the frame path never flows through them.
- `lib/smalt/aoq/tables.ex:126` — same class: error-message string concat, not wire egress.
- `lib/smalt/aoq/nif_holder.ex:37` — a comment restating the ban itself.

## Laws honored

- No sleep as coordination — bounded-poll on file content with Instant-class deadline for the concurrent-lane compile-freeze, per no-sleep doctrine.
- MIX_BUILD_ROOT=_build-lane13.
- Owned exactly: `lib/smalt/aoq/frame.ex`, `test/courts/aoq_framing_court.exs`, `scripts/aoq_egress_fence.sh`, this receipt.
