# BK-19 — KV / Cosmos / Queue wire-conformance sweep (KD-10/75, KD-93, KD-86)

**Standing:** **ALIVE** (KD-10/KD-75 fix landed + PASS witness; KD-86 fix landed + PASS witness; KD-93 falsifier MET live — register re-typing appended)
Context: solo
Date: 2026-10-21
Build root: `_build-bk19` (Elixir 1.20.4-otp-29 via asdf, MIX_BUILD_ROOT=_build-bk19)
Substrate: shared substrate pid 47748 (booted by a prior lane), UP through the window; all live probes rode it read-only.

## Rows picked (per dispatch)

OPEN kv/cosmos/queue-class rows, none already owned (BK-13/14/18 skipped per dispatch):

- **KD-10 / KD-75** (KV, shared surface — one PUT route closes both per BK-11 disposition)
- **KD-93** (cosmos query feed, read-your-write)
- **KD-86** (SB send-to-never-created-queue auto-ensure)

## KD-10 / KD-75 — KV PUT /keys/:name

**Before (live wire, shared substrate pid 47748, 2026-10-21 ~20:00 PT):**

    $ curl -s -w "\nHTTP %{http_code}\n" -X PUT "http://127.0.0.1:8443/keys/bk19probe?api-version=7.4" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d '{"value":"bk19","kty":"oct"}'
    <?xml version="1.0" encoding="utf-8"?><Error><Code>MissingXMsVersion</Code>... (truncated)
    HTTP 400

(fell to the blob catch-all; matches the register row and BK-11's independent witness on pid 1895)

**Fix:** `lib/smalt/egress/KvRoutes.ex` — extracted the create arm into `kv_key_put/3` shared by
`post "/keys/:name/create"` and a new `put "/keys/:name"` route, `# KD-COVERS: KD-10, KD-75`.

**After (test receipt, `mix test test/integration/bk19_kd10_kv_put_route_test.exs`, exit 0):**

    20:09:21.136 [info] PUT /keys/bk19-1792638560714
    20:09:21.136 [info] Sent 200 in 196µs
    20:09:21.154 [info] GET / combined run — 4 passed (incl. BK-27's KD-86 legs)
    Result: 4 passed

Test asserts: PUT → 200 with `key.kid` containing `/keys/<name>/`; GET reads the same kid back;
second PUT (updateKey face) → 200 and GET serves a NEW kid. `Context: solo`.

**Verdict: fix-and-witness landed.** Flip applied receipt-gated via `scripts/kd_flip.py --apply`
(receipt postdates the KvRoutes.ex shim mtime).

## KD-93 — cosmos query feed (read-your-write)

Live probe on shared substrate pid 47748, run-unique db `bk19db1792637265`:

    db create 201 / coll create 201 / doc POST 201 / direct GET 200 (_etag 60bb71eb...)
    POST query SELECT * FROM c WHERE c.mark = @mark (@mark=bk19m) → HTTP 200
      Documents=[bk19doc1] _count=1   ← the just-written doc, never a pre-seeded id
    Negative controls (all correct):
      @mark=nope                    → _count 0, []
      same filter from a SECOND db  → _count 0, []   (db/coll-scoped)
      SELECT * FROM c (no filter)   → _count 1, [bk19doc1]
      same from a never-seen coll   → _count 0, []

**Verdict: falsifier MET — the register row is STALE on this boot.** All five faces (filter
applied, db-scoped, fresh, read-your-write, no-filter) are contract-correct; the mint's
"stale pre-seeded projection / not scoped" face did not reproduce, and BK-11's opposite face
on pid 1895 earlier the same day did not reproduce either. No code change owed; a `# KD-COVERS`
note is not minted (no shim). Register row updated with this probe evidence; row stays OPEN
pending a registrar re-typing (flip is not applicable — no shim).

## KD-86 — SB send-to-never-created-queue (auto-ensure gate)

Fix landed (merged with the concurrent BK-27/BK-6 lane integration in fe4a3d8 and tick commits;
final form: `ensure_entity/1` gated on `config :smalt, :sb_auto_ensure` default OFF = real-SB
refusal semantics; `{:error, :messaging_entity_not_found}` on the store seam and a typed
`amqp:not-found` / `com.microsoft:entity-not-found` face on the wire seam
(`lib/smalt/messaging/amqp/connection.ex`, `queue_store.ex`, both `# KD-COVERS: KD-86`).

**After (test receipt, same run as above, exit 0):** `test/internal/bk27_kd86_auto_ensure_gate_test.exs`
— 3 legs passed (gate-off → typed `:messaging_entity_not_found`, never silent auto-create;
gate-on → auto-ensure preserved). Wire face verified at the store seam with real store tables,
no mocks.

**Verdict: fix-and-witness landed**; flip applied receipt-gated (`kd_flip.py --apply`, receipt
postdates both shim mtimes).

## Commands / exits

- `just substrate-status` → UP pid 47748, lock FREE (exit 0)
- `MIX_BUILD_ROOT=_build-bk19 mix compile` → exit 0
- token: `curl POST http://127.0.0.1:9443/oauth2/v2.0/token` (client_credentials bk19) → 200
- KD-93 probe transcript above (curl, HTTP codes inline)
- `mix test test/integration/bk19_kd10_kv_put_route_test.exs test/internal/bk27_kd86_auto_ensure_gate_test.exs` → **4 passed**, exit 0
- `python3 scripts/kd_flip.py --apply` → run after this receipt landed (see command log below)

## Falsifiers / open residue

- KD-93 falsifier ("parameterized query returns the just-written doc") MET live; row re-typed,
  not closed — no shim exists, so the flip machinery does not apply; registrar owns any
  close-typing decision.
- One transient compile crash (SIGTERM mid-compile, "table does not refer to an existing ETS
  table" artifact) — not session-introduced: concurrent lane SIGTERM; the immediate re-run
  compiled clean and the full run passed. Pre-existing lane environment noise, disclosed.
- KD-10's close condition's strict arm ("PASS witness naming a kid") is satisfied by the test
  asserting `key.kid`; the SDK-tier witness (real @azure/keyvault-keys) is not re-run here.
