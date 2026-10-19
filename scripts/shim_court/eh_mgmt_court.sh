#!/usr/bin/env bash
# eh_mgmt_court.sh — KD-18/19/20 shim court (lane S-2, v26.10.15; ported to
# scripts/shim_court/lib.sh per ERRC lane E6).
#
# Subject: lib/smalt/messaging/amqp/connection.ex (the EH arm of
# deliver_eventhubs + the management request map). The KD-18/19/20 fix is
# LANDED, so the lib.sh orientation is inverted (same shape as
# eh_batch_court.sh):
#
#   BASELINE  sha256(connection.ex)
#   BEFORE    real @azure/event-hubs probe (test/sdk-full/eventhubs.probe.mjs)
#             PASSES on the landed file: getEventHubProperties /
#             getPartitionProperties over the real AMQP wire, typed 404
#             PARTITION_NOT_FOUND on unknown partition, wire delivery with
#             integer sequence numbers.
#   SHIM      TEXTUALLY strip the KD-19 request fields + KD-18 message_format
#             + KD-20 credit bump (marked SHIM-COURT) — never via git, so
#             sibling-lane hunks in the same file are untouched.
#   AFTER     probe FAILS with the registered gaps (mgmt READ -> 501,
#             SDK-tier delivery bodies null, "Received transfer when credit
#             was 0"). The flip (green landed / red shimmed) is the
#             non-vacuity proof.
#   RESTORE   sha256 byte-exact, fail-closed.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 2
source "scripts/shim_court/lib.sh"

# EXPORTED: with_shim runs the witnesses via bash -c (a child process) —
# unexported shell vars arrive EMPTY there (witnessed 2026-10-16: node ""
# degraded to a REPL no-op exiting 0, so both probe legs "passed" on zero
# output and the flip was vacuous).
export SUBJECT="lib/smalt/messaging/amqp/connection.ex"
# RETIRED witness (clean-room test reset, 64f6099): the probe tree was
# deleted with no verification/ successor yet; the court self-skips loudly
# (exit 3) until a successor witness lands.
export PROBE=""
# Lane-local build root for ALL mix legs (compile retry + probe substrate):
# the shimmed subject must never compile into the shared _build, and the
# witness vars must be EXPORTED — with_shim runs them via bash -c, where
# unexported shell vars arrive empty (witnessed 2026-10-16: empty
# MIX_BUILD_ROOT makes mix resolve its build path to /test).
export MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build-lane13}"

[ -f "$PROBE" ] || shim_court_skip "witness probe not found: $PROBE"
command -v node >/dev/null || shim_court_skip "node not installed"

shim_court_self_check || { echo "[FAIL:SELF-CHECK]" >&2; exit 1; }

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, os, time
p = sys.argv[1]
s = open(p).read()
# KD-19 strip: type/name/partition out of the management request map.
# Anchored on the KD-COVERS comment so the SB-path request map is not touched.
old = """      # KD-COVERS: KD-19 — Event Hubs READ management ops carry type/name/partition as
      # application properties (managementClient.js sends body = JSON "[]" —
      # the entity name is NOT in the body).
      type: props["type"],
      name: props["name"],
      partition: props["partition"],
"""
if old not in s:
    sys.exit("KD-19 request fields not found (drifted)")
s = s.replace(old, "      # SHIM-COURT: KD-19 request fields stripped for the court\n")
# KD-18/20 strip: message_format + body extraction + credit bump out of
# deliver_eventhubs (KD-18 message_format, KD-20 credit bump, eh_body_section).
# (2026-10-16 R29: landed delivery builds the section list into a `sections`
# binding before send_message — anchor re-tied to that shape.)
old2 = """          sections =
            [
              # GAP-A2-04: x-opt-offset / x-opt-enqueued-time /
              # x-opt-partition-key surface on every delivery; the SDK's
              # fromRheaMessage maps them to event.offset / enqueuedTimeUtc /
              # partitionKey. x-opt-sequence-number is pre-existing.
              {:message_annotations, eh_event_annotations(ev)}
              | eh_delivery_annotations(partition) ++ [eh_body_section(body)]
            ]

          {st, _id} =
            send_message(
              st,
              link,
              %{
                handle: link.handle,
                delivery_tag: <<seq::unsigned-64>>,
                # KD-COVERS: KD-18,KD-20 — format 0 = standard decoded-message
                # path (SB path below). Keep consistent on EVERY EH arm; the
                # credit bump below closes KD-20.
                message_format: 0
              },
              sections
            )

          # SHIM-COURT R13/V261014-04-F1 fix: re-read the link refreshed by
          # bump_credit (deliver_to_link pattern) — the outer `link`'s credit
          # was never decremented, so put_link used to restore stale credit
          # and the :1389 guard kept draining past the grant (over-delivery).
          st
          |> Map.update!(:eh_cursors, fn m -> Map.put(m || %{}, partition, seq) end)
          |> then(&bump_credit(&1, link.channel, link.handle, -1))
          |> then(fn st2 ->
            put_link(st2, %{st2.links[{link.channel, link.handle}] | eh_link_cursor: seq})
          end)
"""
new2 = """          # SHIM-COURT: KD-18 message_format stripped; KD-20 credit bump
          # stripped; eh_body_section -> raw body_data (defect shape).
          sections =
            [
              # SHIM-COURT: annotations pinned to pre-GAP-A2-04 shape for the probe
              {:message_annotations, eh_event_annotations(ev)}
              | eh_delivery_annotations(partition) ++ [{:body_data, body}]
            ]

          {st, _id} =
            send_message(
              st,
              link,
              %{
                handle: link.handle,
                delivery_tag: <<seq::unsigned-64>>
              },
              sections
            )

          st
          |> Map.update!(:eh_cursors, fn m -> Map.put(m || %{}, partition, seq) end)
          # SHIM-COURT: KD-20 credit bump stripped; the eh_link_cursor refresh
          # hunk is NOT part of the shim and is left verbatim.
          |> then(fn st2 ->
            put_link(st2, %{st2.links[{link.channel, link.handle}] | eh_link_cursor: seq})
          end)
"""
if old2 not in s:
    sys.exit("KD-18/20 delivery hunks not found (drifted)")
s = s.replace(old2, new2)
open(p, "w").write(s)
# SHIM-COURT: force mix to see the edit — an in-place rewrite inside the same
# mtime second is invisible to the compiler's change detection (witnessed
# 2026-10-16: without this, the AFTER probe ran the stale pristine beam and
# the shim read as inert). Same fix as etag_cas_court.sh.
os.utime(p, (time.time() + 2, time.time() + 2))
print("[SHIM] KD-19 fields + KD-18/20 delivery hunks stripped (SHIM-COURT)")
PYEOF
}

# Sibling lanes share this tree; wait out transient foreign compile breaks
# instead of failing the court on them.

run_probe() {
    # Compile retry (wait out transient sibling breaks; timeout is typed FAIL),
    # then the real-wire probe. Echoes the probe output; returns its rc.
    local i=0 out
    until out="$(mix compile 2>&1)"; do
        echo "$out" | grep -q "Compilation error" || {
            echo "[FAIL:AFTER] tree does not compile:" >&2; tail -20 <<<"$out" >&2; return 1; }
        i=$((i+1)); [ $i -lt 40 ] || {
            echo "[FAIL:AFTER] tree did not compile within 10 min — flip would be fake" >&2; return 1; }
        echo "[court] waiting out sibling compile break (poll $i)"; sleep 15
    done
    node "$PROBE" 2>&1
}

before_witness() {
    local out rc
    out="$(run_probe)"; rc=$?
    if [ $rc -ne 0 ]; then
        # Known drift on the LANDED tree (pre-KD-18 probe premise): a lone
        # wire-delivery-raw-payload-decode FAIL is expected and accepted; any
        # other failure is real. NOTE (2026-10-16 audit): this anchor accepts
        # ONLY that one named FAIL when the probe's overall rc is non-zero; if
        # the landed lib/ renames that delivery path the whitelist will fail
        # the BEFORE leg (loud) — retie the anchor then; do not widen it.
        if echo "$out" | grep -q 'FAIL.*wire-delivery-raw-payload-decode' \
           && [ "$(echo "$out" | grep -c '^FAIL')" -eq 1 ]; then
            return 0
        fi
        echo "[FAIL:BEFORE] probe failed on the LANDED tree:" >&2
        tail -20 <<<"$out" >&2
        return 1
    fi
    # The landed tree must serve the mgmt surface for real (no GAP-CLASS
    # degradation on the KD-19 legs) — otherwise the AFTER flip below would
    # have nothing to flip FROM.
    if echo "$out" | grep -Eq 'get-(event|partition)-[a-z-]*: GAP-CLASS'; then
        echo "[FAIL:BEFORE] landed tree already shows GAP-CLASS on mgmt legs:" >&2
        grep 'GAP-CLASS' <<<"$out" >&2
        return 1
    fi
    echo "[BEFORE] probe green on landed tree; mgmt legs served natively"
}

# AFTER: under the shim the KD-19 request fields are stripped, so the EH
# management READ ops can no longer route (type=nil -> 400/unsupported) —
# the probe's own GAP-CLASS gating labels the degradation on the mgmt legs.
# F2 fix (2026-10-16): the old leg was `! ( $BEFORE_CMD )` — it embedded
# COMPILE_RETRY, so a compile TIMEOUT also exited 1 and `!` read that as the
# flip. Now the flip is typed: the probe output MUST carry the KD-19
# GAP-CLASS signature; a compile failure or an inert shim is [FAIL:AFTER].
after_witness() {
    local out rc
    out="$(run_probe)"; rc=$?
    if echo "$out" | grep -Eq 'get-event-hub-properties: GAP-CLASS: MessagingError\(NotImplementedError\)'; then
        echo "[AFTER] KD-19 GAP-CLASS signature present under the shim (probe rc=$rc) — real flip"
        return 0
    fi
    if [ $rc -eq 0 ]; then
        echo "[FAIL:AFTER] probe fully green under the shim — flip absent (shim inert)" >&2
    else
        echo "[FAIL:AFTER] probe failed WITHOUT the KD-19 GAP-CLASS signature:" >&2
        tail -20 <<<"$out" >&2
    fi
    return 1
}

# Serialize per-subject: sibling lanes run this same court script from the
# one canonical checkout; two interleaved shim/restore cycles on one subject
# were witnessed 2026-10-16 as a flapping baseline sha + an "inert" shim
# (the sibling's restore wiped our shim mid-AFTER). Holding the lock fd for
# the whole with_shim makes concurrent court invocations queue.
exec 9>>"/tmp/smalt-shim-court-$(basename "$SUBJECT").lock"
flock 9
with_shim "$SUBJECT" \
                    "$(declare -f run_probe before_witness); before_witness" \
                    "$(declare -f run_probe after_witness); after_witness"
