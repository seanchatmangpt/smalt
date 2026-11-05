# AOQ QUIC Transport Decision Record (LANE-03)

Status: DECIDED (phase-1 fallback now; option 2 is the phase-2 target)
Date: 2026-11-04
Lane: LANE-03 (spec) of the AOQ (smalt QUIC) program, per dispatch §3
Related: LANE-02 NIF spec (zero-copy resource binaries, scheduler pinning)

## Decision

Adopt a staged transport strategy:

- **Phase 1 (now)**: `gen_udp` + userspace framing in Elixir, with connected-socket
  iovec send via `:socket.sendmsg/2,3`. QUIC's crypto/ACK machinery is NOT
  reimplemented in phase 1; phase 1 ships datagram framing + iovec batching only.
- **Phase 2 (target)**: Rust QUIC (`quinn`) inside the LANE-02 NIF boundary — the
  Rust engine owns the QUIC state machine and TLS 1.3, and hands the BEAM
  resource-binary views of received frames (zero-copy, per LANE-02).

`quicer` (msquic NIF) is registered as a watch-list fallback, not the primary.

## Why not a full userspace QUIC in Elixir, even as stepping stone

QUIC phase-1 scope is deliberately cut: userspace QUIC requires a TLS 1.3
handshake with QUIC-specific extensions, header protection (AES/ChaCha20 per
packet), an ACK frame state machine with loss recovery, congestion control, and
connection-ID migration. Reimplementing this in pure Elixir is a dead end for a
phase-1 window: the crypto layer alone (RFC 8446 + RFC 9001 header protection)
is a multi-month court-qualifiable surface, and the pure-Erlang package `quic`
(benoitc/erlang_quic, hex `quic` 2.1.3, single maintainer, 1 open advisory) is
prior art that already exists if a pure-BEAM QUIC is ever genuinely needed —
do not rebuild it. Phase 1 instead ships only the send-path mechanics (iovec
batching) that survive into every later transport, plus wire-format framing so
cursors/parsers under test are real from day one.

## Option evaluation

Criteria: 0-copy compat with LANE-02 resource binaries; scheduler-pin
compatibility; OTP 29 + Elixir 1.20.4 asdf-pin compatibility; maintenance risk;
honest maturity.

### Option 1 — Erlang QUIC NIF (dispatch named "qebp"; real package: `quicer`)

**Existence**: the dispatch's "qebp" does not exist on hex.pm or GitHub. The
real Erlang QUIC NIF is [`quicer`](https://hex.pm/packages/quicer)
(emqx/quic, v0.4.12, updated 2026-10-06, rebar3, Apache-2.0) — an NIF binding
of Microsoft's msquic. Note a name-collision hazard: the GitHub repo is
`emqx/quic`, which is distinct from the hex package `quic` (benoitc's
pure-Erlang implementation, repo `benoitc/erlang_quic`).

- 0-copy compat: **Poor**. quicer delivers application data as ordinary BEAM
  binaries copied out of msquic buffers at the NIF boundary; it does not expose
  resource-binary views into receive buffers. Composing zero-copy with quicer
  would require a fork of the NIF layer.
- Scheduler pinning: **Weak**. msquic spawns its own internal worker/epoll
  threads, unseen by the BEAM scheduler and unpinnable via BEAM dirty schedulers.
  QUIC callbacks land on msquic threads that must trampoline into the BEAM.
- OTP 29 / Elixir 1.20.4: **Unknown/preview** — package is marked Preview;
  OTP 29 NIF ABI compatibility is unverified (no receipts); msquic itself must
  be built per-platform (Linux/macOS) under the asdf-pin.
- Maintenance risk: **Medium**. Active (EMQX-backed, 14 releases, real
  dependants) but Preview status and an external C dependency (msquic) with
  per-platform build burden.
- Honest maturity: Preview-grade; production use concentrated in EMQX's MQTT
  over QUIC work.

**Falsifier**: pin quicer 0.4.x under OTP 29 + Elixir 1.20.4 on smalt's asdf
toolchain and run a 0-copy probe: if received payloads arrive as heap binaries
copied at the NIF boundary (measurable: binary reference count / `:erlang
.binary_part` view absent) rather than resource-binary views, option 1 fails
the LANE-02 zero-copy law and is permanently disqualified.

### Option 2 — Rust QUIC (`quinn`) behind the LANE-02 NIF boundary (PHASE-2 TARGET)

The Rust NIF engine owns the QUIC connection (quinn state machine + rustls
TLS 1.3); the BEAM receives resource-binary views of decoded frames, exactly
the LANE-02 zero-copy law. This is the composition the NIF boundary was
designed for.

- 0-copy compat: **Good by construction**. The NIF owns quinn's receive
  buffers; frames can be exposed as resource binaries referencing those
  buffers (with lifetime/ownership rules per LANE-02). Send path can accept
  iovec lists of resource binaries without copy.
- Scheduler pinning: **Good by construction**. All quinn work runs on NIF
  calls we schedule on dirty CPU schedulers; a dedicated pinned poller thread
  (spawned by the NIF, non-BEAM) is ours to pin — no foreign thread pool.
  quinn is tokio-based, but the NIF can drive it via a single-threaded tokio
  current-thread runtime inside our own pinned thread rather than adopting an
  external executor's threads.
- OTP 29 / Elixir 1.20.4: **Compatible by construction** — a rustler-style
  NIF compiled against the pinned OTP 29 headers; Rust MSRV 1.80+ is
  independent of the BEAM pin.
- Maintenance risk: **Medium-low**. quinn is the most mature pure-Rust QUIC
  (86M+ crates.io downloads, production users, MSRV 1.80, tested Linux/macOS/
  Windows); pin >= 0.11.15 (CVE-2026-25800 affects < 0.11.15). Risk concentrates
  in our own NIF glue, which is code we own and court-test.
- Honest maturity: quinn itself production-grade; the NIF wrapper is new code
  (unknown until falsified), but it is the same risk class as LANE-02's
  engine already accepts.

**Falsifier**: build the LANE-02 NIF with a quinn-backed transport behind the
same boundary and run the zero-copy court on the received-frame path plus the
pinned-poller court on the send path. If either court cannot flip (frames copy
at the boundary, or the poller cannot run pinned without foreign threads),
option 2 is refused and the watch-list fallback (quicer) or phase-1 transport
becomes the standing answer.

### Option 3 — `gen_udp` + userspace QUIC in Elixir, phase-1 stepping stone

- 0-copy compat: **Partial**. `gen_udp`/`socket` receive path yields heap
  binaries (copy at recv); send path can take iovecs via `:socket.sendmsg`
  without copying on the BEAM side. Zero-copy only on send, and only via the
  `socket` module (not `gen_udp`, whose sendf/send doesn't expose sendmsg).
- Scheduler pinning: **Good**. Pure BEAM — a pinned process via
  `:erlang.process_flag(:scheduler, ...)` on a CPU scheduler works, and
  `:socket` on OTP 29 supports poll/select integration without NIFs.
- OTP 29 / Elixir 1.20.4: **Fully compatible** — `:socket` module with
  `sendmsg` exists since OTP 25; no native deps.
- Maintenance risk: **None** (stdlib + `:socket`, all ours).
- Honest maturity: the send-path mechanics are mature stdlib; the userspace
  QUIC part is NOT realistic for phase-1 — see the scope-cut above. This
  option is adopted only in its reduced form (framing + iovec send), not as a
  full QUIC implementation.

**Falsifier**: implement the reduced phase-1 send path and court it: if
`:socket.sendmsg/2` on a connected socket cannot batch a frame list into one
syscall with throughput at parity-or-better vs sequential `gen_udp.send`
measured on the same host (ratio fence, min-of-N paired rounds per the
no-sleep doctrine), the iovec claim is refuted and phase 1 falls back to
sequential sends with the same framing layer.

## Phase-1 fallback design (gen_udp + connected-socket iovec send)

Adopted for phase 1 regardless of option-2 progress, since its send mechanics
survive into option 2's NIF send path.

1. **Socket**: open with `:socket.open(domain, :dgram, :udp)`, then
   `:socket.connect/3` to fix the peer (connected UDP socket). Connected
   sockets let `sendmsg` omit the destination address and allow kernel-level
   send/recv on one 5-tuple, matching QUIC's per-connection socket model.
2. **Send path**: `:socket.sendmsg(sock, [{:erlang.io_list, frames}])` —
   build the iovec list from the frame binaries; on partial send,
   `:socket.sendmsg` returns the sent byte count; the writer loop resumes from
   the resume offset (iovec-level cursor), no fixed sleeps, bounded poll on
   socket writability via `:socket` select events.
3. **Receive path**: `:socket.recvmsg/3` on the same socket; each datagram is
   one QUIC packet in phase 1 (no demux); heap-binary copy accepted in phase 1
   and replaced by resource-binary views at the phase-2 NIF boundary.
4. **Framing**: a small Elixir framing module owns the wire format the parsers
   under test consume; the framing layer is transport-agnostic so the same
   frames feed `gen_udp`, `:socket` iovec, and the phase-2 NIF.
5. **Pinning**: the writer/reader processes run pinned
   (`:erlang.process_flag(:scheduler, n)`) on isolated CPU schedulers; no
   Process.sleep anywhere — writability via `:socket` select, bounded polls on
   observables only.
6. **Exit criteria to phase 2**: iovec send court passes (option-3 falsifier);
   framing courts pass; then LANE-02 NIF + quinn work begins and the framing
   layer survives unchanged behind the NIF boundary.

## Watch list

- `quicer` 0.4.x — re-run the option-1 falsifier on each OTP upgrade.
- `quic` (benoitc/erlang_quic) 2.1.x — pure-BEAM prior art; monitor the open
  advisory and single-maintainer risk; do not reimplement.

## Sources

- https://hex.pm/packages/quicer
- https://hex.pm/packages/quic
- https://github.com/quinn-rs/quinn
- https://docs.rs/quinn
- https://scout.docker.com/vulnerabilities/id/CVE-2026-25800
