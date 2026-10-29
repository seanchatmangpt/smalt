# W3C-C - ACP (Solid ACP) ethics-wall matcher shapes + sieve court

**Standing**: PARTIAL_ALIVE (law files + court ALIVE on the exact subject below; both engines evaluate the ACP shapes natively over real op execution)
**Context: solo**
Date: 2026-10-21 | Base: main@806fc6f | Lane: W3C-C | Build root: `_build-w3cc`

## Subject

| File | Identity |
|---|---|
| `docs/jira/v26.10.22/law/shapes.ttl` | sha256 8deb156809cc (first 12 hex) |
| `docs/jira/v26.10.22/law/rules.n3` | sha256 5dd1e82b2ac1 (first 12 hex) |
| `lib/smalt/powl2/law_compiler.ex` | W3C-C extension: sh:not, sh:in, depth-aware blocks |
| `test/integration/w3cc_acp_court.exs` | new court |
| graphlaw.wasm | sha256 bf7d3dd3d8f2 (graphlaw@main wasm-abi build) |
| graphlaw-run | graphlaw@main release build 2026-10-21 17:29 |

## Deliverable (1) - ACP policy shapes (law/shapes.ttl)

Neutral prefix `acp:` = `http://www.w3.org/ns/solid/acp#`. Added `acp:PolicyShape`
(targetClass acp:Policy; acp:allow required) and `acp:AccessRequestShape`
(targetClass acp:AccessRequest). The ATH-3 evidentiary shapes are untouched; the
mapping is documented inline in shapes.ttl and in the table below.

## ACP-to-SHACL mapping (ACP construct -> SHACL construct)

| ACP construct | SHACL reduction | Engine support (probed) |
|---|---|---|
| acp:allow | `sh:in (acp:Read acp:Write)` on the request-mode path | purrdf::shapes 2.0.2: InConstraintComponent violation witnessed over the real packet-4 `shacl` op |
| acp:allOf | `sh:minCount 1` on acp:agent + acp:client (allOf holds iff every constraint holds, i.e. required presence under a presence-constraint sieve) | both engines (sh:minCount native) |
| acp:noneOf | `sh:not [ sh:property [ sh:path ev:conflictedMatter ; sh:minCount 1 ] ]` - the standard noneOf-to-sh:not reduction over the conflicted-class membership shape | purrdf::shapes 2.0.2: NotConstraintComponent violation witnessed over the real `shacl` op |
| deny leaf | rules.n3 C1/C2: `?req ev:conflictedMatter -> acp:ConflictedAgent -> acp:Deny` (derivation-only, no negation; quarantine stays "Admissible never derived") | eyeron N3 0.7.7 (n3 op fixed point) |

Probe receipt for the engine-support column: the court itself re-probes sh:not and
sh:in against the live wasm each run (leg A).

## Deliverable (2) - rules.n3 C1/C2 deny derivation

B1-B3 untouched; added C1 (conflicted-class derivation) and C2 (acp:Deny leaf).
Derivation-only, matching the file's fail-closed design. The ATH-3 court's
"derive:n3 added 3 facts" assertion still holds because no acp:AccessRequest nodes
exist in the ath3 corpus.

## Shared-lib enablement edit - disclosed

`lib/smalt/powl2/law_compiler.ex` raised CompileError on sh:not at parse time, so
adding sh:not to shapes.ttl would have broken the ath3 court's leg B
(LawCompiler.parse!/1 parses the whole shapes.ttl). Enablement, fail-closed grammar:

- `sh:not [ ... ]` -> constraint `{:not, inner}`: violates iff the node CONFORMS to the inner pattern; a vacuous inner block raises at compile time (no vacuous negation).
- `sh:in ( a b )` -> constraint `{:in, path, values, message}`: absent value conforms (SHACL semantics; required presence is the paired sh:minCount's job - same relation discipline as powl:notEquals).
- `read_block/1` is bracket-depth-aware (sh:not nests property blocks; the previous first-`]` split cannot parse nesting).
- `(` and `)` added to the tokenizer punct set (RDF-list members as punct-delimited words).
- Values compare through the module's canonical same_principal?/2 (GL-KILL F2 discipline).

Regression: `MIX_BUILD_ROOT=_build-w3cc mix test test/internal/powl2_law_compiler_court.exs` - **10 passed, 0 failures**.

Compile-freeze waits this session (other lanes' in-flight breakage; owners fixed in-window under the SLA; this lane applied no unblock fixes): partition.ex syntax error (~2 min), powl_bridge/journal_sink (~5 min).

## Court design (test/integration/w3cc_acp_court.exs)

- Leg A - graphlaw.wasm sieve (packet-4, real op execution): policy without acp:allow refuses (minCount, names pol-2); P-1 (conforming, allowed matter M-100) conforms and the law op (admit:shacl -> derive:n3) derives ev:Admissible (3 facts, blake3 parent==shacl child); P-2 (carries ev:conflictedMatter although its matter IS credential-allowed) witnesses NotConstraintComponent at the sieve and typed NotAdmitted at the law op's shacl step - 0 bytes; P-3 (wrong matter M-999) sieve-clean but Admissible never derived - fail-closed quarantine; standalone n3 op: C1/C2 derive acp:ConflictedAgent and acp:Deny for P-2 only.
- Leg B - smalt LawCompiler over the SAME shapes.ttl: P-1/P-3 pass; P-2 refuses rule `AccessRequestShape/not` naming the acp:noneOf breach; bad mode refuses `AccessRequestShape/in/mode`; allow-less policy refuses `PolicyShape/minCount/allow`.
- Leg C - GLD-7-class 0-byte gate (real ChangeFeed CAS + sealed ReceiptEngine run): P-1 commits (CAS etag); P-2 typed ANDON `AccessRequestShape/not`, 0 bytes (act `w3cc.refusal.ethics-wall`); P-3 fail-closed quarantine, 0 bytes (act `w3cc.refusal.quarantine`). Sealed 6 leaves, 32-byte HSM-signed Merkle root 101ce05103274be35cea7e3978ea4eb9f3471e17066f7a15f918ab4af5db7ba2; non-vacuity witnessed (dropping a leaf changes the root).

## Court transcript (real run, exit 0)

```
W3C-C ACP LAW COURT
  -- leg A: graphlaw.wasm sieve (packet-4)
  ok  graphlaw.wasm capabilities op ok
  ok  policy graph validates through the sieve
  ok  policy without acp:allow refuses (acp:PolicyShape minCount)
  ok  violation names the allow-less policy node (pol-2)
  ok  P-1 (conforming, allowed matter) conforms
  ok  P-2 (conflicted-class presenter) refuses with NotConstraintComponent (sh:not)
  ok  P-3 (wrong matter) conforms at the sieve — the wall is the n3 layer's job
  ok  law op: conforming P-1 admitted through admit:shacl -> derive:n3
  ok  P-1: ev:Admissible derived over the allowed-matter intersection
  ok  law receipt chain: 2 steps (admit:shacl, derive:n3)
  ok  derive:n3 added 3 facts; blake3 parent == shacl child
  ok  P-2 conflicted-class presenter: typed NotAdmitted at the shacl step (0 bytes past the sieve)
  ok  law op: P-3 shapes-admitted (structurally clean)
  ok  P-3: bates witnessed, Admissible NEVER derived (wrong matter) => fail-closed quarantine
  ok  n3 op fixed point reached over rules.n3 + presenter corpus
  ok  C1: P-2 derives acp:ConflictedAgent
  ok  C2: P-2 derives acp:Deny (typed deny leaf)
  ok  P-1 derives no deny
  ok  P-3 derives no deny
  -- leg B: smalt LawCompiler over the same shapes.ttl
  ok  LawCompiler compiled acp:AccessRequestShape from the law file
  ok  P-1 context passes the compiled ACP guard
  ok  P-3 context passes (the matter wall is the n3 layer's job)
  ok  P-2 refuses with rule AccessRequestShape/not
  ok  P-2 refusal names the acp:noneOf breach: sh:not: node matches the excluded (conflicted-class) pattern — acp:noneOf breach (ethical wall)
  ok  bad mode refuses with rule AccessRequestShape/in/mode
  ok  PolicyShape guard admits a policy context
  ok  allow-less policy refuses with rule PolicyShape/minCount/allow
  -- leg C: ChangeFeed + sealed 0-byte ethics-wall refusal
  ok  P-1 committed through real ChangeFeed CAS
  ok  P-2: typed ANDON names AccessRequestShape/not
  ok  P-3: fail-closed quarantine, 0 bytes
  ok  ChangeFeed holds exactly the 1 admitted presenter (0-byte refusals for wall + quarantine)
  ok  sealed receipt holds 6 leaves (3 ingest + 1 production + 2 refusal leaves), got 6
  ok  sealed receipt carries exactly 1 ethics-wall refusal leaf
  ok  sealed receipt carries exactly 1 quarantine refusal leaf
  ok  sealed Merkle root is 32 bytes and HSM-signed
  ok  non-vacuity: dropping a leaf changes the Merkle root
presenters: 3 | admitted: P-1 | wall-refused: P-2 (0-byte ANDON) | quarantined: P-3 (0-byte)
sealed leaves: 6  merkle_root: 101ce05103274be35cea7e3978ea4eb9f3471e17066f7a15f918ab4af5db7ba2
W3C-C COURT: PASS
```

## Exits

| Command | Exit |
|---|---|
| `MIX_BUILD_ROOT=_build-w3cc mix run --no-start test/integration/w3cc_acp_court.exs` | 0 |
| `MIX_BUILD_ROOT=_build-w3cc mix run --no-start test/integration/ath3_law_court.exs` (regression: shapes.ttl/rules.n3 changed) | 0 |
| `MIX_BUILD_ROOT=_build-w3cc mix test test/internal/powl2_law_compiler_court.exs` (regression: LawCompiler extended) | 0 (10 passed) |

Environmental note: one ath3 regression attempt failed before VM boot with a mix
user-lock-cache collision (`Mix.Sync.Lock` tmp file vanished under concurrent lanes);
identical command passed on retry — mix infra, not court logic.

Not committed, per assignment. /tmp/w3cc_court.out holds the full raw transcript.
