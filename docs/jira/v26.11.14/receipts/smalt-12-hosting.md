# smalt-12 fnox.io hosting and arcus sdlc receipt

Standing: UNVERIFIED

- Subject: fnox.io hosting (fnox repo `infra/gcp/*`, `scripts/gcp/up.sh`), authored, not deployed.
- Registration: pending ACTIVE; no observation of ACTIVE exists. Deploy standing is UNVERIFIED
  until registration reads ACTIVE and a deployed endpoint answers.
- Observing command (executed this lane): `curl -sI -m 8 https://fnox.io | head -3`
  Output: empty (no HTTP response received).
- Observing command (executed this lane): `whois fnox.io | head -5`
  Output: IANA referral only ("refer: whois.nic.io"); registration status not observed.
- arcus sdlc failures (HCL_UNSUPPORTED, nil deref at
  /Users/sac/arcus/internal/gcp_emulator/sdlc/sdlc_test.go:153) registered as KD-ARCUS-01 and
  KD-ARCUS-02 in /Users/sac/smalt/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md; go tests not re-run
  by this lane.
- sdk_coverage.py: not run by this lane (coordinator gate). Prior receipt smalt-10-azure.md
  recorded exit 1 from unrelated cap-cell findings.
- Close condition: `curl -sI https://fnox.io` returns 200 and registration reads ACTIVE.
