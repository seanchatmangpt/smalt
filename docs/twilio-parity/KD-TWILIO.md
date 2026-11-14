# KD-TWILIO

Standing: UNVERIFIED

Twilio and fnox.io edge parity divergence register. Offline authored; no run observed.
Mirrored as rows in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

| id | surface | divergence | evidence | close condition | status |
|---|---|---|---|---|---|
| KD-TWILIO-01 | Lookup v2 `?Fields=sim_swap` | No real carrier or SIM data; sim_swap payloads are deterministic fixtures keyed on the number, never a carrier answer | `docs/twilio-parity/TS4.md` | accepted divergence (no carrier access exists offline) | OPEN |
| KD-TWILIO-02 | TrustHub / regulatory bundles | No TrustHub: no business profiles, bundles or vetting; endpoints answer typed UNSUPPORTED | `docs/twilio-parity/TS4.md` | accepted, or a TrustHub fixture surface lands | OPEN |
| KD-TWILIO-03 | A2P 10DLC brand/campaign registration | No 10DLC registration, throughput tiers or carrier filtering; Messages.json is accepted without campaign binding | `docs/twilio-parity/TS4.md` | accepted divergence | OPEN |
| KD-TWILIO-04 | Programmable Voice media streams | No `<Stream>` / media streams websocket; Calls.json returns a CA sid and call state only, no audio path | `docs/twilio-parity/TS4.md` | accepted, or a stream face lands | OPEN |
| KD-TWILIO-05 | sids (PN/SM/CA/VA/VE) | Deterministic sids derived from request content, not random 32-hex; same input yields same sid. Twilio sids are random | `docs/twilio-parity/TS4.md` | accepted divergence (replay law) | OPEN |
| KD-TWILIO-06 | X-Twilio-Signature | Only HMAC-SHA1 over fullURL + sorted POST params key+value is checked; JSON-body (bodySHA256) signing variant and URL port/scheme normalisation edge cases not covered. Test tokens are documented placeholders (AC + 32 hex), never real credentials | `docs/twilio-parity/TS4.md` | bodySHA256 variant court passes | OPEN |
| KD-TWILIO-07 | fnox.io route law `https://fnox.io/{role}/{otype}_{ulid}/{surface}` | Edge refusal of cross-role traversal is typed and pre-state, but DNS/TLS for fnox.io is not live (see KD-GCP-06); only the route parser is exercised offline | `docs/twilio-parity/TS4.md` | fnox.io ACTIVE and a live cross-role probe is refused | OPEN |
| KD-TWILIO-08 | all Twilio cells | All rows UNVERIFIED: authored without compile or test run; TS1/TS2 receipts not read at authoring time unless cited in TS4.md | `docs/twilio-parity/TS4.md` | coordinator runs the Twilio court green and records witnesses | OPEN |
