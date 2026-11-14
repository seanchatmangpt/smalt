# smalt-09 AWS and GCP Test Census Receipt

Standing: UNVERIFIED

This lane could not execute the suite (hook blocks build/test). Fields marked PENDING are filled
by the coordinator from real output; KD-GCP-05 and KD-AWS-03 stay OPEN until then.

- SHA: PENDING (`git rev-parse HEAD` in /Users/sac/smalt)
- Command: `cd /Users/sac/smalt && mix test test/gcp test/aws 2>&1 | tail -5`
- Exit code: PENDING
- Totals: PENDING (prior session observation, unrecorded: 76 passed)

## Files that must appear in the count (static `test "` line counts, not executed)

AWS (7): dynamodb 10, kms 5, s3 5, secretsmanager 4, sigv4 4, sns 4, sts 4.
GCP (11): cloud_tasks 4, firestore 10, functions 3, identity_plane 4, pubsub_engine 7,
pubsub_router 2, run_logging 5, run_logging_router 4, secrets_kms_kms 2,
secrets_kms_secret_manager 2, storage 6.

## Close step (coordinator)

After a green run: fill PENDING, set Standing PASS, flip KD-GCP-05 and KD-AWS-03 to CLOSED citing
this file, and update AS1.md and GCP_WIRE_PARITY.md Standing.
