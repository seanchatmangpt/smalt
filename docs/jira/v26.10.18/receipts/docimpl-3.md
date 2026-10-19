# docimpl-3 — D4 explanation-page implementation (anchors, stale mechanisms, missing clusters)

Standing: PASS
Context: solo(docs-audit D4 anchor/cluster fixes verification greps; no mix test invocation)

## Scope (dispatch)

Implement `docs/jira/v26.10.18/docs-audit/d4-explanation.md`:

1. Fix the 9 wrong line anchors (architecture ×2, chatman-invariant ×2,
   affidavit-evidentiary ×5).
2. Fix 4 stale mechanisms (architecture containers table + plane
   supervisors; chatman bare-engine implication; affidavit Mechanism 5
   no-supervision gap; semantic-kernel-roadmap Canonical row UNLOCATED
   → LANDED).
3. NO_SLEEP_DOCTRINE cross-refs on 8 explanation pages.
4. Add the 6 missing topic clusters as concise sections (architecture:
   plane subtrees, LRO one-writer, Event Grid engine, burn
   architecture; affidavit pair: WasmEngine supervision).

No git actions taken by this lane (coordinator owns transitions).

## Note on anchor drift mid-session

Dispatch-time target lines (router.ex 539/:560/:2226/:2458-2477,
wasm_engine.ex :141/:219+) were correct at dispatch. Commit `b5e1136`
(gap-closure wave) landed mid-session and shifted router.ex +13 /
wasm_engine.ex +4. Anchors were re-pointed to the committed, resolving
lines (verified against HEAD `618d612`):

| doc | dispatch target | landed anchor |
|---|---|---|
| architecture.md | router.ex:539/:560 | `router.ex:552` and `:573` (`details == []` envelope, ARM face) |
| architecture.md | router.ex:2458-2477 | `router.ex:2475-2490` (metadata suffixes maps) |
| chatman-invariant.md | wasm_engine.ex:141/:219+ | `:145` (fail-closed `unavailable/1`), `:218-223` (typed contract), `:225+` (CTRT layout gate) |
| affidavit M1/M2/M3 | wasm_engine.ex:219+ | `:225+` (CTRT layout gate doc :225-232) |
| affidavit M3 (router leg) | router.ex:2226 | `:2239` (`defp affidavit_seal/2`) |
| affidavit M5 | wasm_engine.ex:127→141 | `:218-223` contract + `:145` fail-closed path |
| affidavit M6 | router.ex:2191-2195 | `:2198-2208` (wire-up law comment + witness table) |

## Changes

- `docs/explanation/architecture.md`: KD details-envelope anchor
  engine.ex:495 → router.ex:552/:573 (engine.ex:495 no longer carries
  the envelope — verified `arm_target` there); metadata anchor
  router.ex:1210 → :2475-2490; containers table gains the
  plane-supervisors row; four new sections (plane-scoped supervision
  subtrees AZB-09, LRO one-terminal-writer + Notifier, Event Grid
  at-least-once engine, burn architecture) with receipts azb-09,
  b4-lro-store, b-lro-notifier, azb-07, azb-22-burn-ring,
  burn-soak-live; See Also gains NO_SLEEP_DOCTRINE.
- `docs/explanation/chatman-invariant.md`: seal-path paragraph names
  the supervised engine (`WasmEngine.Supervisor`); anchors fixed; new
  "WasmEngine supervision" section (one_for_one 3/s, owner-GenServer
  monitor, own-mailbox retry classes, typed caller vocabulary, receipt
  b-wasm-supervisor.md); See Also gains NO_SLEEP_DOCTRINE.
- `docs/explanation/affidavit-evidentiary-design.md`: 5 anchor fixes
  (M1 :93→:225+, M2 :135-141→:225+, M3 :135-137→:225+ and router
  :2078-2135→:2239, M5 :127→:218-223/:145, M6 :2078-2090→:2198-2208);
  Mechanism 5 registers supervised-restart behavior (v26.10.18);
  new "Supervised engine lifecycle (context)" section; See Also gains
  chatman + NO_SLEEP_DOCTRINE.
- `docs/explanation/semantic-kernel-roadmap.md`: Canonical row flipped
  UNLOCATED → LANDED (`lib/smalt/projection/canonical.ex`,
  `docs/capabilities.json`, `docs/THIRD_PARTY.md`, drift fence
  `test/canonical_projection_test.exs`, receipt
  `i26-canonical-residual.md`); honest-status note updated (dated
  2026-10-18); See Also gains NO_SLEEP_DOCTRINE.
- Cross-refs only (See Also): zero-drift-model.md, cascade-teardown.md,
  two-green-court-law.md, emulation-stance.md.

NO_SLEEP_DOCTRINE cross-refs landed on 8 pages: architecture,
chatman-invariant, affidavit-evidentiary-design, semantic-kernel-roadmap,
zero-drift-model, cascade-teardown, two-green-court-law, emulation-stance
(ggen-projection-law, two-tier-enclave, docs-from-first-principles
intentionally untouched — no process-law surface).

## Verification (real gate)

Anchor sweep — every `file:line` anchor in the four content-edited docs
checked in-range against the tree (lib/ anchors all resolve; the 4
`affidavit-wasm/src/*.rs` anchors are pre-existing upstream-crate
references, untouched by this WO):

```
$ grep -n "defp unavailable\|CTRT layout gate\|engine down" lib/smalt/affidavit/wasm_engine.ex
145:  defp unavailable(reason) do
223:    * `{:error, :engine_unavailable}` — engine down.
225:  CTRT layout gate (per ffi.rs, proven by W16's Rust court): magic
$ grep -n "defp affidavit_seal(record\|Wire-up law\|\"suffixes\" =>\|details == \[\], do: error" lib/smalt/arm_gateway/router.ex
552:    error = if details == [], do: error, else: Map.put(error, "details", details)
573:    error = if details == [], do: error, else: Map.put(error, "details", details)
2198:  # Wire-up law: on a successful resource PUT and on the RG-delete cascade the
2239:  defp affidavit_seal(record, %{subject: subject, lease_context: lease_context})
2475:        "suffixes" => %{
$ python3 anchor sweep (range check of every ex/exs/rs anchor in the 4 docs)
lib anchors: all in-range; 0 out-of-range failures
(pre-existing affidavit-wasm/src/*.rs upstream refs reported NOFILE — not this WO's scope)
$ grep -c 'NO_SLEEP_DOCTRINE' docs/explanation/*.md
docs/explanation/affidavit-evidentiary-design.md:1
docs/explanation/chatman-invariant.md:1
docs/explanation/cascade-teardown.md:1
docs/explanation/architecture.md:1
docs/explanation/no-sleep.md:3
docs/explanation/zero-drift-model.md:1
docs/explanation/emulation-stance.md:1
docs/explanation/two-green-court-law.md:1
docs/explanation/ggen-projection-law.md:0
docs/explanation/docs-from-first-principles.md:0
docs/explanation/semantic-kernel-roadmap.md:1
docs/explanation/two-tier-enclave.md:0
```

Docs DoD gate:

```
$ just docs-dod-check
...
OK    docs/explanation/architecture.md
OK    docs/explanation/cascade-teardown.md
OK    docs/explanation/semantic-kernel-roadmap.md
OK    docs/explanation/affidavit-evidentiary-design.md
...
OK    README.md
(exit 0 — full 63-check listing in session transcript; no MISS lines)
```

`just docs-dod-check` → exit 0.

## Standing

PASS. All 9 anchors corrected (to resolving committed lines), 4 stale
mechanisms fixed, 6 missing sections added, 8 NO_SLEEP cross-refs
landed, DoD gate green at HEAD `618d612`.
