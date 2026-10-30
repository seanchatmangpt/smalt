defmodule Smalt.Mcp.Tool.Core do
  @moduledoc """
  MCP core/substrate family: `substrate.status`, `substrate.capabilities`,
  `doctor.summary`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @doc """
  Input schemas for this family. `nil` for ids outside the family.
  """
  def input_schema("substrate.status"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("substrate.capabilities"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("doctor.summary"), do: %{"type" => "object", "properties" => %{}}

  def input_schema(_other), do: nil

  @doc """
  Dispatch this family's tools. Returns the standard tool envelope
  (`{:ok, result}` | `{:refusal, code, message}`), or `nil` when the tool id
  is not in this family.
  """
  def invoke("substrate.status", _args), do: {:ok, substrate_status()}

  def invoke("substrate.capabilities", _args), do: {:ok, substrate_capabilities()}

  def invoke("doctor.summary", _args), do: {:ok, doctor_summary()}

  def invoke(_other, _args), do: nil

  # ---------------------------------------------------------------------------
  # Tool bodies
  # ---------------------------------------------------------------------------

  defp substrate_status do
    %{
      "status" => if(substrate_alive?(), do: "ok", else: "degraded"),
      "otp_app" => "smalt",
      "version" => to_string(Application.spec(:smalt, :vsn) || "0.0.0"),
      "store_alive" => Process.whereis(Smalt.Store) != nil,
      "supervisor_alive" => Process.whereis(Smalt.Supervisor) != nil,
      "mcp_read_only_surface" => true,
      "ports" => %{
        "control_plane" => Smalt.Registry.control_plane_port(),
        "data_plane" => Smalt.Registry.data_plane_port(),
        "amqp" => Smalt.Registry.amqp_port(),
        "event_hubs" => Smalt.Registry.event_hubs_port()
      }
    }
  end

  defp substrate_alive? do
    Process.whereis(Smalt.Store) != nil and Process.whereis(Smalt.Supervisor) != nil
  end

  defp substrate_capabilities do
    types = Smalt.Registry.admitted_resource_types()

    %{
      "admitted_resource_types" => types,
      "admitted_resource_type_count" => length(types),
      "api_versions" =>
        Enum.reduce(types, %{}, fn type, acc ->
          case Smalt.Registry.latest_version(type) do
            nil -> acc
            v -> Map.put(acc, type, v)
          end
        end),
      "shape_bindings" =>
        types
        |> Enum.map(fn type -> {type, Smalt.Registry.shape_for(type)} end)
        |> Enum.reject(fn {_t, s} -> is_nil(s) end)
        |> Map.new(),
      "mcp_tools" =>
        Smalt.Mcp.Descriptor.capabilities()
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.sort()
    }
  end

  defp doctor_summary do
    # Test seam (lens-4): the supervisor observed defaults to the real one; a
    # hostile-id real supervisor can be substituted to fuzz sanitize_child_id/1
    # through the public wire path. No other behavior changes.
    sup = Application.get_env(:smalt, :doctor_supervisor, Smalt.Supervisor)

    children =
      case sup do
        nil ->
          []

        sup ->
          flatten_children(sup, 0)
      end

    %{
      "status" => if(substrate_alive?(), do: "healthy", else: "degraded"),
      "supervisor_children" => children,
      "store_alive" => Process.whereis(Smalt.Store) != nil,
      "cosmos_store_ready" => Smalt.DataPlane.Cosmos.store_ready?(),
      "blob_policy_table_ready" => :ets.info(:smalt_blob_policy) != :undefined,
      "vault_keys_table_ready" => :ets.info(:smalt_vault_keys) != :undefined,
      "sb_queues_table_ready" => :ets.info(:smalt_sb_queues) != :undefined,
      "node_uptime_seconds" => elem(:erlang.statistics(:wall_clock), 1) |> div(1000)
    }
  end

  # AZB-09: the app tree is partitioned into plane supervisors (Data/Control/
  # Integration/Identity), so leaf services like Smalt.Store live one level
  # below the root. Flatten the plane subtrees (bounded depth) so the summary
  # reports every service, annotating each nested child with its plane. Only
  # :supervisor-typed children are descended into (a :worker pid is never a
  # supervisor, so the hostile-id fuzz supervisor's Task children are never
  # signalled), and the descent is exit-guarded: a dead or non-supervisor
  # subtree degrades to that plane's own row, never a crash.
  @doctor_flatten_depth 3

  defp flatten_children(sup, depth) when depth >= @doctor_flatten_depth,
    do: Enum.map(Supervisor.which_children(sup), &child_row(&1, nil))

  defp flatten_children(sup, depth) do
    Supervisor.which_children(sup)
    |> Enum.flat_map(fn {id, pid, type, _mods} ->
      row = child_row({id, pid, type, nil}, nil)

      nested =
        if type == :supervisor and is_pid(pid) and Process.alive?(pid) do
          try do
            plane = sanitize_child_id(id)
            flatten_children(pid, depth + 1) |> Enum.map(&put_plane(&1, plane))
          catch
            _class, _reason -> []
          end
        else
          []
        end

      [row | nested]
    end)
  end

  defp child_row({id, pid, _type, _mods}, plane) do
    row = %{
      "id" => sanitize_child_id(id),
      "pid" => inspect(pid),
      "alive" => is_pid(pid) and Process.alive?(pid)
    }

    if plane, do: Map.put(row, "plane", plane), else: row
  end

  defp put_plane(%{} = row, plane), do: Map.put(row, "plane", plane)

  # ids (e.g. {Bandit, #Reference<...>}) keep the module name but collapse
  # session-local reference tokens so no ephemeral internals cross the wire.
  defp sanitize_child_id(id) when is_atom(id), do: inspect(id)

  defp sanitize_child_id(id) do
    String.replace(inspect(id), ~r/#Reference<[^>]+>/, "#Reference")
  end
end
