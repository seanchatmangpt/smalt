# TS1 Twilio emulator parity (smalt)

Standing: UNVERIFIED

Offline authoring only; no gate run by this lane. Arcus `internal/twilio_emulator` was absent
at authoring; signature follows the Twilio spec (base64 HMAC-SHA1 of URL plus sorted key+value
params). Lookup/Verify live in TS2 (lookup.ex, verify.ex), not duplicated here.

Files: lib/smalt/twilio/{core,signature,router}.ex, test/twilio/core_test.exs.

Assumption: non-lead otype role allowance (ent all; qa principal/revops/vendor/client;
stl principal/revops/client/credit; inv principal/revops/vendor/client); lead otypes only
their own role.

Rerun (coordinator): ExUnit file test/twilio/core_test.exs from /Users/sac/smalt.
