# L13 — AoQ Framing Law Court

Standing: PARTIAL_ALIVE

Lane: L13. Program: AoQ-on-BEAM. Spec:
`docs/jira/v26.11.5/aq-architecture-spec.md` §2/§3 (commit 25dd40df).

## Delivered

| path | role |
|---|---|
| `lib/smalt/aoq/frame.ex` | `Smalt.Aoq.Frame` codec — 64B header + ≥1B body; `split/1` refuses sub-65B frames as `{:error, :short_frame}`; `encode/2` returns iolist `[header, payload]`, refuses empty payload (`{:error, :empty_payload}`) and short/ill-typed headers (`{:error, :short_header}`) |
| `test/courts/aoq_framing_court.exs` | byte-fidelity court: header==64, body≥1, total ≥65B (RefcBinary territory, never HeapBin), zero-payload refused, short-header refused, split round-trip + sub-65B refusals, iolist-vs-`<>` reference byte fidelity, payload sizes 1..4096 spanning the 64B boundary |
| `scripts/aoq_egress_fence.sh` | rg-backed fail-closed fence over `lib/smalt/aoq/**`; fail-loud on missing rg (exit 2, no fake-pass); comment-line + error-string-concat file exemptions documented in-script; per-site `# AOQ-FENCE-OK:` marker supported |

## Verdicts (as of landing)

- `bash scripts/aoq_egress_fence.sh` → `0 violation(s), 5 allowlisted exemption(s)`, rc=0. Non-vacuity: a shim `header <> payload` egress line in a /tmp copy of the tree flips the fence to rc=1 (VACUOUS-GATE counter-evidence recorded).
- `mix test test/courts/aoq_framing_court.exs` — PENDING at receipt time (shared-compile freeze from concurrent lanes' in-flight `lib/smalt/aoq/` edits: worker_pool.ex syntax, then listener.ex:92 `:socket.sockaddr_in` — both other lanes' files, SLA window); will be updated to the real count in this receipt before commit.

## Exemptions (known-by-design, loud)

- `lib/smalt/aoq/flags.ex:36,41,46` — `<>` inside raise/log prose strings only; the frame path never flows through them.
- `lib/smalt/aoq/tables.ex:126` — same class: error-message string concat, not wire egress.
- `lib/smalt/aoq/nif_holder.ex:37` — a comment restating the ban itself.

## Laws honored

- No sleep as coordination — bounded-poll on file content with Instant-class deadline for the concurrent-lane compile-freeze, per no-sleep doctrine.
- MIX_BUILD_ROOT=_build-lane13.
- Owned exactly: `lib/smalt/aoq/frame.ex`, `test/courts/aoq_framing_court.exs`, `scripts/aoq_egress_fence.sh`, this receipt.
