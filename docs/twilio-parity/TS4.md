# TS4 Twilio divergence register

Standing: UNVERIFIED

Offline authoring; nothing executed. Register: `docs/twilio-parity/KD-TWILIO.md` (KD-TWILIO-01..08),
mirrored as rows in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

Read at write time: TS1.md (core/signature/router; role allowance for non-lead otypes is an
assumption) and TS2.md (lookup/verify; magic-number fixtures authored locally, to be reconciled
with TW2). Both UNVERIFIED. TS3.md not read.

Extra divergences carried from those receipts: non-lead otype role allowance unverified (TS1);
Lookup/Verify fixtures +15005550006/+15005550001/+15005550009 and code 123456 are local (TS2).

Rerun (coordinator): `tail -n 8 docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` from /Users/sac/smalt,
then ExUnit `test/twilio/` once TS1/TS2 gates are run.
