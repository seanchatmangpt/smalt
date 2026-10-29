# K8 lane receipt — tail-row dispositions (KD-114 / KD-115 / KD-116)

**Standing:** **PARTIAL_ALIVE** (KD-65 FIXED + falsifier green; 114/115/116 dispositioned, not fixed)

Lane K8, repo /Users/sac/smalt, v26.10.20 window, 2026-10-20.

## KD-114 — blob data-plane auth channel — HEAVY

- Row: canonical register v26.10.14:287 (OPEN). Close condition: "blob on the TLS twin
  or SharedKey admit; falsifier: SDK BlobClient upload → list → download byte-equal under enforce auth".
- Probe (code-level, live substrate 8443/9444 up, pid 57559): blob stays an http-8443-only
  splat. `lib/smalt/application.ex` `TlsTwinDispatch` (@egress_prefixes, ~line 127-145) routes
  the twin to EgressRouter only for fixed prefixes (/dbs/, /keys, /secrets, ...); blob's
  guarded catch-all `/{account}/{container}` has no fixed prefix, so putting blob on the
  twin requires dispatch redesign (x-ms-version / host-header sniffing at the twin seat) —
  not a surgical edit. The alternative close leg (SharedKey admit under enforce) requires
  a SharedKey verifier on the blob seat plus a real SDK leg to witness byte-equality.
- Disposition: **HEAVY** — dispatch redesign + real-SDK witness; out of 80/20 scope. Starting
  point: TlsTwinDispatch.call/2 prefix sniffing, egress_router blob catch-all guards.

## KD-115 — SB plain-queue receiver zero-delivery — HEAVY

- Row: canonical register v26.10.14:288 (OPEN). Falsifier: `sb-send20-receive-complete` over
  official @azure/service-bus.
- Probe (code-level): the credit dispatch IS present — `handle_amqp(:flow)` (connection.ex:406)
  grants absolute credit and calls `deliver_available(state)`; `deliver_to_link/2`
  (connection.ex:2286) dequeues via `QueueStore.dequeue_matching(link.address,
  session_id: link.session_id)`; `claim_candidates/3` (queue_store.ex:917) correctly passes
  nil-filter sessions through (reject only when filter != nil). So the break is upstream of
  the store: most likely the receiver link's address/session binding at attach, or
  `deliver_available/1` never reaching the plain-queue link. Diagnosing requires an
  iterative loop against a real @azure/service-bus client — exactly the heavy lane shape.
- Disposition: **HEAVY** — real-SDK diagnosis loop on the attach/credit seam
  (connection.ex:406 flow arm → deliver_available → deliver_to_link at 2286;
  queue_store.ex claim path verified sound). KD-116 (session settle shape) is downstream
  of the same receiver surface and rides the same heavy lane.

## KD-116 — SB session delivery settle methods — HEAVY (downstream of KD-115)

- Row: canonical register v26.10. deliveries arrive FIFO but carry no settle methods —
  the receiver-side delivery construction (delivery_sections, connection.ex:2344) must
  attach the settle surface the JS SDK binds (delivery.lockToken + settled=false + the
  disposition echo path already present). Same heavy lane as KD-115.

---

## SUPERSEDED-BY addendum (2026-10-22, lane BK-SUSP3)

All three HEAVY dispositions above are superseded by later register flips:
each KD row was subsequently closed in the canonical register with a witness
receipt, retiring the "HEAVY / out of scope" disposition.

- KD-114 → CLOSED-SIMULATED (shim + witness
  `docs/jira/v26.10.20/receipts/kd114-sharedkey-close-witness.md`; TLS-routing
  face `kd35-114-tls-plane-witness.md`, PARTIAL_ALIVE)
- KD-115 → CLOSED-SIMULATED (shim + witness
  `docs/jira/v26.10.20/receipts/kd115-post-shim-witness.md`)
- KD-116 → CLOSED-WITH-RECEIPT (premise-rot re-typing, witness
  `docs/jira/v26.10.20/receipts/kd115-116-diagnosis.md` §4)

SUPERSEDED-BY: canonical register rows
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:295-296` + `:33` of the
v26.10.19 pointer register; original disposition prose untouched.

On-disk successor verification (this addendum, real):

```
$ for f in kd114-sharedkey-close-witness.md kd115-post-shim-witness.md \
      kd115-116-diagnosis.md kd35-114-tls-plane-witness.md; do
    ls docs/jira/v26.10.20/receipts/$f; done                      -> all present, exit=0 ×4
$ grep -c "KD-114 .*CLOSED-SIMULATED\|KD-115 .*CLOSED-SIMULATED" \
    docs/jira/v26.10.14/KNOWN_DIVERGENCES.md                      -> 2, exit=0
```
