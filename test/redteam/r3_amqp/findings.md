# r3_amqp — Adversarial AMQP 1.0 Wire Redteam Findings

- **Subject**: live `Smalt.AmqpBroker`, MIX_ENV=test tree of 2026-10-14 ~20:05
  (the **lane-5 in-flight state** of connection.ex/frame_codec.ex — duplicate-clause
  compile warnings show lane 5 mid-convergence; statuses are as-of-that-tree).
- **Substrate**: broker booted by run.sh on shifted ports 45672/45673 with a
  keepalive watchdog (sibling lanes pkill `mix run` substrates mid-run on this
  shared checkout — cost four aborted runs before the watchdog).
- **Run receipt**: 46 attacks, 43 kill-tests (fresh TCP -> 8-byte protocol header
  <=5s after EVERY attack) — 0 kill-test failures, 0 broker process crashes.
  erl_crash.dump (mtime 19:10) predates this session and was never rewritten.
- **Machine receipt**: /tmp/r3_amqp_results.json. Re-run: test/redteam/r3_amqp/run.sh

## CRITICAL (per-connection) — R1: spec-legal attach crashes the connection process

Witnessed exception (broker log, 5x during final run, 20:12:15-20:12:27):

    20:12:15.470 [error] GenServer #PID<0.1232.0> terminating
    ** (FunctionClauseError) no function clause matching in Smalt.Amqp.FrameCodec.decode_source_target/1
        frame_codec.ex:462: decode_source_target({:symbol, "$cbs"})
        frame_codec.ex:416: decode_performative/2
        frame_codec.ex:387: decode_body/4
        connection.ex:147: next_input/1
        connection.ex:85: handle_info/2

decode_source_target/1 has no clause for a BARE SYMBOL source/target — the
canonical SDK attach form (rhea/proton and Azure SDKs encode target="cbs" as a
bare string/symbol). Any such attach kills the connection: client sees a
SILENT TCP CLOSE with NO AMQP error frame. Contained per-connection by the
conn DynamicSupervisor (broker survives; kill-tests stayed green).

Repro (full frame, header exchange first): attach with target = symbol "$cbs":

    0000003502000000005312C02810A1076362732D736E64435600404040C00D07A10424636273404040404040404040404040404040

Minimal variant: any attach whose source/target field is 0xA3 <len> "$cbs".
Mint: FrameCodec.encode_frame(:amqp, 0, {:attach, %{name: "x", handle: 0,
role: false, target: %{address: "$cbs"}}}) then swap field 6 for the raw
symbol, or replay the corpus frame attach_cbs_snd from /tmp/r3_amqp_corpus.json.

Effect: connection terminates; listener keeps accepting; broker alive.
Side effect: the ENTIRE $cbs and $management surface is unreachable from
canonical SDK encodings behind this gate (see R2).

## HIGH — R2: silent TCP close (no error frame) dominates hostile-path failures

All CBS/management attacks (S2 1MB put-token, S3 replay-after-delete,
S4 userinfo audience, S5 sr:///../../admin traversal, S6 200-burst vs cap 128,
S7 10x racing put-token, M1 10k lock-tokens, M3 non-map body, M5 junk payload)
produced ZERO statusCode replies and a silent close — a downstream casualty of
R1 (connection dies at attach, before any transfer reaches the handlers).
BLOCKED-BY-R1: re-run this suite unchanged once decode_source_target gains a
symbol clause; corpus frames are already on disk.

## MEDIUM — R3: slowloris / no short idle-timeout

F1 (truncated frame: declared 16, sent 8) held the connection open with no
error for the whole probe; connection pump recv timeout is @recv_timeout
300_000 (connection.ex). A client that declares a frame and sends half holds a
connection + socket up to 300s per stall, repeated for free; no AMQP
idle-time-out enforcement observed. Recommend a short frame-completion deadline
(~10s) plus honoring the open idle-time-out field.

## MEDIUM — R4: no channel validation (state-machine gaps, no crash)

- F10: begin on un-opened channel 7 -> broker begins back on ch 7 (accepted).
- F11: begin remote-channel=999 -> accepted, broker echoes begin.
- H1: sasl-init AFTER AMQP negotiation -> broker answers sasl-outcome on the
  AMQP layer (layer confusion tolerated, no crash).
- F12/T3: transfer on unknown/role-mismatched handle -> clean close (good).
- T4 transfer-on-detached: once closed at ~15.7s with no error frame
  (violates the 5s clean-close invariant; flaky — 1 of 3 runs).

## R5 — ingest/ack path as-of-state (lane-5 in-flight)

T1 (3 transfers, same delivery-id): 0/3 dispositions received; D1/D4/D5
receivers never received a delivery after explicit flow credit. No crash, no
close: the queue ingest/ack/deliver path produces no wire acks or deliveries
in this tree state. Consistent with lane 5's in-flight rewrite (duplicate
next_input clause warnings; broker logs show decoded source/target as
%{address: {:symbol, "address"}} — key/value mispairing in decode). MUST
re-run this suite at lane-5 convergence before claiming ALIVE.

## R6 — range-bomb falsifier did NOT fire (UNVERIFIED, code-read risk stands)

D3: disposition first=1 last=100,000,000 -> connection responsive in 32ms.
Either the range is bounded upstream or first/last never decoded to integers
(given R5's decode anomalies, the latter is likely). handle_disposition's
Enum.reduce(first..last) is still an unbounded hostile-range iterator in
code-read; recommend clamping last-first (<=10_000) before reduce. Status:
UNVERIFIED on the wire, code-read HIGH risk.

## What held (clean, no findings)

- Framing: size-field lies both directions (F2/F3), doff=0/1/255, unknown
  frame types 0x02/0x7F/0xFF, double AMQP header, garbage-after-header,
  HTTP/2 preface, 2MiB declared frame (SB + EH lanes): clean close/error
  <=1.6s every time. The 1MiB frame cap and doff sanity checks are real.
- Size gates: T6 1.016MB body -> clean close (link-message-size-exceeded);
  T2b 1.31MB partial assembly -> clean close (gate held; the historical
  uncapped link.partial concern is bounded on this tree).
- SASL: unknown mechanism -> sasl-outcome code 1 + close (S1); slow-start (H4)
  legal.
- Corpus replay C1/C2 (15 FrameCodec-minted frames, incl. out-of-order
  transfer-before-open): tolerated or clean close, no crash.
- Broker liveness: 43/43 kill tests green; POSTCHECK rss ~124MB, 0 leftover
  established conns.

## Repro hex index (full frames; host 127.0.0.1:45672 during the run)

- R1 attach-symbol-target (corpus attach_cbs_snd):
  0000003502000000005312C02810A1076362732D736E64435600404040C00D07A10424636273404040404040404040404040404040
- F1 truncated: 0000001002000000
- F2 size-lie: 0000000802000000 + 100 x AB
- F4.x doff: 0000000f <doff> 000000 + 7 x 11
- F7.x unknown types: 0000002202 <tc> 000000 ... (0x02/0x7F/0xFF in byte 5)
- H5 HTTP/2 preface: 505249202a20485454502f322e300d0a0d0a534d0d0a0d0a
- T5 2MiB declared: 0020000002000000
- D3 range bomb: 0000002f02000000005315d00000001f00000006560170000000017005f5e1005601005324d0000000040000000040
- M5 mgmt junk: deadbeefdeadbeef

## Re-run

    test/redteam/r3_amqp/run.sh    # boots broker on 45672/45673 + watchdog, runs adversary
    # machine receipt: /tmp/r3_amqp_results.json

Needs MIX_ENV=test compiled deps and 45672/45673/49443/48443 free. Sibling-lane
substrate churn is handled by the run.sh watchdog + 8-attempt kill-test retry.
