// Package pinion relocates the five wire-compat pinions (v26.10.31
// inversion, lane 15 / digest L6 "DO NOT CLEAN UP") from the BEAM core into
// the posh dialect layer. BYTE FIDELITY IS LOAD-BEARING — every census
// comment below is relocated VERBATIM from its BEAM source (path:line in
// each comment header). Behavioral semantics stay BEAM-side; this package
// is the relocated LAW TABLE + executable proofs.
package pinion

import (
	"crypto/md5"
	"fmt"
)

// ---------------------------------------------------------------------------
// Pinion 1 — sasl-outcome descriptor 0x44
// RELOCATED VERBATIM from lib/smalt/messaging/amqp/frame_codec.ex:69-71:
//
//    # sasl-outcome is 0x44 (wire-lane fix: real-SDK census showed the earlier
//    # 0x42 got dispatched as a challenge by rhea)
//
// ---------------------------------------------------------------------------

// SASLOutcomeDescriptor is 0x44.
const SASLOutcomeDescriptor = 0x44

// ---------------------------------------------------------------------------
// Pinion 2 — SASL ANONYMOUS-only
// RELOCATED VERBATIM from lib/smalt/messaging/amqp/connection/handshake.ex:8-19
// (module doc) and :27/:101:
//
//    BYTE-PINION SURFACE — do not "clean up" any of the following; they are
//    real-SDK-census-pinned (smalt CLAUDE.md):
//
//    - SASL ANONYMOUS only; the advertised mechanism set on the wire stays
//      exactly `[ANONYMOUS]` even when a module attribute or profile config
//      excludes it.
//    ...
//        # the wire stays exactly [ANONYMOUS] (wire-compat pinion, verbatim).
//
// ---------------------------------------------------------------------------

// SASLAdvertisedMechanisms is the ONLY set ever advertised on the wire.
// AZB-07: a configured profile list that excludes :anonymous types the
// refusal (sasl-outcome code 1) but the ADVERTISED set never changes.
var SASLAdvertisedMechanisms = []string{"ANONYMOUS"}

// ---------------------------------------------------------------------------
// Pinion 3 — attach top-level <= 14 fields, locale fields omitted
// RELOCATED VERBATIM from lib/smalt/messaging/amqp/frame_codec.ex (attach
// field list, dialect 103-120; trim_trailing_nulls comment 236-240):
//
//      # NO outgoing_locales/incoming_locales here: those are `open` fields.
//      # Including them made every attach reply a 16-element list; the AMQP
//      # attach composite has 14 fields, and pyamqp reconstructs
//      # AttachFrame(*frame) positionally -> "takes 15 positional arguments
//      # but 17 were given" and the whole SDK handler crashed (py-court lane
//      # 91 wire evidence, 2026-10-14).
//
//      # AMQP lists may omit trailing null fields (spec §1.4.3). Emitting them
//      # inflates the positional arity for strict clients: pyamqp decodes lists
//      # with the wire element count and reconstructs performatives as
//      # `NamedTuple(*frame)`, so a padded attach crashed the SDK handler
//      # (TypeError 17-vs-15). Trailing nulls are dropped before encoding.
//
// ---------------------------------------------------------------------------

// AttachFields is the 14-field attach composite field order (spec order,
// locale fields omitted).
var AttachFields = []string{
	"name", "handle", "role", "sndSettleMode", "rcvSettleMode",
	"source", "target", "unsettled", "incompleteUnsettled",
	"initialDeliveryCount", "maxMessageSize",
	"offeredCapabilities", "desiredCapabilities", "properties",
}

// ---------------------------------------------------------------------------
// Pinion 4 — .NET-GUID lock-token double-involution
// RELOCATED VERBATIM from lib/smalt/messaging/amqp/lock_manager.ex:60-94
// and lib/smalt/messaging/amqp/management_rpc/shared.ex:82-105:
//
//    # `format_uuid/1`: dashed UUID string -> raw 16 bytes in the on-wire
//    # .NET-GUID-reordered layout the delivery-tag actually carries
//    # (`token_to_wire/1`, connection.ex delivery_tag). The store keys the
//    # dashed form. Returning the straight uuid layout here made tests
//    # synthesizing wire bytes mint a permuted store key on settle ->
//    # 410 MESSAGE_LOCK_LOST on every live lock (repair lane R51).
//
//    # Wire lock tokens arrive as raw uuid values the SDK already reordered
//    # .NET-GUID style (LockManager.token_to_wire/1, shouldReorderLockToken: true).
//    # The reorder is an involution, so applying it once more restores the raw
//    # layout before format_uuid; straight-formatting the delivered bytes minted
//    # a permuted store key and 410s on every live-lock settle/renew.
//
// ---------------------------------------------------------------------------

// ReorderNETGUID applies the .NET-GUID byte reorder
// [b3,b2,b1,b0, b5,b4, b7,b6, rest] to 16 bytes. It is an INVOLUTION
// (Reorder(Reorder(x)) == x) — the load-bearing property.
func ReorderNETGUID(b []byte) ([]byte, error) {
	if len(b) != 16 {
		return nil, fmt.Errorf("pinion: lock token must be 16 bytes, got %d", len(b))
	}
	out := make([]byte, 16)
	out[0], out[1], out[2], out[3] = b[3], b[2], b[1], b[0]
	out[4], out[5] = b[5], b[4]
	out[6], out[7] = b[7], b[6]
	copy(out[8:], b[8:])
	return out, nil
}

// ---------------------------------------------------------------------------
// Pinion 5 — EH fixed partitions ["0","1"], md5-rem-2
// RELOCATED VERBATIM from lib/smalt/messaging/amqp/connection/link.ex:888-929
// and the REST twin lib/smalt/egress/EventHubsRestRoutes.ex:223-232
// (concurrent-twin law RSK-05: both halves relocated in the SAME package so
// the partition law cannot split):
//
//    # EH fixed-partition pinion: only the pinned partitions ["0","1"] exist.
//    # A partition-scoped attach outside the pin is refused — the send side
//    # already pins storage to the pair (eh_pk_partition rem 2), so accepting
//    # "2" would silently attach a receiver that can never be delivered to.
//    # Hub-scoped and non-partition tails stay nil (aggregate path).
//
//    # KD-76 (reuse, never re-derive): the pk-partition rule is the SAME law the
//    # AMQP lane runs (`Smalt.Amqp.Connection.eh_pk_partition/1`): first byte of
//    # md5(pk), integer remainder over the pinned partition set ["0", "1"].
//    # Non-binary keys hash their term encoding.
//
// ---------------------------------------------------------------------------

// EHFixedPartitions is the pinned partition set.
var EHFixedPartitions = []string{"0", "1"}

// EHPartitionOf is the pk-partition rule shared by BOTH twins: first byte
// of md5(pk) mod 2 over the pinned set. The REST twin and the AMQP twin
// must resolve the same pk to the SAME partition (RSK-05).
func EHPartitionOf(pk []byte) string {
	sum := md5.Sum(pk)
	return EHFixedPartitions[int(sum[0])%2]
}

// EHPartitionAdmitted reports whether a partition-scoped attach targets the
// pinned set.
func EHPartitionAdmitted(p string) bool {
	return p == "0" || p == "1"
}

// ---------------------------------------------------------------------------
// Executable pinion spec — court_wire.erl byte-law port seeds
// ---------------------------------------------------------------------------

// SASLProtocolHeader / AMQPProtocolHeader (court_wire.erl leg-1 headers).
const (
	SASLProtocolHeader = "AMQP\x03\x01\x00\x00"
	AMQPProtocolHeader = "AMQP\x00\x01\x00\x00"
)

// WirePerfID encodes the AMQP described-type performative id as the 3-byte
// constructor <<0x00, 0x53, desc>> used by test/courts/court_wire.erl.
func WirePerfID(desc byte) []byte {
	return []byte{0x00, 0x53, desc}
}

// AttachFieldCount is the attach composite arity tripwire: 14.
const AttachFieldCount = 14
