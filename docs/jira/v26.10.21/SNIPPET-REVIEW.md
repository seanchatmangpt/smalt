# Snippet Review: ERRC Drop-In Patterns (operator submission, 2026-10-21)

Standing: REVIEWED — 2 of 4 snippets partially adopted (patterns already landed by IMPL lanes); 1 landed-with-correction (wrong `:json` API shape); 1 BLOCKED on a REFUTED premise pending IMPL-12's re-probe on the pinned release
Context: solo

## 1. CasEngine (`Registry.lock/3` + `update_element/4` + `next_lookup/2`) — pattern ADOPTED in principle, module BLOCKED for the Store plane

The primitives are exactly the VAL-DATA-verified set (ordered_set-only cursor, ElementSpec/DefaultTuple upsert, composite-key locks — all confirmed on both toolchains). **Adoption boundary**: the audit's HIGH finding stands — `Smalt.Store`'s CAS funnel is deliberately singleton (`next_seq` has a documented caller-side-CAS race history), so `Smalt.Storage.CasEngine` is admitted as the pattern for **future/new surfaces** (new tables, new planes), NOT as a Store replacement. A migration work-order would need to falsify the audit's race history first.

## 2. ProcessSweeper — REDUNDANT, already landed

`Smalt.ProcessIter` (IMPL-1, receipt `impl1-process-iterator.md`) is this exact seam — iterator/next/reduce/count + the 0-vs-514,605-word court on 201k processes. The snippet adds nothing not already in HEAD. No action.

## 3. HttpParser — guards ADOPTED (IMPL-2/11); the SAX shape is WRONG

- `defguard is_integer(size, 0, @max)` — correct on OTP 29, matches IMPL-2/IMPL-11's landed sweep.
- **The `:json.decode(raw, 0, %{array: handler})` call does not exist.** T42's executed probe established the real API: `json:decode_start/3` → `json:decode_continue/2` with **arity-specific hook funs** (value hooks arity-1, container-push arity-2, finish arity-2) — not a map-of-handlers `decode/3`. T42's first attempt with folklore shapes FunctionClauseErrored exactly as this snippet would. The landed evidence (T42 + `scripts/bench/t42_json.exs`) is the authoritative shape; the snippet's intent (discard-style streaming) is what T42 measured at ~23 KB peak heap.

## 4. MerkleReceipt (deterministic map fold) — **BLOCKED on a REFUTED premise**

The snippet's entire correctness claim ("OTP 29 traverses keys deterministically") is **refuted by execution**: 0/100 stable on 28.3.1, 29.0.6, and 29.1.1 (`receipts/val-ar-powl.md`, probe `p4_maporder.escript`). IMPL-12 is re-probing on the pinned 29.1.2 right now — the only release never tested. If IMPL-12 confirms stability on 29.1.2, this snippet becomes adoptable (and the landed `ReceiptEngine`'s explicit `{epoch, seq}` ordering can be simplified); if it refutes, the snippet as written produces **run-order-dependent digests** — a silent audit-integrity bug. The landed `Smalt.PPlan.ReceiptEngine` (ordered-tuple hashing, byte-identical seals incl. cold DETS re-open) remains correct regardless of the outcome.

## Summary

| Snippet | Status | Action |
|---|---|---|
| CasEngine | Pattern verified; module blocked for Store plane | Admit for new surfaces; falsify the audit race history before any Store migration |
| ProcessSweeper | Redundant | None — `Smalt.ProcessIter` in HEAD |
| HttpParser | Half right | Guards already landed; SAX shape corrected per T42's executed API |
| MerkleReceipt | **BLOCKED → GATED-ADMISSIBLE** | IMPL-12 (`receipts/impl12-maporder-2912.md`): CONFIRMED on pinned 29.1.2 (100/100, fingerprint `yjnri` across 28.3–29.1.2, differs on 26.2.1 — deterministic per release, not portable across major OTPs; prior 0/100 was a harness artifact). The `maps:fold` simplification is admitted ONLY behind IMPL-12's WO gate: otp_release ≥ 28 + order-fingerprint sentinel check (`{:order_fingerprint_mismatch, got, want}` refusal) + byte-identity re-seal court + 26.x negative fixture. Until that gate lands, the ReceiptEngine's `{epoch, seq}` tuple sorting stays — mathematical stability across reboots outranks single-release iteration behavior (operator directive #4 stands). |

## Standing Policy (operator directives, 2026-10-21)

```
1. CasEngine       -> QUARANTINED for Smalt.Store (preserves single-seq monotonic log)
                      ADMITTED for un-sequenced high-concurrency surfaces.
2. ProcessSweeper  -> NO-OP. Smalt.ProcessIter (IMPL-1) is authoritative in HEAD.
3. HttpParser      -> SEPARATE: keep is_integer/3 guards.
                      BIND streaming decode strictly to T42's hook architecture.
4. MerkleReceipt   -> HARD BLOCK. Enforce explicit key/epoch sorting in ReceiptEngine.
```

Immediate next steps:
1. **Gate the Store plane**: no `Smalt.Store` → CasEngine refactor without explicit proof that concurrent `next_seq` generation cannot produce duplicate sequence receipts.
2. **Standardize the JSON seam**: `Smalt.JsonCompat` exclusively wraps `json:decode_start/3` + `json:decode_continue/2`, providing an internal discard-style SAX helper so downstream modules never re-implement the callback hooks.
3. **Receipt sealing**: `Smalt.PPlan.ReceiptEngine` stays locked to deterministic tuple-sorting until IMPL-12 releases receipted findings for 29.1.2 — and even then, mathematical stability across reboots outranks any single-release iteration behavior.
