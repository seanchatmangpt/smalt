defmodule Smalt.Amqp.SbAuthRules do
  @moduledoc """
  Service Bus queue-level authorization rules with SAS keys (real Azure
  parity: /queues/{q}/authorizationRules).

  A rule binds {queue, rule_name} to a rights set (Manage >= Send/Listen)
  plus server-minted primary/secondary SAS keys. The broker's CBS SAS
  verifier (Smalt.Amqp.SasVerifier) consults this module when a token's
  skn is not the namespace RootManageSharedAccessKey: a token signed with
  a rule key verifies with that rule's rights, which ride the CBS claim,
  and right_authorizes?/2 gates per direction (Manage implies Send+Listen).

  Rule keys sign/verify with the same scheme as the namespace key:
  sig = Base64(HMAC-SHA256(key, "sr\nse")) over the URL-encoded sr.
  """

  @table :smalt_sb_auth_rules
  @rights [:manage, :send, :listen]
  @max_rules_per_queue 16
  @max_name_bytes 128
  @max_queue_bytes 260

  defstruct [:queue, :name, :rights, :primary_key, :secondary_key, :created_at]

  @type right :: :manage | :send | :listen

  @type t :: %__MODULE__{
          queue: String.t(),
          name: String.t(),
          rights: [right(), ...],
          primary_key: String.t(),
          secondary_key: String.t(),
          created_at: integer()
        }

  # -- client API -------------------------------------------------------------

  @doc """
  PUT a rule: creates or replaces {queue, name} with FRESH key material
  (PUT = replace in real SB; keys rotate on every PUT).
  """
  @spec put_rule(String.t(), String.t(), [right(), ...]) ::
          {:ok, t()} | {:error, term()}
  def put_rule(queue, name, rights) when is_binary(queue) and is_binary(name) do
    ensure_table()

    with :ok <- check_name(name),
         :ok <- check_queue(queue),
         {:ok, rights} <- validate_rights(rights),
         :ok <- rule_capacity(queue) do
      rule = %__MODULE__{
        queue: queue,
        name: name,
        rights: rights,
        primary_key: mint_key(),
        secondary_key: mint_key(),
        created_at: System.system_time(:second)
      }

      true = :ets.insert(@table, {{queue, name}, rule})
      {:ok, rule}
    end
  end

  @doc "GET one rule. {:error, :not_found} when absent."
  @spec get_rule(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_rule(queue, name) do
    ensure_table()

    case :ets.lookup(@table, {queue, name}) do
      [{_key, rule}] -> {:ok, rule}
      [] -> {:error, :not_found}
    end
  end

  @doc "LIST rules for a queue, name-ordered."
  @spec list_rules(String.t()) :: [t()]
  def list_rules(queue) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {{q, _n}, _r} -> q == queue end)
    |> Enum.sort_by(fn {_k, r} -> r.name end)
    |> Enum.map(fn {_k, r} -> r end)
  end

  @doc """
  DELETE a rule. The last remaining rule on a queue is refused
  ({:error, :last_rule} - real SB requires at least one rule per entity).
  """
  @spec delete_rule(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, :last_rule}
  def delete_rule(queue, name) do
    with {:ok, _rule} <- get_rule(queue, name) do
      if length(list_rules(queue)) <= 1 do
        {:error, :last_rule}
      else
        :ets.delete(@table, {queue, name})
        :ok
      end
    end
  end

  @doc """
  POST regenerateKeys: fresh material for "primaryKey" (default) or
  "secondaryKey"; the other key is untouched.
  """
  @spec regenerate_keys(String.t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, :not_found} | {:error, {:bad_key_type, term()}}
  def regenerate_keys(queue, name, key_type \\ "primaryKey") do
    with {:ok, rule} <- get_rule(queue, name),
         {:ok, which} <- parse_key_type(key_type) do
      fresh = mint_key()
      updated = Map.put(rule, which, fresh)
      true = :ets.insert(@table, {{queue, name}, updated})
      {:ok, updated}
    end
  end

  # -- verification hook (called by SasVerifier for non-namespace skn) --------

  @doc """
  Look up a rule by skn (any queue) whose primary OR secondary key equals
  key_material (constant-time compare). Returns
  {:ok, rule, :primary | :secondary} or {:error, :unknown_skn}.
  """
  @spec lookup_by_name(String.t(), String.t()) ::
          {:ok, t(), :primary | :secondary} | {:error, :unknown_skn}
  def lookup_by_name(skn, key_material) when is_binary(skn) and is_binary(key_material) do
    ensure_table()

    rules =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_q, n}, %__MODULE__{}} -> n == skn end)

    Enum.find_value(rules, {:error, :unknown_skn}, fn {_k, r} ->
      if key_matches?(r, key_material), do: {:ok, r, which_key(r, key_material)}
    end)
  end

  def lookup_by_name(_skn, _key_material), do: {:error, :unknown_skn}

  @doc """
  Rights check. nil rights = namespace key = full access (legacy path).
  Manage implies Send and Listen.
  """
  @spec right_authorizes?([right()] | nil, :send | :listen | :manage) :: boolean()
  def right_authorizes?(nil, _action), do: true

  def right_authorizes?(rights, :manage) when is_list(rights) do
    :manage in rights
  end

  def right_authorizes?(rights, :send) when is_list(rights) do
    :send in rights or :manage in rights
  end

  def right_authorizes?(rights, :listen) when is_list(rights) do
    :listen in rights or :manage in rights
  end

  def right_authorizes?(_rights, _action), do: false

  # -- key material -----------------------------------------------------------

  # 32 random bytes -> 44-char base64 (the real SB key shape).
  defp mint_key do
    Base.encode64(:crypto.strong_rand_bytes(32))
  end

  defp key_matches?(rule, key_material) do
    secure_compare?(rule.primary_key, key_material) or
      secure_compare?(rule.secondary_key, key_material)
  end

  defp which_key(rule, key_material) do
    if secure_compare?(rule.primary_key, key_material), do: :primary, else: :secondary
  end

  defp secure_compare?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare?(_, _), do: false

  defp parse_key_type("primaryKey"), do: {:ok, :primary_key}
  defp parse_key_type("secondaryKey"), do: {:ok, :secondary_key}
  defp parse_key_type(other), do: {:error, {:bad_key_type, other}}

  # -- validation -------------------------------------------------------------

  defp check_name(name) do
    if is_binary(name) and name != "" and byte_size(name) <= @max_name_bytes,
      do: :ok,
      else: {:error, :bad_name}
  end

  defp check_queue(queue) do
    if is_binary(queue) and queue != "" and byte_size(queue) <= @max_queue_bytes,
      do: :ok,
      else: {:error, :bad_queue}
  end

  defp validate_rights(rights) when rights in [nil, []], do: {:error, :rights_required}

  defp validate_rights(rights) when is_list(rights) do
    uniq = Enum.uniq(rights)

    cond do
      rights != uniq ->
        {:error, :duplicate_rights}

      not Enum.all?(rights, &(&1 in @rights)) ->
        {:error, {:bad_rights, rights -- @rights}}

      true ->
        {:ok, uniq}
    end
  end

  defp validate_rights(_), do: {:error, :bad_rights}

  defp rule_capacity(queue) do
    if length(list_rules(queue)) >= @max_rules_per_queue do
      {:error, :rule_capacity}
    else
      :ok
    end
  end

  # -- table (shadow-table law: heir'd to init so request processes can die) --

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        {:heir, Process.whereis(:init), []},
        keypos: 1,
        read_concurrency: true
      ])
    end

    :ok
  end

  # -- SasVerifier hooks (w6am) ------------------------------------------------

  @doc false
  def rights_for_skn(skn) when is_binary(skn) do
    ensure_table()

    rights =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_q, n}, _r} -> n == skn end)
      |> Enum.flat_map(fn {_k, r} -> r.rights end)
      |> Enum.uniq()

    case rights do
      [] -> :error
      rights -> {:ok, rights}
    end
  end

  def rights_for_skn(_), do: :error

  @doc false
  def rules_for_skn(skn) when is_binary(skn) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {{_q, n}, _r} -> n == skn end)
    |> Enum.map(fn {_k, r} -> r end)
  end

  def rules_for_skn(_), do: []

  @doc false
  def skn_exists?(skn) when is_binary(skn) do
    ensure_table()
    rules_for_skn(skn) != []
  end

  def skn_exists?(_), do: false
end

