defmodule Smalt.Config do
  @moduledoc """
  Application-env configuration accessors (W1a projection).

  Auto-projected from smalt-substrate-pack ontology.ttl (smalt:ConfigKey
  census, 46 keys / 88 call sites) via queries/config_keys.rq through
  templates/config.ex.eex. DO NOT HAND-EDIT; regenerate with `mix smalt.gen`.
  Replay identity is fenced by test/config_replay_identity_test.exs.

  Each accessor mirrors its call sites override semantics exactly
  (ontology smalt:override class); the ontology default is the ONLY copy
  of the in-code default going forward. Secret keys are read raw; call
  sites keep their existing case/wrap form.
  """

  @doc "ConfigKey census rows (name/type/default/secret/surface/envVarName)."
  def census do
    [
      %{
        name: :affidavit_wasm_path,
        type: "path",
        default: "priv/wasm/affidavit_wasm.wasm",
        secret: false,
        surface: "affidavit",
        env_var: nil,
        override: "none"
      },
      %{
        name: :affidavit_wasm_pin_path,
        type: "path",
        default: "priv/wasm/affidavit.sha256",
        secret: false,
        surface: "affidavit",
        env_var: nil,
        override: "none"
      },
      %{
        name: :amqp_port,
        type: "integer",
        default: 5672,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :amqp_sweeper_lock_grace_ms,
        type: "integer",
        default: 30_000,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :amqp_sweeper_tick_ms,
        type: "integer",
        default: 250,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :arm_cors_origins,
        type: "list",
        default: ["*"],
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :arm_port,
        type: "integer",
        default: 9443,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :arm_rate_limit,
        type: "atom",
        default: :infinity,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :arm_tls_port,
        type: "integer",
        default: 9444,
        secret: false,
        surface: "tls",
        env_var: nil,
        override: "none"
      },
      %{
        name: :auth_mode,
        type: "atom",
        default: :enforce,
        secret: false,
        surface: "auth",
        env_var: nil,
        override: "none"
      },
      %{
        name: :bind_ip,
        type: "string",
        default: "nil",
        secret: false,
        surface: "control_plane",
        env_var: "SMALT_BIND_IP",
        override: "env-first"
      },
      %{
        name: :blob_account_key,
        type: "string",
        default: "nil",
        secret: true,
        surface: "data_plane",
        env_var: "SMALT_BLOB_ACCOUNT_KEY",
        override: "app-env-first"
      },
      %{
        name: :blob_catch_all_hosts,
        type: "list",
        default: [],
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :cosmos_master_key,
        type: "string",
        default: "nil",
        secret: true,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :cosmos_ru_limit,
        type: "atom",
        default: :infinity,
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :doctor_supervisor,
        type: "module",
        default: Smalt.Supervisor,
        secret: false,
        surface: "mcp",
        env_var: nil,
        override: "none"
      },
      %{
        name: :egress_cors_origins,
        type: "list",
        default: ["*"],
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :egress_port,
        type: "integer",
        default: 8443,
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :event_hubs_port,
        type: "integer",
        default: 5673,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :event_stream_dedup_ids,
        type: "boolean",
        default: false,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :eventgrid_response_mode,
        type: "string",
        default: "real",
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :ex4pm_dir,
        type: "path",
        default: "Path.expand(../ex4pm/ex4pm, File.cwd!())",
        secret: false,
        surface: "ocel",
        env_var: nil,
        override: "none"
      },
      %{
        name: :graphlaw_engine,
        type: "atom",
        default: nil,
        secret: false,
        surface: "graphlaw",
        env_var: nil,
        override: "none"
      },
      %{
        name: :kv_master_secret,
        type: "string",
        default: "nil",
        secret: true,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :ledger_enforce_existence,
        type: "boolean",
        default: false,
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :lro_delay_ms,
        type: "integer",
        default: 0,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :lro_retention_ms,
        type: "atom",
        default: :infinity,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :lro_sweep_interval_ms,
        type: "integer",
        default: 30_000,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :maa_measurement_baseline,
        type: "string",
        default: "nil",
        secret: false,
        surface: "security",
        env_var: nil,
        override: "none"
      },
      %{
        name: :mcp_port,
        type: "integer",
        default: 9545,
        secret: false,
        surface: "mcp",
        env_var: nil,
        override: "none"
      },
      %{
        name: :ocel_dir,
        type: "path",
        default: "Path.join(\"tmp\", \"ocel\")",
        secret: false,
        surface: "ocel",
        env_var: nil,
        override: "none"
      },
      %{
        name: :primitive_codec,
        type: "module",
        default: Smalt.Amqp.PrimitiveCodec,
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :prod,
        type: "boolean",
        default: false,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :receipt_signing_key,
        type: "string",
        default: "nil",
        secret: true,
        surface: "security",
        env_var: nil,
        override: "none"
      },
      %{
        name: :rg_token_preserve_options,
        type: "boolean",
        default: false,
        secret: false,
        surface: "control_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :sb_endpoint,
        type: "string",
        default: "sb://127.0.0.1:5672",
        secret: false,
        surface: "messaging",
        env_var: nil,
        override: "none"
      },
      %{
        name: :sb_shared_key,
        type: "string",
        default: "nil",
        secret: true,
        surface: "messaging",
        env_var: "SMALT_SB_SHARED_KEY",
        override: "none"
      },
      %{
        name: :sentinel_dcr_strict,
        type: "boolean",
        default: false,
        secret: false,
        surface: "observability",
        env_var: nil,
        override: "none"
      },
      %{
        name: :sentinel_forensic,
        type: "boolean",
        default: false,
        secret: false,
        surface: "observability",
        env_var: nil,
        override: "none"
      },
      %{
        name: :skr_allow_legacy_header,
        type: "boolean",
        default: false,
        secret: false,
        surface: "data_plane",
        env_var: nil,
        override: "none"
      },
      %{
        name: :sts_authority_url,
        type: "string",
        default: "nil",
        secret: false,
        surface: "auth",
        env_var: nil,
        override: "none"
      },
      %{
        name: :sts_signing_secret,
        type: "string",
        default: "nil",
        secret: true,
        surface: "auth",
        env_var: nil,
        override: "none"
      },
      %{
        name: :tls,
        type: "atom",
        default: :auto,
        secret: false,
        surface: "tls",
        env_var: nil,
        override: "none"
      },
      %{
        name: :tls_certfile,
        type: "path",
        default: "nil",
        secret: false,
        surface: "tls",
        env_var: "SMALT_TLS_CERTFILE",
        override: "none"
      },
      %{
        name: :tls_keyfile,
        type: "path",
        default: "nil",
        secret: false,
        surface: "tls",
        env_var: "SMALT_TLS_KEYFILE",
        override: "none"
      },
      %{
        name: :token_audiences,
        type: "list",
        default: ["https://management.azure.com"],
        secret: false,
        surface: "auth",
        env_var: nil,
        override: "none"
      },
      %{
        name: :trusted_proxies,
        type: "list",
        default: [],
        secret: false,
        surface: "auth",
        env_var: nil,
        override: "none"
      }
    ]
  end

  @doc "Affidavit WASM module path served to enclave doctors."
  def affidavit_wasm_path,
    do: Application.get_env(:smalt, :affidavit_wasm_path, "priv/wasm/affidavit_wasm.wasm")

  @doc "sha256 pin file for the affidavit WASM module."
  def affidavit_wasm_pin_path,
    do: Application.get_env(:smalt, :affidavit_wasm_pin_path, "priv/wasm/affidavit.sha256")

  @doc "AMQP Service Bus listener port (mode :sb)."
  def amqp_port, do: Application.get_env(:smalt, :amqp_port, 5672)
  @doc "Grace window before a lock tombstone is dropped by the AMQP sweeper."
  def amqp_sweeper_lock_grace_ms,
    do: Application.get_env(:smalt, :amqp_sweeper_lock_grace_ms, 30_000)

  @doc "AMQP sweeper tick period in milliseconds."
  def amqp_sweeper_tick_ms, do: Application.get_env(:smalt, :amqp_sweeper_tick_ms, 250)
  @doc "CORS allow-list for the ARM control-plane (9443/9444) responses."
  def arm_cors_origins, do: Application.get_env(:smalt, :arm_cors_origins, ["*"])
  @doc "ARM-style control plane REST port."
  def arm_port, do: Application.get_env(:smalt, :arm_port, 9443)
  @doc "ARM gateway rate limit (:infinity disables the limiter)."
  def arm_rate_limit, do: Application.get_env(:smalt, :arm_rate_limit, :infinity)
  @doc "TLS twin port for SDK legs that refuse Bearer over http."
  def arm_tls_port, do: Application.get_env(:smalt, :arm_tls_port, 9444)
  @doc "Bearer auth mode: :enforce default, :anonymous test only."
  def auth_mode, do: Application.get_env(:smalt, :auth_mode, :enforce)
  @doc "Listener bind IP; SMALT_BIND_IP overrides the app env."
  def bind_ip, do: System.get_env("SMALT_BIND_IP") || Application.get_env(:smalt, :bind_ip)
  @doc "Blob SAS verification key; app env wins over SMALT_BLOB_ACCOUNT_KEY."
  def blob_account_key,
    do: Application.get_env(:smalt, :blob_account_key) || System.get_env("SMALT_BLOB_ACCOUNT_KEY")

  @doc "Extra hosts routed to the blob catch-all egress rule."
  def blob_catch_all_hosts, do: Application.get_env(:smalt, :blob_catch_all_hosts, [])
  @doc "Cosmos emulator master key for enforce-mode authorization."
  def cosmos_master_key, do: Application.get_env(:smalt, :cosmos_master_key)
  @doc "Cosmos request-unit budget per query (:infinity disables budgeting)."
  def cosmos_ru_limit, do: Application.get_env(:smalt, :cosmos_ru_limit, :infinity)
  @doc "Supervisor module the MCP doctor surface boots into."
  def doctor_supervisor, do: Application.get_env(:smalt, :doctor_supervisor, Smalt.Supervisor)
  @doc "CORS allow-list for egress router responses."
  def egress_cors_origins, do: Application.get_env(:smalt, :egress_cors_origins, ["*"])
  @doc "Data plane router port."
  def egress_port, do: Application.get_env(:smalt, :egress_port, 8443)
  @doc "Event Hubs listener port (mode :eh)."
  def event_hubs_port, do: Application.get_env(:smalt, :event_hubs_port, 5673)
  @doc "Emit dedup-id metadata on event stream rows."
  def event_stream_dedup_ids, do: Application.get_env(:smalt, :event_stream_dedup_ids, false)
  @doc "Event Grid subscription response mode (real vs synthetic)."
  def eventgrid_response_mode, do: Application.get_env(:smalt, :eventgrid_response_mode, "real")
  @doc "ex4pm reverse bridge project dir."
  def ex4pm_dir,
    do: Application.get_env(:smalt, :ex4pm_dir, "Path.expand(../ex4pm/ex4pm, File.cwd!())")

  @doc "WASM fast-path selector; :ash_graphlaw enables the ash_graphlaw validator."
  def graphlaw_engine, do: Application.get_env(:smalt, :graphlaw_engine)
  @doc "KeyVault emulator master secret."
  def kv_master_secret, do: Application.get_env(:smalt, :kv_master_secret)
  @doc "Refuse ledger appends referencing nonexistent ledger rows."
  def ledger_enforce_existence, do: Application.get_env(:smalt, :ledger_enforce_existence, false)
  @doc "Artificial completion delay injected into LRO operations."
  def lro_delay_ms, do: Application.get_env(:smalt, :lro_delay_ms, 0)
  @doc "LRO operation retention window; :infinity keeps operations forever."
  def lro_retention_ms, do: Application.get_env(:smalt, :lro_retention_ms, :infinity)
  @doc "LRO sweeper tick period in milliseconds."
  def lro_sweep_interval_ms, do: Application.get_env(:smalt, :lro_sweep_interval_ms, 30_000)
  @doc "Expected MAA measurement baseline (hex) for attestation admission."
  def maa_measurement_baseline, do: Application.get_env(:smalt, :maa_measurement_baseline)
  @doc "MCP tool surface port."
  def mcp_port, do: Application.get_env(:smalt, :mcp_port, 9545)
  @doc "OCEL NDJSON telemetry directory."
  def ocel_dir, do: Application.get_env(:smalt, :ocel_dir, "Path.join(\"tmp\", \"ocel\")")
  @doc "AMQP primitive codec module dispatched by the frame codec."
  def primitive_codec,
    do: Application.get_env(:smalt, :primitive_codec, Smalt.Amqp.PrimitiveCodec)

  @doc "Prod guard: refuse unconfigured :sts_signing_secret at boot."
  def prod, do: Application.get_env(:smalt, :prod, false)
  @doc "PEM RSA key material for court receipt signing."
  def receipt_signing_key, do: Application.get_env(:smalt, :receipt_signing_key)
  @doc "Preserve unknown expand options in resource-group tokens."
  def rg_token_preserve_options,
    do: Application.get_env(:smalt, :rg_token_preserve_options, false)

  @doc "Service Bus endpoint scheme://host:port used by SAS verification."
  def sb_endpoint, do: Application.get_env(:smalt, :sb_endpoint, "sb://127.0.0.1:5672")
  @doc "Broker SAS shared key; SMALT_SB_SHARED_KEY pins it via the CBS router."
  def sb_shared_key, do: Application.get_env(:smalt, :sb_shared_key)
  @doc "Refuse sentinel rows whose DCR stream is not declared."
  def sentinel_dcr_strict, do: Application.get_env(:smalt, :sentinel_dcr_strict, false)
  @doc "Mirror every sentinel row seq to forensic evidence lines."
  def sentinel_forensic, do: Application.get_env(:smalt, :sentinel_forensic, false)
  @doc "Accept the legacy SKR release header variant."
  def skr_allow_legacy_header, do: Application.get_env(:smalt, :skr_allow_legacy_header, false)
  @doc "Explicit STS authority URL overriding the loopback organizations default."
  def sts_authority_url, do: Application.get_env(:smalt, :sts_authority_url)
  @doc "HS256 STS signing secret; mandatory when :prod is set."
  def sts_signing_secret, do: Application.get_env(:smalt, :sts_signing_secret)
  @doc "TLS mode: :auto derives from certs presence; :on or :off force it."
  def tls, do: Application.get_env(:smalt, :tls, :auto)
  @doc "TLS leaf certificate PEM path; env read stays call-site residue."
  def tls_certfile, do: Application.get_env(:smalt, :tls_certfile)
  @doc "TLS private key PEM path."
  def tls_keyfile, do: Application.get_env(:smalt, :tls_keyfile)
  @doc "Accepted aud claims for Bearer tokens."
  def token_audiences,
    do: Application.get_env(:smalt, :token_audiences, ["https://management.azure.com"])

  @doc "Exact proxy IPs trusted for x-forwarded-for extraction."
  def trusted_proxies, do: Application.get_env(:smalt, :trusted_proxies, [])
end
