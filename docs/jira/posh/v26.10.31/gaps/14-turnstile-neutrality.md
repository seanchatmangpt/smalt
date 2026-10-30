# 14 Turnstile Receipt Law — Neutrality Boundary Statement

Status: **PARTIAL** — the law is verified neutral (real reads this session of
every cited file); dialect participation is specified but not executed against
any dialect. Fence on the arm.request gateway face: ALIVE (gaps/39, in-process
court + flip witnessed). Live kind/TF apply path: UNVERIFIED (gaps/26 residue,
unresolved — the provider still does not read or enforce the header on the TF
apply path).

Subject: turnstile receipt law as implemented in
`/Users/sac/smalt/lib/smalt/arm_gateway/plug/receipt_turnstile.ex`,
`/Users/sac/smalt/lib/smalt/posh/turnstile.ex`,
`/Users/sac/smalt/lib/smalt/posh/egress/settlement.ex`,
`/Users/sac/smalt/lib/smalt/posh/egress/event_log.ex`, and the Go verifier
`/Users/sac/smalt/posh/internal/receipt/verify.go` (`VerifyTurnstile`).

## Boundary statement (normative, citable by the charter)

**The turnstile receipt law is provider-neutral.** A delta is receipted iff a
32-byte BLAKE3 digest exists for it, computed over the exact byte string

    BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)

— no length prefixes, no separators (cross-language contract, pinned vector
`0c39d201…db834`; `settlement.ex:58-68`, `receipt_turnstile.ex:22-23`). A
delta passes the turnstile iff (a) its receipt header carries that digest on
the wire, and (b) the mutation is admitted through the turnstile fence
(`admit()` → typed `{:refused, reason}` halts with a 400 `AdmissionRefused`
envelope, refusal itself settled into the prev-hash-chained event log). No
clause of the law names a cloud provider, an Azure resource type, an ARM-only
shape requirement (the default fence policy `arm.request` has `required: []`,
`types: {}` — shape refusals come only from genuinely non-object payloads),
or a credential system. The law's vocabulary is: op, timestamp_ns,
payload_body, node_id, state_root, route, prev_hash. Provider identity lives
outside the law — it is lane 1's STS bearer boundary, referenced, not
duplicated here.

## Neutrality audit (per-element)

| Element | Where verified | Neutral? | Note |
|---|---|---|---|
| BLAKE3 digest, 32 bytes / 64 hex | `settlement.ex:63-68`, `verify.go` (constant-time compare, 64-hex gate) | Yes | Pure-Elixir, no NIF; Go treats as SHA-256-sized token — size contract, not name dependence |
| Digest input `(op \|\| ts_ns \|\| body)` | `settlement.ex:58-68` | Yes | **Correction to the task premise** (see Violations) |
| Header `X-Smalt-Receipt-Turnstile` (+ `X-Smalt-Receipt-Timestamp`) | `receipt_turnstile.ex:112-113` | Yes | smalt-namespaced, not provider-namespaced |
| Event-log prev-hash chaining (genesis = 64 zeros; entry hash = SHA-256 of serialization ∥ prev) | `event_log.ex:6-7,39-49,61-80` | Yes | Chain hash is SHA-256; receipt digest is BLAKE3 — two distinct, both neutral |
| Fence gating by verb+route | `receipt_turnstile.ex:50-61,166-171` | Yes | Gates on `method ∈ {POST,PUT,PATCH,DELETE}` and `path_info == ["subscriptions" \| _]` — HTTP vocabulary only |
| Refusal: typed 400 `AdmissionRefused` + halt + refusal settlement | `receipt_turnstile.ex:144-163,92-108` | Yes | Refusal carries a receipt too; no-log case is a loud warn, not a fake pass |

## Violations / corrections found

1. **Digest-input premise correction (against the dispatching task, not the
   law).** The task specified the digest as over `(delta ∥ node_id ∥
   timestamp_ns ∥ state_root)`. The actual cross-language contract is
   `BLAKE3(op_utf8 || u64BE(ts_ns) || payload_body)`
   (`settlement.ex:58-68`, `receipt_turnstile.ex:22-23`, `verify.go`). The
   delta is the *body*; `node_id` and `state_root` are event-log *entry
   fields*, not digest inputs. Any charter text carrying the four-input
   formula would be a false citation — use the three-input formula.
2. **Residual Azure coupling in the fence's path predicate** (registered, not
   a violation of the digest/header/chaining elements): the fence's route
   gate is `/subscriptions/*` (`receipt_turnstile.ex:170-171`), which is the
   ARM URL-space convention. The gate itself keys on a literal path prefix —
   a dialect must either serve under a `/subscriptions`-shaped space or
   extend the predicate (config, one clause). Logged as the one provider-adjacent
   residue; boundary statement above already scopes it as fence-placement,
   not law.
3. **Unresolved gaps/26 residue**: on the live TF apply path the provider
   discards the header; nobody verifies. The law is neutral, but its
   enforcement is currently one-sided on that path (emit-only). Participation
   contract below is the close condition.

## Dialect-participation contract

A dialect participates in the turnstile receipt law iff it satisfies all
four; partial participation is registered, never rounded to PASS.

1. **Emit**: every response to a mutating request (POST/PUT/PATCH/DELETE)
   carries `X-Smalt-Receipt-Turnstile: <64-hex>` computed as
   `BLAKE3(op_utf8 || u64BE(ts_ns) || raw_request_body)`, plus
   `X-Smalt-Receipt-Timestamp` carrying the same `ts_ns`. The receipt must be
   computed at send time over the raw body (not the parsed/normalized body).
   Rejections emitted by upstream middleware (401s, pre-parse 400s) carry
   receipts too (mounted above Bearer, per `receipt_turnstile.ex:2-12`).
2. **Verify (membrane side)**: any membrane relaying dialect traffic
   recomputes the digest via `receipt.VerifyTurnstile` and fails closed —
   absent headers on a mutating response are a verification failure, not a
   bypass (this closes the `client.go:200-204` silent bypass noted in
   gaps/26).
3. **Respect refusal halts**: a `{:refused, reason}` from `admit()` halts the
   request with a typed refusal envelope (400 `AdmissionRefused` or the
   dialect's equivalent typed error), never a silent pass-through; the
   refusal is itself receipted and settled into the event log.
4. **Feed mutations through admit()**: every state-modifying delta goes
   through the fence's `admit()` against the compiled policy for its route.
   GET/read paths are stamp-only.

Witness in this repo: `apps/web/test/harness/vault/tc-vault-003-receipt-header.test.ts`
(secret PUT carries a 64-hex turnstile header — emit duty exercised on the
vault face of this consumer repo).

## Adjacent Azure-shaped element: STS bearer boundary

The STS bearer boundary (HRN-014, PLANNED per `gaps/69-dod-execution.md:71`)
is lane 1's territory and is Azure-shaped. It is **outside** the turnstile
law's boundary: the turnstile mounts *above* Bearer so pre-membrane 401s are
stamped, but the law neither defines nor depends on the credential system.
Referenced, not duplicated.

## Receipt

- Commands: reads + greps over `/Users/sac/smalt/lib/smalt/arm_gateway/plug/
  receipt_turnstile.ex`, `lib/smalt/posh/{turnstile,egress/settlement,egress/event_log}.ex`,
  `posh/internal/receipt/verify.go`, gaps/39 + gaps/26, and this repo's
  `gaps/69-dod-execution.md`, `apps/web/test/harness/vault/
  tc-vault-003-receipt-header.test.ts`. No tests executed this session
  (read-mostly lane); all ALIVE claims are cited to the receipts named above,
  not re-run.
- File written: `v26.10.31/gaps/14-turnstile-neutrality.md` (this file; the
  wave's other gap reports live at repo-root `gaps/` — coordinator may want
  to consolidate).
- Standing: PARTIAL — law verified neutral on-disk; dialect contract is
  specified, not yet executed; TF-apply-path enforcement gap (gaps/26) open.
