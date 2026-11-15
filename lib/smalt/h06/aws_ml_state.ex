defmodule Smalt.H06.AwsMl.State do
  @moduledoc """
  Lazily-started Agent holding AWS ML plane state: Transcribe jobs and
  vocabularies, Rekognition liveness sessions, and the logical clock `seq`.
  Started unlinked on first use (no application.ex edit needed); `reset/0`
  restores the pristine state (vocabularies re-seeded from `Smalt.H06.Vocab`).
  """
  alias Smalt.H06.Vocab

  def init_state do
    vocabs = Map.new(Vocab.default_vocabularies(), fn n -> {n, %{"VocabularyName" => n, "LanguageCode" => "en-US", "VocabularyState" => "READY", "LastModifiedTime" => Vocab.logical_clock_base() + 0.0}} end)
    %{seq: 0, jobs: %{}, vocabs: vocabs, sessions: %{}}
  end

  defp ensure do
    case Agent.start(fn -> init_state() end, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @doc "fun :: state -> {reply, new_state}; atomic."
  def update(fun) do
    ensure()
    Agent.get_and_update(__MODULE__, fun)
  end

  def reset do
    ensure()
    Agent.update(__MODULE__, fn _ -> init_state() end)
  end
end
