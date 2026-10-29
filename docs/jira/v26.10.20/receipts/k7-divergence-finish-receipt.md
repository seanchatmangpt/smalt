# Lane K7 receipt — divergence-finish: infra/egress/misc (2026-10-21)

**Standing:** PARTIAL_ALIVE (4 FLIP-ELIGIBLE closes + 1 narrow fix, 5 documented dispositions)
Context: solo
Repo: /Users/sac/smalt

## Dispositions (all 10 rows probed)

| row | disposition | evidence |
|---|---|---|
| KD-35 egress TLS | HEAVY (documented, substantially narrowed) | TLS twin dispatch (lib/smalt/application.ex TlsTwinDispatch) now serves /keys /secrets /certificates /deletedsecrets etc. over 9444 — the KD-102/103/109 probes this lane ran all rode the twin. Remaining faces: blob guarded catch-all is http-8443-only by design (application.ex:126 comment) and AMQP 5672 is plaintext (SDKs pin `UseDevelopmentEmulator=true`). Full egress TLS = new listeners on the blob/file plane — heavy, not 80/20. |
| KD-48 census harness | OBSOLETE (subject deleted) | scripts/sb_census_replay.sh is a loud RETIRED no-op — exit 1 naming successor V261019-08; the census subject (test/sdk-smoke/census-run.mjs) was deleted at 64f6099. Falsifier ("unmodified front-door run passes") is unreplayable against a retired subject; row can retire via the registrar. |
| KD-84 SB settlement race | HEAVY (documented) | No disposition flush on receiver close in lib/smalt/messaging/amqp/connection.ex (no flush path in the :detach arm). Falsifier subject (workspace/test/servicebus_dataplane.test.ts test 04) deleted at 64f6099 — the race fix needs a live court subject to falsify against; fixing blind without a court would be unverifiable. |
| KD-85 annotation stamp | FIX (landed; PARTIAL_ALIVE) | delivery_encoder.ex dual-stamps `x-opt-enqueued-time` + `-utc` (`# KD-COVERS: KD-85`); witness: kd85-sb-enqueued-time-annotation-witness.md. SDK-side falsifier pending the V261019-08 successor. |
| KD-88 EH pump warm-up race | HEAVY (documented) | Cold-boot attach race in the EH deliver/$management path; the PHASE_A_RETRY_WITNESSED court retries loudly, so the flake is witnessed, not faked. Root-causing a cold-boot race is not 80/20 for this lane. |
| KD-101 EG webhook push | PINION (no work) | v26.10.19 register already narrowed the row: webhook RECEIVER landed (lib/smalt/event_grid_webhook.ex verified on disk, 13.6 KB); remote-push is forbidden by the air-gap/loopback law — a permanent typed divergence. Nothing left to fix. |
| KD-102 KV secrets soft-delete | VERIFY — FLIP-ELIGIBLE | Surface already landed (KvRoutes deleted-secrets plane); K7 verified the full falsifier live over the TLS twin (kd102-kv-secrets-softdelete-witness.md): delete → getDeletedSecret(recoveryId) → recover → get → list → purge → typed 404. |
| KD-103 KV secrets backup/restore | FIX (landed) — FLIP-ELIGIBLE | Engine existed engine-only; the real Azure restore wire shape (`POST /secrets/restore`, conflict→409) was missing — K7 added `post "/secrets/restore"` + `post "/keys/restore"` (`# KD-COVERS: KD-103`) with the engine's Conflict refusal mapped to 409; full backup→purge→restore→get roundtrip + 409 + tamper refusal witnessed live (kd103-kv-secrets-backup-restore-witness.md). |
| KD-107 blob snapshots | VERIFY — FLIP-ELIGIBLE | Full lifecycle already landed (snapshot/list/lease-on-snapshot engine + wire, blob lane KD-107 RAISE 2026-10-20); K7 verified create → include=snapshots list → read-at-snapshot live (kd107-blob-snapshots-witness.md). 409 on base overwrite is the WORM policy arm, not a snapshot divergence. |
| KD-109 appconfig feature flags | FIX (landed) — FLIP-ELIGIBLE | Typed flag engine existed with zero callers; K7 wired `.appconfig.featureflag/{name}` writes through AppConfigFeatures.put_flag/4 in AppConfigRoutes.ex (`# KD-COVERS: KD-109`); typed 201 roundtrip → GET typed record → invalid body typed 400 InvalidFeatureFlag witnessed live (kd109-appconfig-feature-flags-witness.md). |

## Subject-deletion verification (verify-before-typing)

- KD-48: scripts/sb_census_replay.sh on disk = RETIRED loud no-op (exit 1,
  names V261019-08); census subject deleted at 64f6099. OBSOLETE-class.
- KD-84: workspace/test/servicebus_dataplane.test.ts not on disk —
  verified deleted at 64f6099; HEAVY class (court subject must be re-authored).

## Shared-tree disclosures

1. cosmos.ex compile-freeze window (18:56-19:01, another lane's edit): K7
   waited out the owner's window; compile green after — no K7 touch.
2. KvRoutes.ex truncation incident (19:14): a concurrent lane truncated
   lib/smalt/egress/KvRoutes.ex to a 416-byte fragment (its own base snapshot
   /tmp/kvroutes_base.ex is also 0 bytes). K7 restored the shared file from
   lane k3's byte-complete 19:08 snapshot (/private/tmp/k3_KvRoutes.ex.orig,
   contains the KD-102 plane + K7's KD-103 routes) and re-applied the K7
   409-Conflict patch on top; compile green, all live probes green after.
   Full disclosure also in kd103-kv-secrets-backup-restore-witness.md.

## Substrate events (honest)

The live substrate went DOWN mid-probe (~19:02, not a K7 action — flock FREE
afterwards). K7 brought it back with `just substrate-up` once the shared
compile unbroke, and ran down/up cycles to load K7's own lib/ changes; the
final substrate instance carries the K7 code and all receipted probes ran on
it. STS keys rotate per boot — tokens re-fetched each cycle.

## Files touched (K7-owned edits)

- lib/smalt/messaging/amqp/delivery_encoder.ex (KD-85 dual stamp)
- lib/smalt/egress/KvRoutes.ex (KD-103 restore wire routes + 409 mapping;
  plus truncation-restore from the k3 snapshot)
- lib/smalt/egress/AppConfigRoutes.ex (KD-109 typed feature-flag wire)
- docs/jira/v26.10.20/receipts/: kd102-, kd103-, kd107-, kd109-, kd85-
  witnesses + this lane receipt

No bench jsonl written (probes are witness probes, not load lanes). Rows stay
OPEN in the register — flips go through scripts/kd_flip.py --apply (registrar,
receipt-gated), no status-column hand-edits.
