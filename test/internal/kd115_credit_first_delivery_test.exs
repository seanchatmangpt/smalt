# KD-COVERS: KD-115 — credit-first receiver starvation.
#
# Chicago discipline: real AMQP wire, real socket, real broker connection
# process, real QueueStore claim. No mocks. The falsifier is the wire itself:
# a receiver link grants credit BEFORE any message exists (attach -> flow),
# a second link on the same session sends a message, and the assertion is
# that a TRANSFER arrives on the receiver link WITHOUT any further client
# flow. Pre-fix the receive starves (deliver_available/1 ran only on :flow).
#
# Provenance (lib/ read fresh):
#   - lib/smalt/messaging/amqp/connection.ex handle_amqp(:flow, ...):
#     the pre-fix only deliver_available/1 call site.
#   - lib/smalt/messaging/amqp/connection.ex ingest tail (post-fix):
#     `state = deliver_available(state)` on every successful queue enqueue.
#   - lib/smalt/messaging/amqp/frame_codec.ex encode_frame/3 + encode_message/1
#     build the client-side frames so the bytes are codec-native.
# KD-COVERS: KD-115 — credit-first receiver starvation (wire falsifier gate).
#
# Chicago discipline: the collaborator is the REAL wire. The probe
# (verification/ts/kd115.probe.cjs) boots its own private substrate
# (block b13, swept at exit), connects with rhea 3.0.5 (repo-local
# node_modules), and asserts the falsifier directly: attach + flow credit
# BEFORE any message exists, then send — a delivery must arrive with NO
# further client flow. Plain and session-filter legs. Pre-fix this starves
# (0/3 both legs); post-fix 3/3 both legs.
#
# The probe court is non-vacuous: KD115_AMQP_PORT override runs the same legs
# against a running substrate; the shim-revert run witnessed 0/3 both legs
# (2026-10-21, w13j diagnosis lane). Exit contract: 0 pass / 1 fail; missing
# node/rhea toolchain is a loud [SKIP], never a fake pass.
defmodule InternalTier.Kd115CreditFirstDeliveryTest do
  use ExUnit.Case, async: false

  @probe "verification/ts/kd115.probe.cjs"
  @tag :kd115_wire
  test "credit-first receiver receives with no reflow (KD-115 wire falsifier)" do
    repo = File.cwd!()
    probe = Path.join(repo, @probe)

    unless File.exists?(probe) do
      flunk("probe missing: " <> probe)
    end

    node = System.find_executable("node")

    if node == nil do
      IO.warn("[SKIP] kd115 wire probe: node not on PATH")
      :ok
    else
      {out, status} = System.cmd(node, [probe], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

      if status != 0 do
        flunk("kd115 wire probe failed (exit #{status}):\n" <> out)
      end

      assert out =~ "PASS plain-credit-first"
      assert out =~ "PASS session-credit-first"
      assert out =~ "PASS kd116-session-settle"
    end
  end
end
