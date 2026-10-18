# Rewrite draft — auth / wire / egress test lanes (v26.10.18)

Scope: `test/auth_enforce_test.exs`, `test/egress_dispatch_test.exs` (incl.
`resilient_clear` consolidation), `test/kd79_blob_apiversion_wire_test.exs`,
`test/eventgrid_topics_arm_test.exs`, `test/eventgrid_conformance_test.exs`
(private `ConfWireSup` trees → `start_supervised!`), `test/mix_auth_scope_test.exs`,
`test/data_plane/blob_hardening_test.exs` (non-perf faces).

READ-ONLY draft. No file in `test/` is edited by this window; this document is
the construction plan. Every receipted pinion is carried forward — nothing below
weakens a pinned contract; restructures are harness-mechanics only.

---

## 0. Invariant inventory (pinions that MUST survive any rewrite)

Extracted from the current suites. Each row is receipted wire behavior; the
rewrite reproduces it verbatim or by reference, never "improves" it.

### 0.1 Bearer sub-codes (`Smalt.Auth.Bearer` refusal classes)

The `error.message` field of the ARM 401 envelope is the exact reason atom
string. Pinned corpus (auth_enforce + lens-4/5 tables):

| condition | message |
|---|---|
| missing / malformed / empty header | `MissingBearerToken` |
| duplicate Authorization headers (either order) | `MalformedBearerHeader` |
| bad signature / tampered / alg=none / RS256-confusion / cross-secret / foreign-key jku sig | `SignatureVerificationFailed` |
| `b64` header member or `b64:false` (RFC 7797) | `SignatureVerificationFailed` (sig-leg, earlier) |
| `crit` non-empty / non-list / unknown extension | `UnsupportedCriticalHeader` |
| present `typ` not case-insensitive `JWT` | `UnsupportedTokenHeader` |
| expired / exp <= now / float exp / string exp | `TokenExpired` |
| nbf > now / float nbf / string nbf | `TokenNotYetValid` |
| aud not a member string (incl. list-form aud, integer aud, trailing-slash aud) | `AudienceMismatch` |
| iss mismatch (incl. scheme-less iss, non-binary iss, never-minted authority, case-shifted forwarded host) | `IssuerMismatch` |

Non-refusal pins: `Bearer`/`bearer`/`BEARER`/`bEaReR` case-insensitive; 1*SP
padding between scheme and token; double-space admits; tab separator refuses;
unicode look-alike `Βearer` refuses; leading whitespace refuses; trailing junk
refuses; `Bearer Bearer abc` reaches signature verify (refuses
`SignatureVerificationFailed`, never a parse failure); iat/jti/sub/azp/oid/tid/
roles are informational (single-claim mutation accepts; iat absurd-future
accepts; far-future exp int64max and far-past nbf int64min accept); crit:[]
accepts; absent typ accepts; jku/jwk/x5u headers inert over a valid signature
(RFC 7515-correct signer pinning), refuse over a foreign signature; KD-94
`type=aad&ver=1.0&sig=<jwt>` Authorization shape verifies the sig JWT through
the same fence (wrong `type`/`ver`, missing `type`, empty sig, garbage sig,
cross-secret sig, expired sig all refuse); AAD shape admitted on both ARM and
egress/cosmos planes.

Time boundaries (lens-4 table, keep verbatim): exp==now refuse;
exp==now+1 accept; nbf==now accept; nbf==now+1 refuse; nbf==-1/0 accept;
nbf==exp → exp leg wins (`TokenExpired`).

Exempt surface (oracle = `Smalt.Auth.Bearer.auth_exempt_path?/1`, ONE predicate —
the egress router must never carry a private prefix copy):
prefixes `/oauth2/`, `/.well-known/`, `/common/discovery/`, `/attest/`;
exact `/metadata/endpoints`, `/tenant`, `/tenants`; anchored tenant STS form
`~r{^/[^/]+/oauth2/v2\.0/token$}` (case-insensitive segment; suffix `/extra`
NOT exempt; `//`-collapsed and `v2.1` forms NOT exempt). Exemption is bounded:
non-token oauth2 shapes (`/a/oauth2/junk`, `/a/oauth2/v2.0/`,
`/a/oauth2/v2.0/tokens`, `token%2f`, `OAUTH2`/`Oauth2` case variants) stay
ENFORCED 401 on both routers. Exempt-namespace blob paths (3+ segments) never
reach the blob splat: 404 `BlobNotFound` with or without a bearer; traversal
refusals precede the version guard.

Cross-seat registry: mint-time `register_trusted_authority/1` per-authority
`persistent_term` keys (concurrent-mint no-lost-update, 50-way); reset is the
restart contract (pre-restart token refused `IssuerMismatch` post-reset;
register-after-last-reset lands); cap at 1024 keys — at the cap the mint still
succeeds own-seat, cross-SEAT acceptance is exactly what is withheld
(`{:refuse, "InvalidAuthenticationTokenIssuer", "IssuerMismatch"}`); ""
(scheme-less) is never a registry key and a scheme-less iss never rides the
registry leg; bare-authority iss admits via the registry leg once that authority
minted (verify ⊋ mint, registry-gated).

Forwarded headers: honored ONLY from trusted proxies (exact IP or true-CIDR
`10.99.1.1 ∈ 10.0.0.0/8`, `10.0.200.1 ∈ 10.0.0.0/16` — not string prefix);
malformed forwarded host degrades TO DIRECT (direct-bound token accepts) —
`{host,0}`, `{host,-1}`, `{host}:`, `host/extra`, proxy-chain, IPv6 form
`[::1]:8443` all degrade; overflow port (`:999…9`) is a REAL authority (not a
degradation); colon-less garbage host (`a.test, b.test`) forms a garbage
authority; default-port omission is per-scheme (http/443 and https/80 keep
their port); byte-case of forwarded host must not broaden issuer acceptance;
uppercase `HTTPS` proto honored; malformed `x-forwarded-host` never 500s and
never breaks a direct-authority token; `trusted_proxies` garbage entries
stay fail-closed (no crash, no open).

STS mint: registered claim set {exp,iat,nbf,aud,iss,sub} + Azure set
{tid,oid,appid,azp,roles}; iat==nbf, exp-iat==3600; DEV-MODE constants
appid==azp=="00000000-…-0", oid==sub (=="00000000-…-1" in lens8 form-injection
court — keep each suite's own pinned value), roles==["Contributor","Owner"];
iss binds the MINT seat authority; tenant-scoped path echoes tid; typ JWT
pinned by production mint; `error` envelopes: missing grant_type / empty /
duplicate (either order, incl. %-encoded-dup laundering) →
`{"error":"invalid_request"}` + `Cache-Control: no-store`; case variants /
`client+credentials` / semicolon separator / trailing-space grant →
`unsupported_grant_type`; leading amp mints; substring-neighbor key
(`xgrant_type`) does not false-positive the raw dup scan;
redirect_uri/scope are inert. Form-injection immunity: oid/roles/aud/tid are
server constants; only tid is client-echoed (mint ⊆ verify property over the
adversarial tid corpus — %2F, %2e%2e, %00, multibyte, 4k, url-shaped all mint
AND re-verify 200).

BodyCache: full raw body cached after the Plug.Parsers read loop (chunked
12KB case); second/duplicate read does not truncate; JSON content-type caches
too (`pass: ["*/*"]`); read error passes through unchanged (no half-cache);
per-request isolation on pipelined STS posts; re-invoked reader after a
completed read never double-accumulates.

### 0.2 KD-15 challenge handshake (enriched WWW-Authenticate)

Tokenless `/keys` (any method) in BOTH auth modes: 401 + single
`www-authenticate` header carrying `Bearer`, `error="invalid_token"`,
`error_description="MissingBearerToken"`,
`^Bearer authorization="[^"]+/organizations"`, `resource="https?://[^"]+"`
echoing the request origin; `authorization_uri` MUST NOT appear
(@azure keyvault-common whitelist grammar). SAS bad signature → 401 with the
same enriched challenge class (`invalid_token`, `authorization=`, `resource=`).
Every bearer refusal class emits exactly ONE challenge header, printable
ASCII, no CR/LF (error_description from compile-time atoms — injection
structurally impossible). Non-`/keys` tokenless routes keep prior behavior
(`/dbs` with x-ms-version is not 401 in anonymous mode).

### 0.3 InvalidQueryParameterValue envelopes

- Blob/container `comp=list` with junk/zero/negative/`5x`/`abc` maxresults →
  400 + `x-ms-error-code: InvalidQueryParameterValue` header +
  `<Error>…<Code>InvalidQueryParameterValue</Code>…</Error>` XML envelope
  (`application/xml`), on BOTH `/acct?comp=list` and `/acct/cont?comp=list`.
- Unimplemented comp whitelist (GAP-AUD1-01): `appendblock page pagelist tags
  query tier expiry seal lease copy` → typed 400 InvalidQueryParameterValue,
  message `The comp value '<comp>' is not supported`, on PUT/GET/HEAD/DELETE
  arms; HEAD proof is the header alone; blob body unchanged / never served /
  never deleted.
- Duplicate `comp` (list-form decode, `?comp=metadata&comp=lease`) → default-
  deny 400 InvalidQueryParameterValue on blob AND container arms (A14).
- R155 W1: `?comp=lease` / `?comp=acl` on containers → 400
  InvalidQueryParameterValue naming `GAP(blob-comp-lease-absent)` in the
  message + x-ms-error-code header.
- `x-ms-error-code` also rides non-list JSON error envelopes
  (`BlobNotFound` on missing blob GET; KV errors via blob_error F5 with
  `x-ms-request-id` v4-GUID + `x-ms-version`).

### 0.4 CORS allowlist

Default: `access-control-allow-origin: *`. With `:smalt, :egress_cors_origins`
configured: listed origin echoed exactly, unlisted origin gets NO header.
(Keep both legs; restore prev env via the save-prev/on_exit pattern.)

### 0.5 Egress dispatch contracts (non-auth, receipted)

Two-layer 8MB cap: transport 413 at byte 8_000_001 citing "8,000,000" (never
the engine bound); engine 413 for 1_048_577..8_000_000 citing "1,048,576";
oversized PUT to a missing container → 404 ContainerNotFound (404 outranks
413); exact 1 MiB admitted. Truncated partial read (`{:more, small, _}` then
error) → 400 InvalidRequestBody with "truncated" in the message, NOT 413;
transport read fault/timeout → 400 InvalidRequestBody (M4 / timeout classes).
Raw blob PUT parse-exemption covers urlencoded content-type, json
content-type, 3/4/5-segment splats, slash-named blobs; parsed-PUT
(cosmos doc replace under dbs namespace) stays parsed; whitelist-extension
law re-homed on `/vltkv` (R99 reserved-namespace fence on `/keys`: blob-shaped
PUT under /keys → 404 `NotFound` "reserved namespace 'keys'"); encoded
`comp=%6De%74adata` decodes before routing; `prefix` qparam filters both list
call sites; typed engine errors at exact status (InvalidResourceName 400,
ContainerAlreadyExists 409, idempotent re-PUT identical meta 200); cosmos
continuation tokens namespace-typed (v2 list / v1 query, cross use 400
BadRequest flat envelope); C3 row-8 query bad-body = Cosmos flat BadRequest
envelope `{"code":"BadRequest","message":"The query is invalid."}`, never the
generic error map; ledger/event/sentinel batch-list admission boundaries;
RouteNotReady 503 fail-closed on missing tables/engines (cosmos, vault, ledger,
events, blob list surfaces; engine-kill court BEFORE/KILL/RESTORE over real
:gen_tcp); method-mismatch → 404 RouteNotFound naming the METHOD, blob-shaped
wrong-verbs keep the guard 400; Accept header never changes content-type or
status (fixed wire content-types); SKR: bearer MAA JWT admits, legacy header
gated on `skr_allow_legacy_header`, bogus token 403 `UnauthorizedAttestation`,
release 200/404 carry NO blob-plane headers (F5), missing api-version → 400
InvalidApiVersion (R143 S8), KQL v1-in-path absence accepted + wrong value 400
(R143 D8 hard 200); KV soft-delete cycle; lane-19 policy-validation 400s;
`resilient_clear` setup discipline (see §2.1).

### 0.6 Event Grid + KD-79 + MixAuthScope + blob-hardening (non-perf) pins

EventGrid ARM: topic/systemTopics CRUD shapes (201/200/404
ResourceNotFound), endpoint echo `http://localhost:<egress>/topics/:t/events`,
invalid inputSchema → 400 InvalidResourceShape (no partial record); EG1 gate:
declared `EventGrid` topic admits envelope (200 + EMPTY body, ordered batch),
undeclared refuses 400 InvalidCloudEvent, missing member → 400
InvalidEventGridEvent (all-or-nothing, nothing stored), readback merges CE+EG1
by seq. Conformance: single JSON object = structured mode (200 empty),
array-of-one stores, batch content-type stores full batch, missing
source/wrong specversion → 400 InvalidCloudEvent + nothing stored, missing id
gets a UUID, text/plain + application/xml → 415 UnsupportedMediaType,
non-JSON body with application/json → bare 400 EMPTY body
(Plug.Parsers.ParseError tier — divergence pinned, regression fence),
binary-mode ce-* headers construct+store+round-trip, insertion-order and
topic-scoped readback. Empty batch publish = 200-empty (conformant, C7-1b);
`{"events": []}` wrapper refused 400 InvalidCloudEvent.

KD-79/83: registry lattice top for
`Microsoft.Storage/storageAccounts/blobServices` is literal `"2023-05-01"`
(literal pin, not `latest_version/1`, so an ontology regression re-fails);
witnessed version admitted on blobServices PUT + containers PUT/GET (refuted
only if `InvalidApiVersionParameter`); future version → 400 naming
InvalidApiVersionParameter + the witnessed latest.

MixAuthScope: `with_anonymous_auth/1` sets `:anonymous` inside, restores prior
value on exit (including raise path), deletes the key when unset before;
tripwire: no raw `Application.put_env(:smalt, :auth_mode, :anonymous)` outside
the helper under `lib/mix/tasks`. Per-test save/restore of `:auth_mode` in
setup (the v26.10.17 leak fix) is retained in EVERY suite that flips auth mode.

Blob-hardening non-perf faces: If-Match/If-None-Match semantics (put/delete/
get_conditional matrices, 412/304/200, RFC 7232 precedence), WORM arms
(KD-52 snapshot/tier under hold/locked policy), policy grammar
(`period_days` [0,146000] → else 400 InvalidXmlDocument "between 0 and
146000"; lock requires If-Match `*` → 412; locked change → 409
ContainerLocked; legal-hold non-bool → 400 InvalidHeaderValue), metadata
grammar (C#-identifier names → 400 InvalidMetadata "C# identifier";
value-side printable-ASCII/`control characters` fence; lowercase-normalized
x-ms-meta-*; container create-with-metadata set-at-create/replace/hostile
400 pre-create), name grammar (control chars / oversize 1025 / zero-visible
names → 400 InvalidResourceName; 1024 boundary legal; container 3-63
lowercase grammar; duplicate create → 409 ContainerAlreadyExists record
preserved), ranged GET (206 slices incl. suffix/x-ms-range/416 `bytes */N`/
parser fuzz + edge corpus), block stage/commit/list (X-1 byte-equality,
InvalidBlockList, content-type storage), listing (delimiter BlobPrefix rollup
+ interleaving + pagination, prefix/marker compose, include=metadata exact
comma-token grammar + escaping, listed-vs-stored xmerl-parsed consistency
across all variants, triple-compose partition property, delimiter x metadata
compose, marker-tamper opacity, mid-pagination delete continuation), lane-06
container-list hardening (astral NCR `&#x1f5a8;`, XML error envelope, fast-path
Prefix echo), W-7 batch (`comp=batch` multipart 202, set-tier sub-request,
256 bound → SubRequestCountExceedsLimit) and W-7 SAS (admit without
x-ms-version, read-only `sp` → 403 AuthorizationPermissionMismatch, bad sig →
401 KD-15 challenge, expired → 403 AuthorizationFailure), F1 v4-GUID request
ids, ST6 D1 content-leak-free binary PUT. The perf-budget test
(`@perf_budget_ms 180`, 8000x2KiB pagination) is EXCLUDED from this rewrite
scope (perf face) — carried verbatim.

---

## 1. First-principles diagnosis (what is wrong with the current shape)

1. **Three hand-rolled supervision-tree harnesses.** `eventgrid_topics_arm`,
   `eventgrid_conformance`, and the egress Bandit legs each duplicate
   `get_free_port/0`, `stop_existing_tree/0`, `stop_tree/1`, `http_request/4`,
   `recv_all/1`, `parse_response/1`, and the save-prev/on_exit port-restore
   dance. Two of them name the same `Smalt.ConfWireSup` — a collision if they
   ever run concurrently in one mix test process group, and both rely on
   `Supervisor.stop` + `Process.exit(:kill)` fallbacks instead of the test
   lifecycle. Fix: `ExUnit`-owned trees via `start_supervised!` (one ForChild
   per resource; ExUnit terminates and re-raises on failure), with the shared
   helpers pulled into `SmaltTest.Wire` (§2.2).

2. **`resilient_clear` lives as a private function in `egress_dispatch_test`**
   but the not-ready race it defends against (async sibling tearing shared ETS
   down between `ensure_store_up` and `Store.clear/0`) is a checkout-wide
   hazard: kd79's `ensure_store/0` + `Store.clear()` and blob_hardening's
   `ensure_store_up` + `Store.clear()` setup are the same race with weaker
   armor. Fix: one shared `SmaltTest.Lifecycle.resilient_clear/0` (§2.1),
   used by all three setups.

3. **`auth_enforce_test.exs` has become a lens log.** Ten numbered "lens"
   cycles, each with its own helper generations (`mint/2`, `mint_sts/*`,
   `mint_at/1`, `mint_at_token/0`, `hand_signed_token/2-3`), duplicated
   trusted-proxy save/restore blocks (four styles: `after`-delete,
   `on_exit`-prev, bare put, `Process.put`), and three fuzz generations that
   overlap in coverage (cycle-1 header corpus ∩ lens-6 family B ∩ lens-8
   family A). The rewrite flattens to ONE setup discipline + ONE fuzz
   registry with per-family seeds, deleting only *redundant* probes whose
   pinned row already appears verbatim in a kept table (the pinion rows move,
   never disappear).

4. **`Process.put` used as an `after`-block** (egress SKR/CORS tests stash
   prev-env in `Process.put` then read it in `after`) — works but obscures
   the save/restore discipline and breaks if the test body raises before the
   put. Fix: the uniform `save_restore/1` macro (§2.3).

5. **kd79 setup asserts through the router for parent fixtures** (RG/SA PUTs
   in setup with `assert ... in [200,201,202]`) — a setup failure reads as a
   cryptic `assert` in setup. Keep the real-router fixture (Chicago: real
   collaborators) but route assertions through a named helper
   `put_parent!/2` whose failure message names the fixture.

6. **Duplicate `:rand.seed` + corpus constants** across suites with no single
   place that says "these are the seeds". Fix: all seeds named in ONE module
   attribute block per file (reproducibility stays per-file; no new shared
   seed module needed — seeds are receipts).

---

## 2. Shared mechanics (new file: `test/support/wire_helpers.ex`)

One new support module, zero production-code changes. All suites keep their
own assertion bodies.

```elixir
defmodule SmaltTest.Wire do
  @moduledoc """
  Shared wire-tier harness mechanics for the auth/egress/eventgrid suites.
  Assertions stay in the suites; this module owns only lifecycle + transport.
  """

  # -- §2.1 store readiness (consolidates resilient_clear) --------------------

  @clear_retries 50

  @doc """
  Ensure the shared Store is up, then clear it, riding out the async-sibling
  ETS teardown race (i21): a dead-table ArgumentError retries after 10 ms,
  re-ensuring the store each round; persistent failure raises the original
  error (loud, never swallowed). Replaces the private resilient_clear/1 in
  egress_dispatch_test.exs and the bare Store.clear() in kd79/blob setups.
  """
  def resilient_clear! do
    case do_clear(@clear_retries) do
      :ok -> :ok
      {:error, :store_unavailable} -> raise "shared Store unavailable after retry bound"
    end
  end

  defp do_clear(0), do: {:error, :store_unavailable}

  defp do_clear(retries) do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    :ok
  rescue
    # ArgumentError only: the `in [message: ...]` rescue form is not legal
    # Elixir (alias-only match) — i21 leak-batch2 narrowing preserved.
    ArgumentError ->
      Process.sleep(10)
      do_clear(retries - 1)
  end

  # -- §2.2 ExUnit-owned private tree (replaces ConfWireSup hand trees) --------

  @doc """
  Boot {Smalt.Store, Bandit(arm), Bandit(egress)} under ExUnit's own
  supervisor via start_supervised!/1 — ExUnit shuts the tree down between
  tests and links failures to the test, removing hand-written stop_tree/
  stop_existing_tree/Process.exit(:kill). Port env pins are saved/restored
  by the caller through save_restore/1 (or use boot_ports!/1 below).
  """
  def start_wire_tree(arm_port: arm, egress_port: egress) do
    start_supervised!(Smalt.Store)
    if arm, do: start_supervised!({Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: arm})
    if egress, do: start_supervised!({Bandit, plug: Smalt.EgressRouter, scheme: :http, port: egress})
    :ok
  end

  @doc "Save-prev/put/on_exit-restore for the three port env pins."
  def pin_ports!(arm \\ nil, egress \\ nil, amqp \\ nil) do
    prev = %{
      arm_port: Application.get_env(:smalt, :arm_port),
      egress_port: Application.get_env(:smalt, :egress_port),
      amqp_port: Application.get_env(:smalt, :amqp_port)
    }

    set = fn
      _, nil -> :ok
      key, val -> Application.put_env(:smalt, key, val)
    end

    set.(:arm_port, arm)
    set.(:egress_port, egress)
    set.(:amqp_port, amqp || get_free_port())

    ExUnit.Callbacks.on_exit(fn ->
      for {k, v} <- prev do
        if is_nil(v), do: Application.delete_env(:smalt, k), else: Application.put_env(:smalt, k, v)
      end
    end)

    prev
  end

  # -- §2.3 uniform env save/restore -------------------------------------------

  @doc """
  save_restore(aws: [auth_mode: :enforce, token_audiences: @aud]) —
  reads each key's current value, applies the overrides, and registers an
  on_exit that restores (or deletes when previously unset). Replaces the four
  divergent after/on_exit/Process.put styles in the current suites.
  """
  defmacro save_restore(overrides) do
    quote do
      overrides = unquote(overrides)

      prev =
        Map.new(overrides, fn {k, _} ->
          {k, Application.get_env(:smalt, k, :__unset__)}
        end)

      Enum.each(overrides, fn {k, v} -> Application.put_env(:smalt, k, v) end)

      ExUnit.Callbacks.on_exit(fn ->
        Enum.each(prev, fn
          {k, :__unset__} -> Application.delete_env(:smalt, k)
          {k, v} -> Application.put_env(:smalt, k, v)
        end)
      end)
    end
  end

  # -- §2.4 raw HTTP/1.1 over :gen_tcp (single copy) ----------------------------

  def get_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  @recv_timeout 15_000

  def http_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    header_lines =
      Enum.map_join(headers ++ [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}],
        "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    req =
      "#{method} #{path} HTTP/1.1\r\n" <> header_lines <>
        "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, req)
    raw = recv_all(sock) |> IO.iodata_to_binary()
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, @recv_timeout) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    [head, rest] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status, _] = String.split(status_line, " ", parts: 3)

    body =
      if get_header(header_lines, "transfer-encoding") == "chunked",
        do: decode_chunked(rest),
        else: rest

    %{status: String.to_integer(status), body: body, headers: header_lines}
  end

  defp get_header(lines, name) do
    case Enum.find(lines, &String.starts_with?(String.downcase(&1), name)) do
      nil -> nil
      l -> l |> String.split(": ", parts: 2) |> Enum.at(1)
    end
  end

  defp decode_chunked(bin, acc \\ [])
  defp decode_chunked("\r\n" <> rest, acc), do: decode_chunked(rest, acc)

  defp decode_chunked(bin, acc) do
    case Integer.parse(bin, 16) do
      {0, _} -> IO.iodata_to_binary(Enum.reverse(acc))
      {size, rest} ->
        <<chunk::binary-size(size), "\r\n", rest2::binary>> = rest
        decode_chunked(rest2, [chunk | acc])
      :error -> IO.iodata_to_binary(Enum.reverse(acc))
    end
  end
end
```

Note on `Store` alias: the support module references `Smalt.Store` fully
qualified (`do_clear` calls `Smalt.Store.clear()`); the snippet alias above is
cosmetic. Also required: `test/test_helper.exs` already loads
`test/support/*` — no change there.

`start_supervised!` caveats honored:
- The suites that previously NAMED their supervisor (`Smalt.ConfWireSup`) did
  so only for `stop_tree/1` bookkeeping; `start_supervised!` removes the need.
  Where a test body needs the tree's ports, they arrive via the setup assigns
  (`%{arm: arm, egress: egress}`), unchanged.
- `stop_existing_tree/0` semantics are preserved: before booting the private
  tree, the shared app tree must be stopped, and `on_exit` must
  `SmaltTest.Lifecycle.restore_app(); ensure_store_up()`. With
  `start_supervised!` this becomes: setup calls
  `SmaltTest.Lifecycle.stop_shared_tree()` (or the whereis-GenServer.stop
  fallback) BEFORE `start_wire_tree/1`, and registers the restore inside
  `on_exit` — the draft keeps the existing two-branch `stop_existing_tree`
  body as a shared `SmaltTest.Lifecycle.stop_existing_tree/0` so the
  Smalt.AmqpBroker / Smalt.Store name-list divergence between the two
  eventgrid suites (conformance stops Store+AmqpBroker; topics-arm stops only
  Store) is normalized to the superset list.

---

## 3. Per-file drafts

### 3.1 `test/auth_enforce_test.exs` — flatten to setup + tables + fuzz registry

Structure of the rewritten file (all pinned rows from §0.1 present):

```
defmodule Smalt.AuthEnforceTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import SmaltTest.Wire, only: [save_restore: 1]

  @secret / @aud / @iss                        # unchanged
  setup_all  -> SmaltTest.Lifecycle.ensure_store_up()
  setup      -> enforce-mode pin via save_restore(auth_mode: :enforce,
                sts_signing_secret: @secret)     # one style, no bare after-blocks
  # helpers: mint/2, arm_req/3, egress_req/3, put_headers/2, assert_challenge/2,
  #          decode_jwt/1, mint_sts/3, mint_sts_with_params/1,
  #          hand_signed_token/2-3, forwarded_authority_of/2, race_conn/0
  #          — all kept verbatim (they are the corpus generators).

  # sections, in order (renumbered, no "lens" generation history):
  #   A. challenge matrix + sub-code corpus        (rows of §0.1 table)
  #   B. extract_token grammar (RFC 7235)          (kept table from lens-8 family A)
  #   C. claims + time boundaries                  (lens-4 rows table, verbatim)
  #   D. JWS header fence (crit/b64/typ)           (@crit_headers + @typ_refusals)
  #   E. exempt surface + oracle pin               (matrix + auth_exempt_path? pin)
  #   F. forwarded headers / trusted proxies       (degradation + CIDR + garbage
  #                                                 authority rows, both directions)
  #   G. registry: concurrency / reset / cap / poisoning / bare-authority
  #   H. STS mint contract + form fuzz             (C6 rows + lens-8 families D)
  #   I. BodyCache                                 (chunked, dup-read, JSON, error,
  #                                                 isolation, no-double-accumulate)
  #   J. KD-94 AAD header shape
  #   K. registered-claim informationality audit   (lens-4 audit, verbatim)
  #   L. fuzz registry                             (one place, seeds named)
end
```

Concrete deletions (redundancy only — every surviving row is named):
- The cycle-7 `www-authenticate fuzz` per-class case list and the lens-8
  family-A rows table overlap 8/11 rows; the rewrite keeps ONE combined
  `@header_grammar_rows` table (superset: empty, scheme-only, `"Bearer "`,
  `"Bearer  tok"` double-space accept, tab, no-space, `Bearer Bearer tok`,
  `Basic`, `.` , `..`, `ab cd`, CRLF, leading-ws, `bEaReR` accept,
  `bearer   tok` accept, trailing junk x2) asserting the exact status list —
  the lens-8 exact-list style (stronger than per-row assert).
- The lens-6 family A byte-mutation fuzz and the lens-2 class-partitioned
  JWS-sequence fuzz both pin "malformed token never verifies, message in the
  six-class set". Keep the class-partitioned one (deterministic corpus,
  includes the alg:none form) and fold the byte-mutation operators into it as
  two additional operators (truncate-sig, no-dots) — seed
  `{20_261_015, 20_261_016, 20_261_017}` named on the merged test.
- Four trusted-proxy setup styles collapse to
  `save_restore(trusted_proxies: [{127, 0, 0, 1}])`.
- The `@tag :cross_seat` set stays tagged as-is (CI tiering is receipted).

### 3.2 `test/egress_dispatch_test.exs` — resilient_clear hoisted, sections regrouped

- Setup becomes:

```elixir
setup do
  SmaltTest.Lifecycle.ensure_store_up()
  SmaltTest.Wire.resilient_clear!()
end
```

  (the 50-retry/10ms/ArgumentError-narrowed loop moves to
  `SmaltTest.Wire.resilient_clear!/0` verbatim — including the comment that
  the `in [message: ...]` rescue form is illegal Elixir).
- `call/3` keeps the KD-15 placeholder-bearer logic and the
  x-ms-compliance-status legacy-header non-overwrite carve-out verbatim
  (both are receipted harness semantics, not accidents).
- SKR/CORS env flips switch from `Process.put(:prev_…)` to
  `save_restore(skr_allow_legacy_header: false)` /
  `save_restore(egress_cors_origins: ["https://allowed.example"])`.
- The two hand-rolled Bandit legs (8MB boundary over real adapter; wire-tier
  traversal court) and the engine-kill isolated tree move to
  `SmaltTest.Wire.start_wire_tree/1` + `http_request/4`; the
  `wire_request/parse_response/decode_chunked/get_free_port/stop_tree*`
  private helpers are deleted from this file. The engine-kill court keeps its
  `@tag :engine_kill_court`, its BEFORE/KILL/RESTORE shape, its on_exit
  module-restore + port-env restore (folded into `pin_ports!/3`), and the
  purge+delete+beam-hide rationale comment.
- The `ErrAdapter` / `TimingOutBodyAdapter` / `PartialThenErrorAdapter`
  hand-written adapters stay in-file (Chicago exception documented at each:
  real interface, simple fake, no mock) — they are per-test fault injectors,
  not shared collaborators.
- Test bodies and pinned envelopes carry over unchanged, regrouped under
  `describe` blocks keyed to §0.3/§0.5 rows: `describe "comp whitelist
  (InvalidQueryParameterValue)"`, `describe "two-layer 413 boundary"`,
  `describe "KD-15 /keys challenge"`, `describe "CORS"`,
  `describe "RouteNotReady fail-closed"`, `describe "route precedence"`,
  `describe "typed engine errors"`, `describe "R155 W1-W3"`, etc.

### 3.3 `test/eventgrid_topics_arm_test.exs` + 3.4 `test/eventgrid_conformance_test.exs` — start_supervised!

Shared rewritten setup shape (both suites):

```elixir
setup do
  arm  = SmaltTest.Wire.get_free_port()
  egress = SmaltTest.Wire.get_free_port()

  # stop the shared app tree before booting the private one (same contract
  # as the old stop_existing_tree/0, normalized to superset name list)
  SmaltTest.Lifecycle.stop_existing_tree()
  SmaltTest.Wire.pin_ports!(arm, egress)
  SmaltTest.Wire.start_wire_tree(arm_port: arm, egress_port: egress)

  ExUnit.Callbacks.on_exit(fn ->
    SmaltTest.Lifecycle.restore_app()
    SmaltTest.Lifecycle.ensure_store_up()
  end)

  {:ok, arm: arm, egress: egress}
end
```

- The private supervisor name `Smalt.ConfWireSup` disappears (it existed only
  so `stop_tree/1` could target it; `start_supervised!` is unnamed and
  ExUnit-owned). Conformance suite's unused `wait_until_gone/2` is dropped.
- `http_request/recv_all/parse_response/get_free_port/stop_tree/
  stop_existing_tree` private copies deleted; calls go through
  `SmaltTest.Wire.http_request/4`. The conformance suite keeps its 5s recv
  semantics by passing through the shared 15s default (strictly more patient;
  no assertion depends on the shorter timeout).
- topics-arm's `arm_port()/egress_port()` env-read helpers stay (the EG
  endpoint echo assertion `http://localhost:#{egress_port()}/…` reads the
  env pin, which `pin_ports!/3` set).
- All test bodies (§0.6 pins) unchanged. Both suites keep
  `use ExUnit.Case, async: false`.

### 3.5 `test/kd79_blob_apiversion_wire_test.exs` — small armor upgrade

- `ensure_store/0` + `Store.clear()` in setup →
  `SmaltTest.Wire.resilient_clear!/0` (this file is one of the siblings that
  can hit the same i21 race).
- Parent fixtures (RG + SA PUT through the real router) move to
  `put_parent!(path, payload \\ default)` whose assert message names the
  fixture ("parent SA creation failed"), so a setup failure is diagnosable;
  the router-real fixture discipline is unchanged.
- The KD-COVERS header comment, the literal `@witnessed "2023-05-01"` pin
  (deliberately NOT `Registry.latest_version/1`), the
  `invalid_api_version?/1` oracle, and all four test bodies carry over
  verbatim.

### 3.6 `test/mix_auth_scope_test.exs` — no structural change

This file is already the fix for the leak class the other suites suffer
from. The rewrite only: (a) swaps the hand-written prev/on_exit block for
`save_restore/1`-equivalent semantics inline (the file may keep its explicit
form — it IS the reference implementation of the pattern), and (b) the
tripwire glob stays `lib/mix/tasks/*.ex`. Bodies verbatim.

### 3.7 `test/data_plane/blob_hardening_test.exs` — non-perf faces only

- Setup: `SmaltTest.Lifecycle.ensure_store_up(); Store.clear()` →
  `SmaltTest.Wire.resilient_clear!()` + the three `ensure_*_table` calls +
  the two `:ets.delete_all_objects` sweeps, unchanged in order (policy table
  clear order is receipted: tables ensured BEFORE delete_all_objects).
- The wire legs (`router_call/1`) keep `EgressRouter.call(conn,
  EgressRouter.init([]))` — direct dispatch, no Bandit, by design (these are
  engine-facing fences; the wire-facing duplicates live in egress_dispatch).
- The `tc_setup` named-setup for the triple-compose describe and the
  detached-keeper-free table handling carry over verbatim.
- EXCLUDED (perf face, carried verbatim, explicitly out of rewrite scope):
  the `@perf_budget_ms 180` pagination contract with its 8000x2KiB seeding
  and its budget-derivation block comment.
- Everything in §0.6's blob-hardening inventory keeps its assertion text;
  the only mechanical change is the setup call and the deleted duplicated
  `Store` alias juggling inside `router_call/1`
  (`SmaltTest.Lifecycle.ensure_store_up()` already guaranteed by setup; the
  defensive re-ensure inside `router_call/1` is retained — it defends the
  describe-level setups that run after other suites' private trees).

---

## 4. What the rewrite does NOT touch

- Any `lib/` code. Zero production diff.
- Tags/tiering: `:cross_seat`, `:wire`, `:engine_kill_court`, `:amqp_wire`
  boundary unchanged.
- Seeds, corpus sizes, budgets, and every pinned status/code/message triple.
- The `SmaltTest.Lifecycle` module itself (its API gains
  `stop_existing_tree/0` promoted from the per-suite copies; existing
  functions unchanged).

## 5. Apply sequence (for the implementing window)

1. Land `test/support/wire_helpers.ex` + `SmaltTest.Lifecycle.stop_existing_tree/0`.
2. `egress_dispatch_test.exs`: hoist `resilient_clear`, swap env styles,
   switch wire legs to `SmaltTest.Wire`. Run file green.
3. Eventgrid pair → `start_supervised!` shape. Run both files green back to
   back with `egress_dispatch` in the same batch (the i21 race is only
   observable co-batched).
4. kd79 + blob_hardening setups → `resilient_clear!`. Run green.
5. `auth_enforce_test.exs` flatten (largest; last, isolated lane). Diff the
   pinned-row inventory against §0.1 before landing: every table row in the
   old file must appear in the new one (mechanical check: extract quoted
   strings per file, old ⊆ new ∪ moved-to-shared).
6. Full `mix test` + one shuffled-seed rerun before receipt.

## Falsifier

A rewritten suite that (a) drops any §0 pinion row, (b) passes while a
KD-15 challenge header loses a param, (c) loses a bearer sub-code to a
generic 401 message, or (d) turns a typed InvalidQueryParameterValue into a
bare 400 — fails the rewrite. `(d)` is the mutation check: revert the comp
whitelist in the harness-facing assertions only and the new suite must still
catch it because the pinned envelope assertions (header + XML body + message
text) are intact.
