# FIX-4 — AMQP substrate closes: KD-131 / KD-132 / KD-133

**Standing:** **ALIVE** (all three closes witnessed on live wire, post-shim).

Lane: FIX-4 (writer), repo /Users/sac/smalt, no git actions taken.

## Diffs (surgical)

1. `scripts/substrate.sh` (KD-131): default SB key now derives the per-host
   dev key EXACTLY as `scripts/dev_env.sh`
   (`base64(sha256(hostname+"smalt-dev-sb"))`, 44 bytes >= the SasVerifier
   32-byte floor). Env override `SMALT_SB_SHARED_KEY` preserved;
   `SMALT_FAIL_ON_DEFAULT_SB_KEY=1` refusal preserved.
   KD-COVERS marker at the SB_KEY line.
2. `lib/smalt/messaging/amqp/connection.ex` (KD-132):
   - handle_cbs: decoded sections normalized against the defaulted shape
     `%{application_properties: nil, body: nil, properties: %{}}` — a decode
     failure can no longer KeyError the broker connection process; the request
     falls through to the typed 400 UNSUPPORTED_CBS_REQUEST refusal.
   - find_reply_link: same normalization (Map.get/3) — the SECOND KeyError
     site on the same malformed path, found by the raw-wire witness itself.
   - KD-COVERS: KD-133 comment at handle_amqp(:flow) (witness locus).
3. No PrimitiveCodec change was needed: map32 (0xD1) already decodes per
   AMQP spec at BOTH size semantics in the current tree — the KD-132(a)
   premise predates a landed fix; witnessed, not edited.

## Wire witnesses (all post-shim)

Direct decode court (mix, in-process):
```
{:elem_count,   {:ok, %{{:symbol, "a"} => 1}, ""}}   # map32 element-count
{:pair_count,   {:ok, %{{:symbol, "a"} => 1}, ""}}   # map32 pair-count
{:map8_rhea,    {:ok, %{"a" => 1}, ""}}              # map8 (rhea emit form)
{:malformed,    {:error, :truncated}}                # 0xD1 + 0xFFFFFFFF size
{:truncated_body, {:error, :truncated}}
```

Raw-wire witness (`verification/ts/fix4-raw-wire.exs`, private block b88,
enforce mode, broker's own codec for frame encode/decode):
```
WIRE open ok
WIRE begin ok
WIRE attaches ok
WIRE spec-ordered flow sent (handle 1, credit 10)
WIRE malformed map32 app-props transfer sent
WIRE malformed-map reply statusCode=400
WIRE post-malformed valid put-token on the SAME socket: statusCode=200
FIX4-RAW WITNESS PASS
```

rhea probe `verification/ts/fix4.probe.cjs` (block b88):
```
PASS kd131.shared-key-at-or-above-32-byte-floor
PASS kd131.cbs-put-token-200-floor-valid-key
PASS kd132b.malformed-body-typed-400
PASS kd132b.connection-survives-after-malformed-body
PASS kd133.spec-ordered flow-grants-credit-2-deliveries
PASS kd133.topup-flow-delivers-third
TOTAL pass=6 fail=0   (exit 0)
```

Non-vacuity (BEFORE court): with the handle_cbs + find_reply_link
normalizations reverted, the raw-wire witness reproduced the KD-132(b) crash
class — the connection CLOSED on the malformed transfer (b88.log
"closing on :bad_frame_size" from the 9-byte-header variant; the reverted-code
run answered no reply and the socket died mid-drain; restored byte-exact,
sha256 5426e3852191865b7b681b17230362095e3d9ba527c4a04779551466abdacab0).
Honest note: an EARLIER before-court attempt using a malformed DATA body was
vacuous (a data section is not re-parsed as a map) and passed pre-fix; the
non-vacuous witness is the raw-wire MALFORMED application-properties map.

KD-131 policy pinion (close-condition second arm): substrate.sh now pins the
per-host dev_env derivation; shell-verified equality:
`substrate.sh default == dev_env.sh: YES ; len=44`.

## Court (regression)

- kd115.probe.cjs exit 0 (PASS plain-credit-first / session-credit-first /
  kd116-session-settle) — no regression to the witnessed KD-115 fix.
- kd127.probe.cjs exit 0 (2 PASS, 0 FAIL) — no regression to the witnessed
  KD-127 fix.
- SB topic leg: rhea topic publish/subscribe on b88
  (`verification/ts/fix4-topic.probe.cjs`): PASS
  topic.publish-subscribe-2-byte-exact-fifo (exit 0). NOTE: the canonical X3
  test `popcorn_demo/test/live_topic_test.exs` could NOT run in this session —
  popcorn_demo pins `elixir: "~> 1.20"` and only 1.19.5 is installed
  (pre-existing environment condition; the rhea leg stands in as the topic
  regression witness).
- Compile: `MIX_BUILD_ROOT=_build-lanefix4 mix compile` — 0 errors.

## Cross-lane disclosures

- Minimal unblock fix (compile-freeze SLA) to ANOTHER lane's in-flight
  `lib/smalt/arm_gateway/router.ex:2247`: `is_map(legacy) and sql =
  legacy["sqlExpression"]` (match not allowed inside `and`) rewritten
  semantics-identically to `is_map(legacy) and is_binary(legacy["sqlExpression"]) ->
  %{"sqlExpression" => legacy["sqlExpression"]}`. The owning lane later
  self-repaired; my hunk no longer present in the working tree.
- A second foreign break (`lib/smalt/egress/KvRoutes.ex` duplicate-if-keys)
  self-repaired by its owner while I waited out the SLA; no action taken.
- My substrate.sh diff was swept into coordinator commit 9a0b8c6 by another
  actor; content verified intact (dev_env-identical derivation + KD-COVERS).

## Blocks torn down

- b88 up during witnessing; downs sweep at close.

## KD-131 runtime locus

The key-floor policy has two halves: boot (scripts/substrate.sh, .sh not
scanned by kd_flip) and runtime admission (connection.ex ensure_cbs_router
>=32-byte guard — the lib/ KD-COVERS locus). Both witnessed by the b88 CBS
put-token 200 with a floor-valid key under :enforce.
