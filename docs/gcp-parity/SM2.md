# SM2

Standing: UNVERIFIED

Only test/gcp failure in /tmp/sm_test.log (rc=2, 54/75): identity_plane_test.exs:75,
ArgumentError from :erlang.phash2(email, 1_000_000_000_000) in lib/smalt/gcp/iam.ex:37
(range max is 2^32). Fixed to 4_294_967_296. Not re-run (coordinator gates).
20 other failures are test/aws, out of lane.
