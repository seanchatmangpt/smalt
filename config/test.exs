import Config

config :smalt, skr_allow_legacy_header: true

# GL28-2: local runs opt in to the GraphLaw admission gate. With the base
# engine_digest: nil + fail_closed: true unchanged, the enabled gate's
# fail-closed refusal is the default path exercised under `mix test`.
config :smalt, :graphlaw_ex_gate, enabled: true

# Existing test suite exercises routers without tokens: opt out of bearer
# enforcement here; enforce-mode behaviour is covered by test/auth_enforce_test.exs.
config :smalt, :auth_mode, :anonymous

# ---------------------------------------------------------------------------
# Config-level ephemeral ports (test isolation, docs/TEST_ISOLATION.md §2)
#
# `mix test` boots Smalt.Application BEFORE test_helper.exs runs, so any
# concurrent substrate/keeper holding the fixed default ports (9443/9444/8443/
# 5672/5673) aborts the whole suite fatally at app.start. This block evaluates
# at config time (only under MIX_ENV=test): each listener port defaults to a
# probed-free port (:gen_tcp.listen(0) then close — the probe-then-close bind
# race is accepted, same contract as SmaltTest.Lifecycle), so `mix test` always
# boots on free ports. Runtime `Application.put_env` still wins over config
# (chaos + wire tiers rely on that), and per-port env overrides are honoured:
#   SMALT_TEST_ARM_PORT / SMALT_TEST_ARM_TLS_PORT / SMALT_TEST_EGRESS_PORT /
#   SMALT_TEST_AMQP_PORT / SMALT_TEST_EVENT_HUBS_PORT / SMALT_TEST_MCP_PORT
# ---------------------------------------------------------------------------
free_port = fn ->
  case :gen_tcp.listen(0, [:binary, active: false]) do
    {:ok, sock} ->
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      port

    _ ->
      nil
  end
end

test_port = fn name, default ->
  with {:ok, val} <- System.fetch_env("SMALT_TEST_#{name}_PORT"),
       {int, ""} <- Integer.parse(val) do
    int
  else
    _ -> free_port.() || default
  end
end

config :smalt,
  arm_port: test_port.("ARM", 9443),
  arm_tls_port: test_port.("ARM_TLS", 9444),
  egress_port: test_port.("EGRESS", 8443),
  # P14 TLS-everywhere: additive data-plane https listener (only bound when
  # SMALT_TLS_ALL_PLANES=1 / config :smalt, :tls_all_planes, true).
  egress_tls_port: test_port.("EGRESS_TLS", 8445),
  # BK-58: WebSocket -> AMQP relay listener (data plane), ephemeral under test.
  ws_amqp_relay_port: test_port.("WS_RELAY", 5675),
  # AZ-5: Web PubSub face listener (data plane), ephemeral under test.
  web_pubsub_port: test_port.("WPS", 5676),
  # AZ-3b: Confidential Ledger REST face listener (data plane), ephemeral
  # under test; ACL journal dir per-run tmp (overridable SMALT_ACL_JOURNAL_DIR).
  confidential_ledger_port: test_port.("ACL", 8444),
  acl_journal_dir:
    System.get_env("SMALT_ACL_JOURNAL_DIR") ||
      Path.join(System.tmp_dir!(), "smalt-acl-journal-test-#{:rand.uniform(1_000_000_000)}"),
  amqp_port: test_port.("AMQP", 5672),
  event_hubs_port: test_port.("EVENT_HUBS", 5673),
  # MCP tool surface (lane I15): fixed 9545 default collided across
  # concurrent test runs — same ephemeral-probe contract as the others.
  mcp_port: test_port.("MCP", 9545),
  # AZ-1: Kafka wire face — ephemeral under test; journal dir per-run tmp
  # (overridable via SMALT_TEST_KAFKA_PORT / SMALT_KAFKA_LOG_DIR).
  kafka_port: test_port.("KAFKA", 9092),
  kafka_log_dir: System.get_env("SMALT_KAFKA_LOG_DIR") ||
                   Path.join(System.tmp_dir!(), "smalt-kafka-journal-test-#{:rand.uniform(1_000_000_000)}")
