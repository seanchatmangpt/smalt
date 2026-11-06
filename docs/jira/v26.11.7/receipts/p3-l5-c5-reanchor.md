# P3-L5 C5_SERVICEBUS Re-Anchor Receipt

Standing: PARTIAL_ALIVE

Lane: P3-L5 of `00-azure-out-migration-charter.md` P3 (C1-C7 re-anchoring).
Subject: `docs/compliance/C5_SERVICEBUS.md` — arcus anchors appended to the
Results matrix; smalt anchor text byte-identical (appended in-cell only,
never substituted). Per-anchor line pins derived at execution from the
landed arcus tree (`/Users/sac/arcus`), per plan §Anchor form.

## Commands

- Arcus counterpart census:
  `grep -rn -i 'sasl\|0x44\|anonymous' /Users/sac/arcus/internal --include='*.go' | grep -vi _test` → 0 matches
  (SASL layer absent from arcus; loud counterpart-absent verdicts).
- Anchor files verified on disk: `/Users/sac/arcus/internal/dialect/azure/{amqp_annotations,cbs,sb_rest,leases,eh_pinions,eh_rest,entitypath}.go`.
- Smalt pinion loci re-read at receipt time: `frame_codec.ex:69-73` (0x44
  comment), `frame_codec.ex:117` (attach composite 14 fields), `frame_codec.ex:316`
  (pyamqp arity tripwire), `connection.ex:20-21` (SASL `[ANONYMOUS]` offer),
  `lock_manager.ex:61,68,77,86` (.NET-GUID reorder).
- No git transitions (per lane contract).

## Results matrix re-anchor summary (20 rows, R1-R14 + R6a/R6b/R7a/R9a/R9b-i)

- CONFIRMED counterparts (3): R9b filetime law →
  `amqp_annotations.go:31-50` (FiletimeEpochOffsetTicks :34,
  FiletimeFromMs :43, FiletimeToMs :47; dual annotation encode :109-110 —
  const matches the smalt CODE value 621_355_968_000_000_000, not the
  drifted delivery_encoder.ex:124 moduledoc); R10 $cbs → `cbs.go:59-60,152+`
  (put/delete-token ops, CBSRouter.PutToken, 200
  LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY :20,:43); R12 DLQ naming →
  `entitypath.go:10-11,34-35,63,208-218` (DLQSuffix/DLQName/IsDLQ; casing
  normalize half absent, disclosed).
- PARTIAL counterparts (3): R8 REST error vocabulary `sb_rest.go:369-379`
  (amqp:error-conditions symbols absent); R9b-i annotation-encode half
  `amqp_annotations.go:109-110` (attach-properties half absent); R11 REST
  renew/unlock arms `sb_rest.go:10-12,332-333` (AMQP management RPC absent).
- UNSUPPORTED(counterpart-absent) (14 rows): R1-R7, R6a, R6b, R7a, R9, R9a,
  R13, R14 — the AMQP wire/frame layer did not travel to arcus; every such
  cell says so loudly with receipt pointer. No silent skips.

## KD pinion receipts (charter §4.2 five rows; witness = SHIM-COURT R51)

R51 witness statement (charter :35, :113): the "cleaner" straight-uuid
lock-token layout caused 410 MESSAGE_LOCK_LOST on every live lock. Each
pinion below cites R51 as the relocation-falsifier witness; a relocation
that flips a real-SDK census = migration FAIL (charter §6.2).

| # | Pinion | smalt byte pin | arcus counterpart | Pinion verdict |
|---|--------|----------------|-------------------|----------------|
| 1 | SASL ANONYMOUS-only | `connection.ex:20-21` (server offers `[ANONYMOUS]`, expects sasl-init mechanism ANONYMOUS, replies sasl-outcome 0) | ABSENT — zero SASL matches in arcus `internal/` (command above) | **UNSUPPORTED(counterpart-absent)** — loudly missing; no arcus-side byte pin exists |
| 2 | sasl-outcome descriptor 0x44 | `frame_codec.ex:69-73` ("sasl-outcome is 0x44 (wire-lane fix: real-SDK census...)") | ABSENT — no AMQP frame codec in arcus | **UNSUPPORTED(counterpart-absent)** — loudly missing |
| 3 | attach top-level ≤14 arity (source=8/target=7 tripwires, locale fields omitted) | `frame_codec.ex:117` (14-field composite), `frame_codec.ex:316-330` (pyamqp `Target.__new__() takes 1 to 8 positional arguments but 9 were given` tripwire) | ABSENT — no attach encode/decode in arcus | **UNSUPPORTED(counterpart-absent)** — loudly missing |
| 4 | .NET-GUID lock-token byte reorder | `lock_manager.ex:61,68,77-88` (token_to_wire, shouldReorderLockToken: true layout) | PRESENT — `eh_pinions.go:103-135`: EhTokenToWire (func :115) ports token_to_wire byte-exact, layout `[b3,b2,b1,b0, b5,b4, b7,b6, b8..b15]` (:109), inverse EhTokenFromWire (:136-148), EhFormatUUID (:150-154); in-file comment cites R51 (:112 "Returning the straight uuid layout here caused 410 MESSAGE_LOCK_LOST on every live lock (smalt SHIM-COURT R51)") | **PASS** — byte-law present, R51 cited in-file as witness; round-trip identity declared part of the pinion |
| 5 | EH fixed partitions `["0","1"]` | smalt KD-76 pinned partition surface (pinned_partitions 2) | PRESENT — `eh_pinions.go:28-32` EhPinnedPartitionIDs = ["0","1"] ("Order is load-bearing"); EhPartitionAdmits :51-61 (func :56) refuses out-of-pin partitions (ErrEhPartitionOutOfPin :38); `eh_rest.go:24,46-47` (EhPinnedPartitions=2, KD-76 cited), EhPKPartition :183-188 (md5(pk) first byte mod 2) | **PASS** — byte-law present, order pinned, refusal typed |

Pinion standing: 2/5 PASS with arcus byte pins (rows 4-5, eh_pinions.go);
3/5 UNSUPPORTED(counterpart-absent) (rows 1-3 — SASL ANONYMOUS-only,
descriptor 0x44, attach ≤14 arity). The three UNSUPPORTED rows are the
charter §4.2 relocation risk realized in part: the AMQP handshake/frame
byte-laws have NO arcus-side pin at execution time and are recorded
loudly, never silently skipped.

## Falsifier

Charter §6.2: any pinion byte-law that flips a real-SDK census after
relocation = migration FAIL. Rows 4-5 are the exact R51 pattern (straight
uuid layout → 410 MESSAGE_LOCK_LOST) already encoded as typed refusals in
eh_pinions.go. Rows 1-3 cannot flip a census in arcus because there is
nothing to flip — their falsifier is deferred to whichever membrane
receives the AMQP face.

## Notes

- `leases.go:13` cites SHIM-COURT R51 for the BLOB lease break/release
  transition table (KD negative law), not the AMQP lock token — it is the
  R51 pattern witness on the storage face, NOT a pinion-4 byte pin. The
  pinion-4 arcus pin is eh_pinions.go EhTokenToWire only.
- amqp_annotations.go:3-5 states: "Annotations are map[string]any; the AMQP
  wire codec is out of scope — this file carries only the annotation
  naming, typing, and conversion law." Consistent with the 14
  UNSUPPORTED(counterpart-absent) rows.

Standing: PARTIAL_ALIVE — doc re-anchor executed and verified on disk;
3 CONFIRMED + 3 PARTIAL + 14 loud UNSUPPORTED rows; 2/5 pinions pinned,
3/5 loudly counterpart-absent. Not PASS because three charter §4.2
byte-laws have no arcus-side pin at execution time.
