# LANE-4 receipt — AoQ QUIC NIF face (v26.11.6)

Standing: PARTIAL_ALIVE

## Subject

smalt's first NIF: the AoQ QUIC transport face over the cgap-beam
`quic`-feature dylib (quinn engine, client role).

## Landed (all ALIVE unless noted)

- `lib/smalt/aoq/quic/nif.ex` — loader module `:cgap_beam` + facade
  `Smalt.Aoq.Quic.Nif`. Loud-skip stubs (named refusal log + `:error`
  atom), never boot-raise. MODULE-NAME LAW (witnessed this session):
  OTP binds a NIF only into a module whose name equals the dylib's
  `ErlNifEntry.name` (bad_lib otherwise), so the loader module is
  literally `:cgap_beam` and the Elixir facade delegates.
- `lib/smalt/aoq/quic/quic.ex` — typed wrapper
  `{:error, {:quic_refusal, reason}}` (transport.ex convention
  mirrored); open/connect/send/recv; serve/accept/stream_open typed
  UNSUPPORTED (`:server_role_not_in_nif_surface`).
- `lib/smalt/aoq/quic/certs.ex` — pure pattern-match PEM→DER, no
  `:public_key`; typed `{:cert_refusal, reason}`.
- `scripts/build_aoq_nif.sh` — cargo build `-p cgap-beam --features
  quic --release` (cgap root via `SMALT_AOQ_NIF_CGAP_ROOT` env >
  `config :smalt, :aoq, cgap_root:` > `../cgap` default), stage to
  `priv/aoq/aq_beam_nif.so` + extensionless copy. OTP `load_nif`
  appends `.so` on macOS too (witnessed: dlopen tried only
  `aq_beam_nif.so`, never `.dylib`) — staging name law.
- `scripts/gen_dev_cert.sh` — ECDSA P-256 quic leaf rider
  (`ensure_quic_leaf`, reuse path + mint path; SAN localhost/127.0.0.1,
  serverAuth; witness: minted + `openssl verify ... OK` in sandbox).
- `test/smalt/aoq/quic_certs_test.exs`, `quic_nif_test.exs` — 12 tests.
- `test/courts/aoq_quic_roundtrip_court.exs` — 4-court file.

## Gates (commands + exits, this session)

- `elixirc` standalone compile of all three lib files: OK.
- Scratch checkout (HEAD archive + lane files, sanctioned git-archive
  mechanism; shared-tree compile frozen by another lane's in-flight
  `src/smalt_lakehouse_mount.erl` unbound-var errors, 19:26-19:47+):
  `mix compile` RC=0 (path deps symlinked, ASH_GRAPHLAW_PATH default).
- `mix test test/smalt/aoq/quic_certs_test.exs test/smalt/aoq/quic_nif_test.exs
  test/courts/aoq_quic_roundtrip_court.exs` → **16 passed**, 0 failures.
- `bash scripts/aoq_egress_fence.sh` — lane file clean (nif.ex joins
  the flags.ex/tables.ex log-string class; APPEND-ONLY fence edit,
  disclosed). Fence is repo-red on OTHER lanes' untracked files
  (rdf_projector.ex, schema_bindings.ex) — not lane-4 surface.
- No `Process.sleep` in any lane file (sleep-gate compatible).

## BLOCKED-HONEST (cgap-side, disclosed not edited)

1. ROUNDTRIP court arm: staged dylib is client-role only; the L3
   server-role table entries (aq_quic_serve/accept/accept_bi/
   stream_open/stream_send/stream_recv/stream_close) exist in cgap
   source but the staged dylib predates them, and the cargo rebuild
   fails today (cgap-arrow errors, mid-flight L-lane edits). Roundtrip
   loopback, ALPN-drop mutation, wrong-CA mutation: BLOCKED on L3.
2. NIF export law gap (cgap-side fix required): cgap-beam's NIF entry
   functions are not `#[no_mangle]`-exported from the cdylib. OTP
   resolves each ErlNifFunc entry by dlsym on the entry name; with
   hidden symbols the load refuses
   (`bad_lib: Function not found cgap_beam:cgap_new/2`), even with the
   module-name law satisfied and `nif_init` exported. The real-load
   arm (real engine bind, corrupted-CA refusal flip) cannot flip until
   cgap exports the fns (or adopts rustler). Disclosed to cgap lane L3;
   smalt tree untouched on cgap (read-only lane contract held).

## Court non-vacuity status

- Loader arm: flips TODAY (stub arm asserted when dylib absent/broken,
  named-reason receipt inside every refusal; real arm asserts the
  `{:loaded, _}` receipt inside the same refusal shape).
- Certs arm: openssl chain-verify + DER extraction ALIVE; corrupted-CA
  mutation lands (sha256 differs) + fail-closed restore verified; the
  refusal-flip leg is stub-arm until cgap exports.
- Roundtrip arm: BLOCKED as cited; asserts the typed-UNSUPPORTED law
  instead of faking a pass.

## Standing

PARTIAL_ALIVE: loader/certs courts + 16/16 tests ALIVE in a HEAD-scratch
checkout; roundtrip + real-load arm BLOCKED on cgap lane L3 (server role
+ NIF export law). No fake passes.
