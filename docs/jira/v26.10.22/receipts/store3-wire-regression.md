# STORE-3 — Store partitioning wire regression court

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-21
Lane build root: `MIX_BUILD_ROOT=_build-store3` (lease — coordinator deletes at integration)
File: `test/integration/store_partition_wire_regression_test.exs` (new; no `lib/` edits)
Command: `MIX_BUILD_ROOT=_build-store3 mix test test/integration/store_partition_wire_regression_test.exs --seed 0` → **Result: 6 passed, exit 0**; re-run `--seed 7` → **6 passed, exit 0** (two green seeds).

## Per-plane verdicts

| face | leg | verdict | evidence |
|---|---|---|---|
| Blob | leg1 PUT/GET/If-Match round-trip | **ALIVE** | PUT 201 w/ ETag; GET 200 same etag + byte-identical body; replace with current If-Match admits + etag rotates; stale If-Match 412; GET If-Match 200 (KD-144/145/146 etag family preserved) |
| Cosmos | leg2 doc CRUD + parameterized query | **ALIVE** | create-db 201, create-coll 201, doc create 201 (quoted-GUID `_etag`), read-your-write GET 200 seq=1, replace 200 etag rotates, delete → 404, recreate + `application/query+json` parameterized query → 200 hits just-written doc; absent-id query honest empty (KD-93 face) |
| SB | leg3 send/consume, real AMQP wire | **ALIVE** | real TCP socket + `Smalt.Amqp.Connection` + real CBS put-token (LOCAL_SIGNATURE_VERIFIED, status 200), codec-native sender transfer → wire `accepted` disposition; receiver link credit → transfer with byte-identical body; real accepted disposition → `QueueStore.peek` empty (kd86 face, kd134 wire-client pattern) |
| Partition isolation | leg4a crash owner of key A | **ALIVE** | `Store.partition_count() == 16`; phash2(table,16) mapping printed: a→p9, b→p15, c→p2 (3 stripes); real `Process.exit(owner_pid, :kill)`; DURING window B and C serve reads AND writes (direct + serialized `insert_new` on a 4th stripe); only the crashed partition respawns (1/16 = 6.25% blast radius); A recovers content-intact and resumes writes |
| Partition crash + heir | leg4b partition-owner kill | **ALIVE** | (re-authored at BK-105/BK-69r, see collision disclosure) heir hold keeps the table defined and reads serving through the kill; sibling stripe serves reads+writes+serialized during window; only the crashed partition respawns and RECLAIMS the heir-held table (`Heir.reclaim_table` give-away) with zero key loss; sealed keys survive a full-ensemble kill via Boot replay |
| TTV-4 interplay | leg5 journal-sealed full restart | **ALIVE** | sink on, 5 keys across 4 plane tables (resources/subscriptions/blobs/cosmos_docs), `JournalSink.seal` (≥5 frames), real ensemble kill + supervisor restart → "journal replay restored 5 frame(s)", all 5 keys recovered across ALL tables (no table's frames skipped) |

## Partition-isolation evidence (leg 4a, both runs)

```
[store3] phash2/16 partition mapping: [{:a, "store3-iso-a-smalt_appconfig", :smalt_appconfig, 9},
 {:b, "store3-iso-b-smalt_attestation_baseline", :smalt_attestation_baseline, 15},
 {:c, "store3-iso-c-smalt_blob_containers", :smalt_blob_containers, 2}]
```

- 16 partitions asserted (`Store.partition_count() == 16`); 1/16 = the ≤6.25% gate.
- Real `Process.exit(pid, :kill)` on `Smalt.Store.Partition.whereis_owner(Store, t_a)` — no mocks.
- During-window service of B/C asserted with both direct (`get`/`put`) and serialized
  (`insert_new`) ops on untouched stripes.
- Bounded polls only (`SmaltTest.Internal.Poll.eventually/2`); zero `Process.sleep`.

## Defects / findings for owner dispatch

1. **RESOLVED mid-lane by the owner lane (BK-69r/BK-105)** — my original leg4b
   witnessed a full-ensemble kill with journaling OFF losing all table contents
   ("GenServer Smalt.Store.Heir terminating (stop) killed" → dead-heir chain deletes
   every table). The owner lane re-authored leg4b to the landed contract: the heir
   guarantees PARTITION-crash zero-loss (leg4a/leg4b witness it); a full-ensemble
   kill is replay's job (leg5 witnesses recovery); full-kill-with-journaling-OFF is
   the documented dead-heir face. The typed boundary is now court-fenced.
2. **kd_conformance cosmos face (pre-existing, not session-introduced)**: while
   authoring leg2 I found `test/integration/kd_conformance_test.exs` POSTs
   `/dbs/:db/colls/:coll` (4 segments) to create a container — no such route exists
   (`POST /dbs/:db/colls` with body id is the create face; 404 in 146µs witnessed).
   Its cosmos KD-147/148/CAS412 tests appear to exercise the wrong route. Owner
   should re-witness or fix; not touched (outside lane lease).

## Lane collisions (disclosed per same-checkout-fanout)

- Two compile-freeze windows hit the shared tree mid-lane
  (`lib/smalt/powl2/change_feed.ex`, then `lib/smalt/storage/journal_sink.ex`); both
  were fixed by their owners within the SLA; no unblock applied by this lane.
- **BK-69/BK-105 (STORE-4 reconciliation) edited this lane's owned court file
  twice**: first re-typing leg4a (superseded — the partition surface landed, so I
  re-typed it back to the real crash gate), then re-authoring leg4b into the
  partition-owner-kill form now on disk. Both of my final green runs executed the
  on-disk joint version; the re-author subsumed my typed-loss-face draft (its
  content-intact claim is subsumed by leg4a). Disclosure here attributes the joint
  authorship; coordinator owns the integration diff.

## Non-vacuity notes

- No mocks anywhere; real sockets, real Process.exit kills, real journal bytes.
- Wire legs assert final wire state (status/header/bytes), never call counts.
- leg4a's during-window assertions would fail under a single-owner store (they ran
  green only after the partitioned design landed mid-lane — the court demonstrably
  distinguishes the two designs).

## Standing rationale

All five wire/isolation faces green on two seeds against the live partitioned store
(16 × `Smalt.Store.Partition` + `Smalt.Store.Heir` + `Smalt.Store.Boot`). The
partition-isolation gate (≤6.25% blast radius, sibling service during window, heir
give-away recovery) is witnessed on the production path. Standing **ALIVE**.
