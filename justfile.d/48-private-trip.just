# 48-private-trip — COURT-PRIVATE-TRIP private-token gate (NFR-SEC-004, v26.10.22)

private-trip-root := justfile_directory()

# Fail-closed tree scan for private tokens (structural /Users/<name>/ patterns
# + env PRIVATE_TRIP_TOKENS). Exit 1 lists hits for triage — do not mass-delete.
@private-trip:
    python3 {{private-trip-root}}/scripts/private_trip.py

# Non-vacuity: planted tokens in a temp dir must be REFUSED, else exit 2.
@private-trip-self-test:
    python3 {{private-trip-root}}/scripts/private_trip.py --self-test
