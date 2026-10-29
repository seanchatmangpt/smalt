# BK-11 — pre-window KD legacy triage (anti-escape-hatch #3)

**Standing:** PASS (11/11 rows triaged; 2 CLOSED verified, 9 DISPOSITIONED with falsifier + next action; live-probe evidence on substrate pid 1895)
Context: solo
Date: 2026-10-21
Lane build root: MIX_BUILD_ROOT=_build-bk11

## Premise check

The 11 pre-window rows (KD-04/10/13/14/23/75/79/86/90/92/93) were reported typed
"legacy, out of scope" — that category does not exist in the register and the
string now appears **0 times** in both `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`
(canonical) and the v26.10.21 pointer doc (grep receipt in this session). A prior
kd-registrar sweep earlier this window
(receipt `docs/jira/v26.10.20/receipts/kd-legacy-triage-20261021.md`)
had already live-probed all 11 and registrar-closed KD-04 and KD-13. No row is
typed with an out-of-register category anymore; every row is triageable state
(CLOSED-WITH-RECEIPT or OPEN + explicit Disposition).

## Per-row verdicts

| Row | Verdict | Evidence |
|---|---|---|
| KD-04 | CLOSED-n (pre-existing) | `CLOSED-WITH-RECEIPT`; live wire answers 400 InvalidQueryParameterValue on comp=bogus; witness `docs/jira/v26.10.20/receipts/kd-legacy-triage-20261021.md` + rename witness `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md` — both on disk, verified |
| KD-13 | CLOSED-n (pre-existing) | `CLOSED-WITH-RECEIPT`; full soft-delete lifecycle LIVE (create/DELETE/getDeleted/recover/get all 200); witnesses on disk (kd13-kd75-softdelete-routes-witness.md + 20261021 triage) |
| KD-10 | DISPOSITIONED | Fresh probe (substrate pid 1895): PUT /keys/bk11probe → 400 MissingXMsVersion blob catch-all — unrouted face re-witnessed. Disposition: fix-and-witness; falsifier: PUT answers 200 + kid + GET readback; next: `put /keys/:name` in lib/smalt/egress/KvRoutes.ex, `# KD-COVERS: KD-10` |
| KD-75 | DISPOSITIONED | Shares the KD-10 PUT face; one route closes both. Disposition: fix-and-witness; falsifier: updateKey → 200 readback |
| KD-14 | DISPOSITIONED | Fresh probe: key bk11v2 created 200, sign 200 (kid .../637446), substrate verify = `{"valid":false}` — divergence LIVE. Disposition: fix-and-witness; falsifier: external crypto.verify true, or contract-pin w/ fence receipt; next: fix RS256 sign shape in KvRoutes.ex crypto path |
| KD-23 | DISPOSITIONED (row repaired) | Fresh probe: pipe-leading `\| where ... \| project` 200; bare-mixed 400 SYN0003; pipe-mixed-no-leading-bar 400 SYN0002 — 400 BadQuery-class (the morning run's 500-class face did not reproduce). Also REPAIRED the row itself: unescaped `\|` pipes inside the status cell were splitting the table row (now renders 6 cells like every other row) |
| KD-79 | DISPOSITIONED | Fresh probe: vault PUT 202 → GET 200, vaultUri `http://127.0.0.1:9443/` — loopback-by-design constant holds. Disposition: documented-constant; falsifier: azurerm apply terminal without "no such host"; no code change owed unless a DNS-shape vault host mapping lands |
| KD-86 | DISPOSITIONED | Code-face re-read: `ensure_queue/1` still on put/dlq paths (queue_store.ex:210/356/380), no config flag. Disposition: fix-and-witness (config-flag gate, default = real-SB MessagingEntityNotFound); falsifier: flag off → typed refusal, not silent creation |
| KD-90 | DISPOSITIONED | Bench re-read: docs/jira/v26.10.16/bench/affidavit-seal.jsonl lane c10 n=100 errors 0, p50 11.265ms / p95 26.491ms — b3sum spawn floor, no NIF swap. Disposition: fix-and-witness (perf); falsifier: post-NIF-swap p50 materially below ~4ms spawn floor; next: in-process blake3 NIF in lib/smalt/affidavit/seal.ex |
| KD-92 | DISPOSITIONED | Fresh probe: ARM PUT containers/bk11c 201 → data-plane PUT /smalt/bk11c/bk11.txt 404 ContainerNotFound — divergence LIVE. Disposition: fix-and-witness; falsifier: ARM PUT → blob PUT 201; next: mirror container record into `:smalt_blob_containers` (lib/smalt/arm_gateway/router.ex), `# KD-COVERS: KD-92` |
| KD-93 | DISPOSITIONED | Fresh probe, fresh db bk93b1792636132: db 201 / coll 201 / doc POST 201 / direct GET 200, but parameterized-filter query feed answers id `doc_637510` — a doc the run never wrote (mint's exact face). Disposition: fix-and-witness; falsifier: query right after PUT returns the just-written id; next: db/coll scoping + parameterized filtering in lib/smalt/data_plane/cosmos.ex |

Notes:
- KD-04/13 flips were registrar actions with receipts predating this lane;
  verified on disk, no flip owed from BK-11, no shim landed by this lane, so no
  `kd_flip.py --apply` runs (flip machinery is CLOSED-SIMULATED-scoped).
- WIRE-02 shim reconciliation untouched (BK-6's).
- Substrate: booted by BK-11 (`substrate.sh up`, elixir 1.20.2-otp-28,
  MIX_BUILD_ROOT=_build-bk11) after the shared substrate was DOWN at lane
  start; UP as pid 1895, lock FREE after window lock release.
- Register cell-count receipt: all 11 rows render exactly 6 cells
  (KD-23 previously split by unescaped pipes — repaired).

## Probe transcript (exit/body evidence, 2026-10-21, substrate pid 1895)

    # token: POST https://127.0.0.1:9444/.../oauth2/v2.0/token -> 200
    # KD-10/KD-75  PUT http://127.0.0.1:8443/keys/bk11probe?api-version=7.4
    -> 400 MissingXMsVersion (blob catch-all — unrouted)
    # KD-14  POST /keys/bk11v2/create 200; POST sign 200 (kid .../637446);
    POST verify {"valid":false}
    # KD-23  pipe-leading 200 (0 records); bare-mixed 400 SYN0003;
    pipe-mixed 400 SYN0002
    # KD-79  vault PUT 202; GET 200 vaultUri http://127.0.0.1:9443/
    # KD-92  ARM PUT containers/bk11c 201; blob PUT 404 ContainerNotFound
    # KD-93  fresh db bk93b1792636132: 201/201/201/GET 200;
    query feed -> id doc_637510 (never written this run)
    # KD-86  code face: queue_store.ex:210/356/380 ensure_queue/1, no flag
    # KD-90  bench jsonl re-read: p50 11.265ms / p95 26.491ms (c10, n=100)
