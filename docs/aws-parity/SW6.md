# SW6 AWS plane wiring receipt

Standing: UNVERIFIED

Edited without mix/just/git (lane law). Gate for coordinator: `mix compile --warnings-as-errors`
then `mix test test/aws`. No result claimed.

## Diff

- `lib/smalt/egress_router.ex`: `plug(:aws_plane)` before `:kinesis_rest_face`/`:sqs_query_face`
  (same pre-Bearer slot, ahead of `:gcp_plane`); new `aws_plane/2` + `aws_next/2`. Chain: S3 ->
  DynamoDB(+KMS+STS) -> SNS -> SecretsManager, stop at first halt. Creds from
  `Application.get_env(:smalt, :aws_creds, %{"AKIDLOCAL" => "secretLocal"})`.
- `lib/smalt/application.ex`: `aws_children/0` appended after `gcp_children()`:
  `{Smalt.AWS.S3.Server, name: Smalt.AWS.S3.Default}`, `{Smalt.AWS.SNS, name: ...SNS.Default}`,
  `{Smalt.AWS.SecretsManager, name: ...SecretsManager.Default}` (code names; all have child_spec).
  DynamoDB/KMS/STS ride `Smalt.Store` (`:smalt_cosmos_docs`), no children.

## Collision analysis

- Gate: only `Authorization: AWS4-HMAC-SHA256`. Azure uses Bearer/SharedKey/SAS, GCP uses Bearer
  or none -> plug is a no-op, routing byte-unchanged. Each router then claims by SigV4 credential
  scope service, not by path, so GCS path shapes (`/storage/v1`) and S3 path-style cannot cross.
- SQS/Kinesis (X-Amz-Target / Action= on POST /): scopes `sqs`/`kinesis` are not claimed by any
  AWS router, pass through to the existing faces. SNS vs SQS both use `Action=`: disambiguated
  by scope service only. KMS/SecretsManager both use X-Amz-Target: disambiguated by scope.
- Not detected (gaps): X-Amz-Target or S3 host-style/presigned-query (`X-Amz-Signature`) without an
  Authorization header; unsigned requests fall to Bearer/Azure. S3 virtual-host style is not
  handled by `S3.Router` (path-style only). AWS plane precedes GCP plane; no shared path claims.
- Unverified risk: `S3.Router` reads body (64MB) before halt; harmless as only claimed convs read.

## Open point from SW1 (SF1 owns lib/smalt/gcp/*)

Needed change: `Smalt.GCP.SecretManager.start_link/0` and `Smalt.GCP.KMS.start_link/0` should
accept `opts` and register `name: __MODULE__` (Agent.start_link(fun, name: ...)), plus
`child_spec/1`; then `gcp_agent_family` can drop the :global engine spawn. Not done here.

## Result (W1-07)

Block-status: UNVERIFIED

No build or test executed by this lane. SQS SigV4 verify wired in
lib/smalt/egress/sqs/sqs_routes.ex; KD-SQ2 closed pending run. Coordinator gate: compile with
warnings-as-errors, then the test/aws suite; replace this Standing with observed output.

## Result (W3-11 parity receipt)

Block-status: UNVERIFIED

- Command: `mix test /Users/sac/smalt/test/gcp /Users/sac/smalt/test/aws` (cwd /Users/sac/smalt)
- Exit: NOT OBSERVED by this lane (session testimony only: 76 gcp+aws combined, unverified)
- AWS-only `mix test /Users/sac/smalt/test/aws` exit/count: not separately recorded. Coordinator
  runs it and replaces this line with observed exit and count; PASS only on exit 0.
- KD-AWS-01..03 and KD-SQ2 remain OPEN in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md.
