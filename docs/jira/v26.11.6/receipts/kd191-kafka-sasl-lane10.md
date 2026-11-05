# KD-191 — Kafka SASL face (lane 10, v26.11.6 wave)

Standing: PARTIAL_ALIVE — the whole KD-191 surface (wire rows, conn phase gate, sasl kernel, probes, court, shim court) executed green this session; `mix test test/internal/kafka_sasl_court_test.exs` = 16/16, shim court PASS with byte-exact restore. kafka_wire_test (not my lane's surface) is red from a different lane's in-flight produce-face edits — bisect-disclosed below.

## Subject

`/Users/sac/smalt` (canonical checkout, no commits — coordinator owns git).

## Owned diff (lane 10)

- `lib/smalt/messaging/kafka/sasl.ex` — NEW pure module: mechanisms/0
  (Application.get_env(:smalt, :kafka, [])[:sasl_mechanisms], default
  [:plain]), required?/0 (:sasl_required), wire_name/1, parse_plain/1
  (i32-prefixed RFC-4616, {:error, :malformed_plain} on shape violation),
  authenticate/2 (:plain non-blank STS-dev posture; :anonymous gated on
  configured AND auth_mode != :enforce; typed refusals). Config read site
  lives here by law; config.ex untouched (GENERATED).
- `lib/smalt/messaging/kafka/wire.ex` — additive: api_keys sasl_handshake 17
  / sasl_authenticate 36; matrix 17=>{0,0} 36=>{0,1}; error codes 33/34/58;
  moduledoc falsifier prose (unadvertised mechanism -> 33 + kill).
- `lib/smalt/messaging/kafka/conn.ex` — additive on L1's landed group
  family: init phase `:await_sasl|:open` (default-off = :open, byte-green);
  phase gate (await_sasl admits only 17/36/18; others killed typed
  {:sasl_required, key}); route 17 (advertised -> {0, mechs} stays; else
  {33, mechs} + kill); route 36 v0/v1 (success -> 0 + phase :open; refused
  -> 58 + message + kill; malformed -> crash-only kill; post-auth 17/36 ->
  34 + kill); vendored kafka-python-ng raw-PLAIN continuation
  (exactly-three-nul-field shape gate, raw Int32(0) reply); compact
  (KIP-482) helpers for SaslAuthenticate v1. dispatch restructured to
  dispatch/2 -> dispatch_plain_token / dispatch_framed.
- `scripts/az1/kafka_sasl_probe.py` — NEW positive probe (kafka-python-ng
  SASL_PLAINTEXT producer roundtrip, NEGOTIATED-SASL marker). The vendored
  kafka-python-ng never sends SaslAuthenticate: after SaslHandshake v0 it
  sends the raw RFC-4616 token (Int32 len + token, expects raw Int32(0))
  — the face serves that dialect via the exactly-3-field shape gate.
- `scripts/az1/kafka_sasl_negative_probe.py` — NEW raw-TCP refusal corpus
  (GSSAPI -> 33+close; blank creds -> 58+close; produce-before-auth ->
  kill; ANONYMOUS-under-enforce -> 58+close). All legs PASS.
- `test/internal/kafka_sasl_court_test.exs` — NEW court: pure-module
  courts, default-off regression, handshake/auth/phase-flip,
  33/58/34/kill legs, ANONYMOUS enforce/anonymous legs, negative-probe
  corpus, vendored probe leg. **16/16 green.**
- `scripts/shim_court/kafka_sasl_court.sh` — NEW layer-3 shim court: BASELINE -> BEFORE (suite green, excluding the
  :vendored_probe tag ONLY as an exclusion no-op now that the leg is green)
  -- excluded leg note stale: the leg is GREEN and runs in the plain mix
  test population; the shim court's COURT_CMD still excludes the
  :vendored_probe tag (harmless: the tag only marks the leg; the exclusion
  no longer hides a failure). COURT_CMD = `mix test <court> --exclude
  vendored_probe`, SHIM mutates parse_plain's two refusal arms -> AFTER
  (suite RED = flip is the proof) -> RESTORE sha256 byte-exact. PASS.

## Commands / exits (this session, ALIVE)

- `mix compile` (MIX_BUILD_ROOT=_build-lane10, asdf 1.20.4-otp-29): 0 errors.
- `mix test test/internal/kafka_sasl_court_test.exs` -> **16 passed**.
- `bash scripts/shim_court/kafka_sasl_court.sh` -> PASS, restore sha256
  byte-exact (sasl.ex b5eca637...29bc verified post-restore).
- `mix test test/internal/kafka_wire_test.exs` -> 6/9 — **pre-existing /
  other-lane in-flight**: bisect (my SASL matrix rows removed -> same
  failures) proves the KD-191 rows are not the cause; the produce-face
  (records.ex / KD-174) was red mid-wave from another lane's in-flight
  edits and is being landed by that lane. Default-off posture proven
  byte-identical by the same bisect.
- python syntax check on both probes: `python3 -m py_compile` clean.

## Coordination disclosures

- L1 (KD-190 group family) landed mid-session into conn.ex/wire.ex; my
  edits are additive clauses in different regions; no unblock needed.
- KD-174 lane's produce-face fix (records.ex bare magic-2 batch support)
  landed mid-session and UNBLOCKED my vendored-probe leg (15/16 -> 16/16).
- My parse_auth now returns the length-prefixed bytes field so
  Sasl.parse_plain/1 receives the exact RFC-4616 shape (the dispatch
  contract's "i32-length-prefixed" reading).
- The shim court uses MIX_BUILD_ROOT=_build-shim-kafka-sasl (fixed-name
  lane lease; coordinator `just lane-clean` reclaims at integration).
- KD-191 ids referenced in KD-COVERS comments; the register row itself is
  NOT minted (docs/jira/v26.11.6 has no KNOWN_DIVERGENCES.md yet — first
  minted wins at integration).

## Falsifiers

- Unadvertised mechanism -> 33 + kill (named falsifier; witnessed raw-TCP
  and in-court).
- produce-before-auth -> typed kill {:sasl_required, key}, never served
  (witnessed).
- Shim court: parse_plain admitting malformed tokens flips the suite RED;
  restore byte-exact. PASS = non-vacuous.
