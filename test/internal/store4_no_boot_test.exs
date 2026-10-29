# BK-ST4W — store4 (Erlang partition store, src/smalt_store*.erl) disposition
# pin: typed NO-BOOT assertion.
#
# Census (docs/jira/v26.10.22/receipts/bkst4w-store4-disposition.md): the
# Erlang store4 family (smalt_store, smalt_store_sup, smalt_store_partition,
# smalt_store_heir) is compiled into every build (mix.exs erlc_paths "src")
# but is NOT in any production supervision tree — Smalt.Application boots the
# Elixir Store ensemble (lib/smalt/store.ex) as the single
# Smalt.Plane.DataSupervisor child. The only start site is the lazy
# smalt_store:start() (whereis(smalt_store_sup) guard), invoked solely by
# src/-internal consumers (smalt_proposer_gate, smalt_wormhole) which are
# themselves driven only by the test/courts/*_SUITE.erl Erlang courts.
#
# This test pins the disposition on the REAL self-booted app (Chicago: real
# collaborators, no mocks): after a full production boot, the store4
# supervisor is not registered and none of the store4 partition tables
# (smalt_store_p0..15) exist — store4 is dead/unwired in production, the
# Elixir facade is the sole production store.
#
# Context: solo (internal tier, in-process)

defmodule Internal.Store4NoBootTest do
  use ExUnit.Case, async: false

  test "store4 (Erlang partition store) does not boot in the production path" do
    # 1. no store4 supervisor registered after real app boot
    assert :erlang.whereis(:smalt_store_sup) == :undefined

    # 2. none of the 16 store4 partition tables exist (the Elixir ensemble's
    #    tables are named :smalt_<table>, e.g. :smalt_appconfig — never
    #    :smalt_store_pN; the name-collision guard in
    #    test/courts/court_store_partition_SUITE.erl covers the dual-boot case)
    live =
      for n <- 0..15,
          t = :"smalt_store_p#{n}",
          :ets.info(t) != :undefined,
          do: t

    assert live == []

    # 3. the Elixir ensemble IS up: its supervisor is registered under the
    #    name Smalt.Store and owns the real production tables
    refute :erlang.whereis(Smalt.Store) == :undefined
    assert :ets.info(:smalt_appconfig) != :undefined
  end
end
