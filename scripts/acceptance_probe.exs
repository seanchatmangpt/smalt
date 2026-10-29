# MTTW LANE 14 — substrate-side acceptance probe.
#
# The substrate's own self-check: five real-wire checks against the LIVE
# substrate (ARM control plane :9443, data plane :8443), emitting one signed
# verdict file the athena probe can chain. Chicago discipline: real HTTP
# (curl subprocess transport), real STS mint, real stores — no mocks, no
# sleeps (each curl has a hard --max-time; the only wait is the transport's
# own timeout, not a sleep), signature over canonical JSON.
#
# Usage:
#   mix run --no-start scripts/acceptance_probe.exs [out_path]
#   (default out_path: /tmp/smalt-acceptance-verdict.json)
#
#   --no-start is REQUIRED: the probe VM must NOT boot the smalt application
#   (the live substrate holds the fixed ports; a second boot would collide).
#
# KEY LAW (documented, dev-only default):
#   probe_key = HMAC-SHA256("smalt-acceptance-probe-v1", key_material)
#   key_material =
#     - env SMALT_ACCEPTANCE_PROBE_KEY when set (MUST be >= 32 bytes or the
#       probe refuses fail-closed — a short key must never silently sign),
#       else
#     - the dev default SHA-256("smalt-dev-acceptance-probe") — dev substrate
#       ONLY. Production runs MUST set SMALT_ACCEPTANCE_PROBE_KEY.
#
# VERDICT LAW:
#   payload   = canonical JSON of the verdict map (object keys sorted,
#               recursive)
#   signature = base64(HMAC-SHA256(payload, probe_key))
#   file      = {"payload": <payload string>, "signature": <sig>}
# A verifier recomputes the signature over the payload bytes; any mutation of
# the payload (results, overall standing, timestamps) refuses.

defmodule Smalt.AcceptanceProbe do
  @moduledoc """
  Substrate-side acceptance probe (MTTW LANE 14). See the file header for the
  key law and verdict law.
  """

  @probe_version 1
  @key_context "smalt-acceptance-probe-v1"
  @dev_key_material :crypto.hash(:sha256, "smalt-dev-acceptance-probe")
  @env_key "SMALT_ACCEPTANCE_PROBE_KEY"
  @default_arm "http://127.0.0.1:9443"
  @default_data "http://127.0.0.1:8443"
  @http_timeout_s 15

  defstruct [:arm_base, :data_base, :out_path, :key, :token]

  # -- entry points ------------------------------------------------------------

  @doc """
  Runs all five checks against the live planes and writes the signed verdict
  to `out_path`. Returns `{:ok, verdict_map}` or `{:error, reason}`.

  Opts:
    - `:arm_base` / `:data_base` — plane base URLs (defaults :9443/:8443)
    - `:key_material` — override of the env/dev key law (tests)
    - `:cleanup` — best-effort DELETE of the probe's cosmos db (default true)
  """
  def run(out_path, opts \\ []) do
    with :ok <- key_law_ok(opts),
         {:ok, key} <- resolve_key(opts) do
      probe = %__MODULE__{
        arm_base: Keyword.get(opts, :arm_base, @default_arm),
        data_base: Keyword.get(opts, :data_base, @default_data),
        out_path: out_path,
        key: key,
        token: mint_token(%__MODULE__{arm_base: Keyword.get(opts, :arm_base, @default_arm)})
      }

      verdict = execute(probe, opts)
      write(verdict, out_path, key)
      {:ok, verdict}
    end
  end

  defp write(verdict, out_path, key) do
    payload = canonical_json(verdict)
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, payload))

    File.mkdir_p(Path.dirname(out_path))
    File.write!(out_path, Jason.encode!(%{"payload" => payload, "signature" => sig}))
  end

  @doc """
  Reads a verdict file and verifies the signature under the SAME key law as
  `run/2`. Returns `{:ok, verdict_map}` or `{:error, reason}`:

    - `{:error, :signature_mismatch}` — payload mutated (or signed under a
      different key material)
    - `{:error, :malformed}` — not the two-field file shape
    - `{:error, :unreadable}` — file missing/unreadable
  """
  def verify(path, opts \\ []) do
    with {:ok, raw} <- read(path),
         {:ok, %{"payload" => payload, "signature" => sig}} when
              is_binary(payload) and is_binary(sig) <- Jason.decode(raw),
         {:ok, key} <- resolve_key(opts) do
      expected = Base.encode64(:crypto.mac(:hmac, :sha256, key, payload))

      if Plug.Crypto.secure_compare(sig, expected) do
        {:ok, Jason.decode!(payload)}
      else
        {:error, :signature_mismatch}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :malformed}
    end
  end

  @doc "Canonical JSON: object keys sorted, recursively. Byte-stable form the signature is computed over."
  def canonical_json(term), do: cj(term)

  defp cj(%{} = m) do
    parts =
      m
      |> Map.to_list()
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> ~s("#{k}":) <> cj(v) end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  defp cj(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &cj/1) <> "]"
  defp cj(v) when is_binary(v), do: Jason.encode!(v)
  defp cj(v), do: Jason.encode!(v)

  # -- key law -----------------------------------------------------------------

  defp key_law_ok(opts) do
    cond do
      Keyword.has_key?(opts, :key_material) -> :ok
      is_binary(System.get_env(@env_key)) ->
        if byte_size(System.get_env(@env_key)) >= 32, do: :ok, else: {:error, :probe_key_too_short}

      true -> :ok
    end
  end

  defp resolve_key(opts) do
    material =
      case Keyword.fetch(opts, :key_material) do
        {:ok, m} ->
          m

        :error ->
          case System.get_env(@env_key) do
            m when is_binary(m) and byte_size(m) >= 32 -> m
            _ -> @dev_key_material
          end
      end

    {:ok, :crypto.mac(:hmac, :sha256, @key_context, material)}
  end

  # -- verdict assembly ----------------------------------------------------------

  defp execute(probe, opts) do
    results = [
      check_health(probe),
      check_auth_law(probe),
      check_pk_fence(probe),
      check_keyvault_versions(probe),
      check_worm(probe, opts)
    ]

    %{
      "probe" => "smalt-acceptance-probe",
      "version" => @probe_version,
      "completed_at" => System.system_time(:millisecond),
      "results" => results,
      "overall" => if(Enum.all?(results, &(&1["standing"] == "ALIVE")), do: "PASS", else: "FAIL")
    }
  end

  # -- check 1: health planes -----------------------------------------------------

  # Data plane has no /.well-known face: its "health" law is the typed auth
  # refusal — a tokenless request answers 401 MissingBearerToken from the
  # substrate's own router. 401 = reachable + auth law active on the plane.
  defp check_health(probe) do
    {arm_status, arm_body} = http(:get, probe.arm_base <> "/.well-known/health/ready")
    {data_status, _} = http(:get, probe.data_base <> "/")
    ready? = arm_status == 200 and match?(%{"status" => "ready"}, safe_decode(arm_body))

    %{
      "check" => "health_planes",
      "standing" => if(ready? and data_status == 401, do: "ALIVE", else: "FAIL"),
      "arm_ready_status" => arm_status,
      "data_tokenless_status" => data_status
    }
  end

  # -- check 2: auth law -----------------------------------------------------------

  @doc false
  def check_auth_law(probe) do
    {tokenless_status, _} = http(:get, probe.arm_base <> "/subscriptions?api-version=2022-12-01")

    {mint_status, mint_body} =
      http(:post, probe.arm_base <> "/organizations/oauth2/v2.0/token",
        body:
          "grant_type=client_credentials&client_id=acceptance-probe&client_secret=acceptance-probe&scope=https://vault.azure.net/.default"
      )

    token =
      with {:ok, %{"access_token" => tok}} when is_binary(tok) and tok != "" <-
             Jason.decode(mint_body) do
        tok
      else
        _ -> nil
      end

    {authed_status, _} =
      if token,
        do: http(:get, probe.arm_base <> "/subscriptions?api-version=2022-12-01",
          auth: token),
        else: {nil, ""}

    %{
      "check" => "auth_law",
      "standing" =>
        if(tokenless_status == 401 and mint_status == 200 and authed_status == 200,
          do: "ALIVE", else: "FAIL"),
      "tokenless_status" => tokenless_status,
      "mint_status" => mint_status,
      "authed_status" => authed_status
    }
  end

  # -- check 3: pk fence (KD-S1 wire witness) --------------------------------------

  # Unique db per run (no cross-run interference). Control leg first: the
  # matching-pk read MUST be 200, so the wrong-pk 404 is attributable to the
  # fence, never to a missing doc.
  @doc false
  def check_pk_fence(probe) do
    unique = Integer.to_string(System.system_time(:millisecond))
    db = "aprobe" <> unique
    root = probe.data_base <> "/dbs"

    create_status =
      elem(
        http(:post, root,
          auth: probe.token,
          body: ~s({"id":"#{db}"}),
          headers: [{"content-type", "application/json"}]
        ),
        0
      )

    {coll_status, _} =
      http(:post, root <> "/#{db}/colls",
        auth: probe.token,
        body: ~s({"id":"c1","partitionKey":{"paths":["/pk"]}}),
        headers: [{"content-type", "application/json"}])

    {doc_status, _} =
      http(:post, root <> "/#{db}/colls/c1/docs",
        auth: probe.token,
        body: ~s({"id":"d1","pk":"a"}),
        headers: [{"content-type", "application/json"}, {"x-ms-documentdb-partitionkey", ~s(["a"])}])

    {good_status, _} =
      http(:get, root <> "/#{db}/colls/c1/docs/d1",
        auth: probe.token,
        headers: [{"x-ms-documentdb-partitionkey", ~s(["a"])}])

    {bad_status, bad_body} =
      http(:get, root <> "/#{db}/colls/c1/docs/d1",
        auth: probe.token,
        headers: [{"x-ms-documentdb-partitionkey", ~s(["b"])}])

    fenced? =
      bad_status == 404 and
        match?(%{"code" => "NotFound"}, safe_decode(bad_body))

    cleanup_db(probe, db)

    %{
      "check" => "pk_fence",
      "standing" =>
        if(create_status == 201 and coll_status == 201 and doc_status == 201 and
             good_status == 200 and fenced?, do: "ALIVE", else: "FAIL"),
      "wrong_pk_status" => bad_status,
      "control_pk_status" => good_status,
      "db_status" => create_status,
      "coll_status" => coll_status,
      "doc_status" => doc_status,
      "db" => db
    }
  end

  # -- check 4: keyvault version history (KD-S3/S4 wire witness) -------------------

  # PUT (create) 201, PUT (update face) 200, GET bare name → latest last-write
  # (the SECOND value) with a per-version GUID id.
  @doc false
  def check_keyvault_versions(probe) do
    name = "aprobe-sec-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    root = probe.data_base <> "/secrets"

    {put1, _} =
      http(:put, root <> "/#{name}?api-version=7.4",
        auth: probe.token,
        body: ~s({"value":"v1"}),
        headers: [{"content-type", "application/json"}])

    {put2, _} =
      http(:put, root <> "/#{name}?api-version=7.4",
        auth: probe.token,
        body: ~s({"value":"v2"}),
        headers: [{"content-type", "application/json"}])

    {get_status, get_body} = http(:get, root <> "/#{name}?api-version=7.4", auth: probe.token)
    decoded = safe_decode(get_body)

    latest? =
      is_map(decoded) and decoded["value"] == "v2" and
        is_binary(decoded["id"]) and String.contains?(decoded["id"], name)

    %{
      "check" => "keyvault_version_history",
      "standing" =>
        if(put1 == 201 and put2 == 200 and get_status == 200 and latest?,
          do: "ALIVE", else: "FAIL"),
      "create_status" => put1,
      "update_status" => put2,
      "latest_status" => get_status,
      "latest_is_last_write" => latest?
    }
  end

  # -- check 5: WORM opt-in (KD-135 wire witness) ------------------------------------

  # Opt-in via x-ms-immutable-policy: true on container create; blob PUT 201;
  # rewrite (PUT same blob) → 409 ContainerLocked.
  @doc false
  def check_worm(probe, opts \\ []) do
    container = "aprobe#{System.system_time(:millisecond)}"
    account = "probeacct"
    url = "#{probe.data_base}/#{account}/#{container}?restype=container"

    {mk, _} =
      http(:put, url,
        auth: probe.token,
        headers: [{"x-ms-immutable-policy", "true"}, {"x-ms-version", "2023-11-03"}])
    blob_url = "#{probe.data_base}/#{account}/#{container}/keep.txt"

    {put1, _} =
      http(:put, blob_url,
        auth: probe.token,
        body: "0123456789",
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"x-ms-version", "2023-11-03"}])

    {rewrite, rewrite_body} =
      http(:put, blob_url,
        auth: probe.token,
        body: "over",
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"x-ms-version", "2023-11-03"}])

    locked? =
      rewrite == 409 and
        case safe_decode_xml_code(rewrite_body) do
          "ContainerLocked" -> true
          _ -> false
        end

    unless opts[:cleanup] == false do
      cleanup_container(probe, container)
    end

    %{
      "check" => "worm_opt_in",
      "standing" => if(mk == 201 and put1 == 201 and locked?, do: "ALIVE", else: "FAIL"),
      "rewrite_status" => rewrite,
      "rewrite_code" => safe_decode_xml_code(rewrite_body),
      "container" => container,
      # probe containers are immutable by design; deletion is refused by the
      # WORM policy — left in place deliberately (the fence, not litter).
      "cleanup" => "left-in-place"
    }
  end

  # -- cleanup ----------------------------------------------------------------------

  @doc false
  def mint_token(probe) do
    {status, body} =
      http(:post, probe.arm_base <> "/organizations/oauth2/v2.0/token",
        body:
          "grant_type=client_credentials&client_id=acceptance-probe&client_secret=acceptance-probe&scope=https://vault.azure.net/.default")

    case Jason.decode(body) do
      {:ok, %{"access_token" => tok}} when status == 200 and is_binary(tok) -> tok
      _ -> nil
    end
  end

  defp cleanup_db(probe, db) do
    authed_cleanup(probe, probe.data_base <> "/dbs/#{db}")
  end

  defp cleanup_container(probe, container) do
    authed_cleanup(probe, "#{probe.data_base}/probeacct/#{container}?restype=container")
  end

  defp authed_cleanup(probe, url) do
    case mint_token(probe) do
      nil -> {nil, ""}
      tok -> http(:delete, url, auth: tok)
    end
  end

  # -- transport ----------------------------------------------------------------------

  @doc false
  def http(method, url, opts \\ []) do
    args = [
      "-s",
      "--max-time", Integer.to_string(@http_timeout_s),
      "-X", String.upcase(Atom.to_string(method)),
      "-w", "\n%{http_code}",
      url
    ]

    args =
      args ++
        case opts[:body] do
          nil -> []
          body -> ["--data-binary", body]
        end

    args =
      args ++
        Enum.flat_map(opts[:headers] || [], fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    args =
      if tok = opts[:auth] do
        args ++ ["-H", "Authorization: Bearer #{tok}"]
      else
        args
      end

    try do
      {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)

      case String.split(String.trim_trailing(out), "\n") do
        parts when is_list(parts) ->
          code = List.last(parts) |> String.to_integer()
          raw = parts |> Enum.drop(-1) |> Enum.join("\n")
          {code, raw}
      end
    rescue
      _ -> {nil, ""}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      _ -> {:error, :unreadable}
    end
  end

  defp safe_decode(body) do
    case Jason.decode(body) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp safe_decode_xml_code(body) do
    case Regex.run(~r/<Code>([^<]+)<\/Code>/, body) do
      [_, code] -> code
      _ -> nil
    end
  end
end

# -- script main -------------------------------------------------------------------
# Guard: the main block runs ONLY on direct execution (mix run script.exs).
# The ExUnit court compiles this same file in-process and sets
# SMALT_ACCEPTANCE_PROBE_SKIP_MAIN=1 so the main block is skipped.

if System.get_env("SMALT_ACCEPTANCE_PROBE_SKIP_MAIN") != "1" do
  out_path =
    case System.argv() do
      [path | _] -> path
      [] -> "/tmp/smalt-acceptance-verdict.json"
    end

case Smalt.AcceptanceProbe.run(out_path) do
  {:ok, verdict} ->
    IO.puts(
      Jason.encode!(%{
        overall: verdict["overall"],
        results:
          Enum.map(verdict["results"], fn r ->
            %{check: r["check"], standing: r["standing"]}
          end)
      })
    )

    if verdict["overall"] != "PASS", do: exit({:shutdown, 1})

    {:error, reason} ->
      IO.puts(:stderr, "PROBE_REFUSED: #{inspect(reason)}")
      exit({:shutdown, 1})
  end
end
