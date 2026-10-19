# INCIDENT → FIX → FENCE
#
# INCIDENT: duplicate Put Container on an existing container silently REPLACED
# the record (created_at/WORM clock reset, flag flip-flop) — blob lane
# cycle-25 audit; the R-repair landed the idempotent re-PUT arm
# (lib/smalt/egress_router.ex container_reput_arm, "Idempotent Put Container"
# real-Azure semantics).
#
# FIX: re-PUT with an IDENTICAL x-ms-meta-* set answers 200 with the standard
# headers; re-PUT with DIFFERENT metadata answers 409 ContainerAlreadyExists.
# The WORM/lease gates stay AHEAD of the comparison.
#
# FENCE (this corpus row): the CLOSED wire shape cannot regress.
Code.require_file("helper.exs", __DIR__)

defmodule Smalt.Corpus.BlobContainerReput do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @acct "corpus-reput"
  @container "corpus-container"

  setup do
    ensure_store()
  end

  defp put_container(meta) do
    egress(
      :put,
      "/#{@acct}/#{@container}?restype=container",
      "",
      [{"x-ms-version", "2021-12-02"} | Enum.map(meta, fn {k, v} -> {"x-ms-meta-#{k}", v} end)]
    )
  end

  @tag :corpus
  test "INCIDENT → FIX → FENCE: first PUT creates 201; identical re-PUT 200; different re-PUT 409 ContainerAlreadyExists" do
    create = put_container(%{"a" => "1"})
    assert create.status == 201, inspect(create.resp_body)

    identical = put_container(%{"a" => "1"})
    assert identical.status == 200, "idempotent re-PUT regressed: #{inspect(identical.resp_body)}"

    different = put_container(%{"a" => "2"})
    assert different.status == 409
    assert code(different) == "ContainerAlreadyExists"
  end

  @tag :corpus
  test "WORM gates stay ahead of the metadata comparison (legal-hold re-PUT is 409 ContainerLocked)" do
    create = put_container(%{"a" => "1"})
    assert create.status == 201, inspect(create.resp_body)

    hold =
      egress(
        :put,
        "/#{@acct}/#{@container}?restype=container&comp=legalhold",
        "",
        [{"x-ms-version", "2021-12-02"}, {"x-ms-legal-hold", "true"}]
      )

    assert hold.status in [200, 201],
           "legal hold did not arm: #{hold.status} #{inspect(hold.resp_body)}"

    reput = put_container(%{"a" => "1"})

    assert reput.status == 409 and code(reput) == "ContainerLocked",
           "WORM gate lost to the idempotent-rePUT arm: #{reput.status} #{inspect(reput.resp_body)}"
  end
end
