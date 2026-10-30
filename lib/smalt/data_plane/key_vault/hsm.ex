defmodule Smalt.DataPlane.KeyVault.HSM do
  @moduledoc """
  Managed HSM face: the oct-HSM-adjacent surface of the KV data plane —
  `randomnumbers`, AES Key Wrap (RFC 3394/5649, A128KW/A192KW/A256KW) wrap
  and unwrap, and the public AES-KW seam.

  Crypto admission (release-policy / disabled gate, key fetch, GCM and RSA
  encrypt/decrypt engines) stays in `Smalt.DataPlane.KeyVault.Keys` and is
  consumed through its `@doc false` seams (`with_key/5`, `do_encrypt/3`,
  `do_decrypt/3`, `b64_field/2..3`, `b64url_encode/1`, `bad_request/2`) — one
  engine, one calculus, no drift.
  """

  alias Smalt.DataPlane.KeyVault.Keys

  @doc "POST /keys/:name/randomnumbers (w6bc): length random bytes wrapped by the key per alg. oct keys get AES-KW; RSA faces typed-UNSUPPORTED (400 InvalidAlgorithm)."
  def random_numbers(name, params) when is_map(params) do
    Keys.with_key(name, "wrapKey", params, nil, fn record, _params, material ->
      with {:ok, alg} <- randomnumbers_alg(material, params),
           {:ok, len} <- randomnumbers_length(params["length"]),
           {:ok, plain} <- kw_rand(material, alg, len) do
        case do_kw(material, alg, plain, record["kid"]) do
          {wrapped, kid} -> {:ok, 200, %{"value" => Keys.b64url_encode(wrapped), "kid" => kid}}
        end
      end
    end)
  end

  def random_numbers(_name, _params) do
    {:error, 400, Keys.bad_request("InvalidParameter", "request body must be a JSON object")}
  end

  defp kw_rand({:oct, _}, _alg, len), do: {:ok, :crypto.strong_rand_bytes(len)}

  defp do_kw({:oct, key}, _alg, plain, kid), do: {kw_wrap(key, plain), kid}

  defp randomnumbers_alg({:oct, key}, %{"alg" => "A256KW"}) when byte_size(key) == 32, do: {:ok, "A256KW"}
  defp randomnumbers_alg({:oct, key}, %{"alg" => "A192KW"}) when byte_size(key) == 24, do: {:ok, "A192KW"}
  defp randomnumbers_alg({:oct, _key}, %{"alg" => "A128KW"}), do: {:ok, "A128KW"}

  defp randomnumbers_alg({:oct, _}, %{"alg" => kw}) when kw in ["A256KW", "A192KW", "A128KW"] do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "oct key size does not match requested KW alg")}
  end

  defp randomnumbers_alg(_m, %{"alg" => "RSA-OAEP-256"}) do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "randomnumbers RSA faces are typed-UNSUPPORTED at this tier")}
  end

  defp randomnumbers_alg(_m, %{"alg" => other}) do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "unsupported alg " <> other)}
  end

  defp randomnumbers_alg(_m, _params) do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "alg is required")}
  end

  defp randomnumbers_length(len) when is_integer(len) and len in 16..128 and rem(len, 8) == 0, do: {:ok, len}

  defp randomnumbers_length(_) do
    {:error, 400, Keys.bad_request("InvalidParameter", "length must be an integer in 16..128 and a multiple of 8")}
  end

  @doc "AES Key Wrap dispatch for wrapKey/unwrapKey (w6bc): oct keys get RFC 3394/5649 AES-KW (A256KW/A192KW/A128KW); the landed A256GCM oct face is preserved; RSA keeps the landed RSA-OAEP-256 face. Additive."
  def key_wrap(name, params, version \\ nil)

  def key_wrap(name, params, version) do
    Keys.with_key(name, "wrapKey", params, version, fn record, params, material ->
      case material do
        {:oct, key} ->
          if kw_alg_request?(params) do
            with {:ok, alg} <- kw_alg(params, key),
                 {:ok, plain} <- Keys.b64_field(params, "value"),
                 :ok <- kw_multiple?(plain) do
              {:ok, 200, %{"value" => Keys.b64url_encode(kw_wrap(key, plain)), "kid" => record["kid"], "alg" => alg}}
            end
          else
            Keys.do_encrypt(record, params, {:oct, key})
          end

        {:rsa, _} = rsa ->
          Keys.do_encrypt(record, params, rsa)
      end
    end)
  end

  @doc "Public AES-KW seam (w6bc): RFC 3394 wrap/unwrap exposed for callers; asserted byte-exact against the RFC 3394 B.2 vector in the w6bc witness."
  def aes_kw_wrap(kek, plain), do: kw_wrap(kek, plain)
  def aes_kw_unwrap(kek, wrapped), do: kw_unwrap(kek, wrapped)

  @doc "AES-KW unwrap side of key_wrap/3."
  def key_unwrap(name, params, version \\ nil)

  def key_unwrap(name, params, version) do
    Keys.with_key(name, "unwrapKey", params, version, fn record, params, material ->
      case material do
        {:oct, key} ->
          if kw_alg_request?(params) do
            with {:ok, alg} <- kw_alg(params, key),
                 {:ok, wrapped} <- Keys.b64_field(params, "value"),
                 :ok <- kw_multiple?(wrapped) do
              {:ok, 200, %{"value" => Keys.b64url_encode(kw_unwrap(key, wrapped)), "kid" => record["kid"], "alg" => alg}}
            end
          else
            Keys.do_decrypt(record, params, {:oct, key})
          end

        {:rsa, _} = rsa ->
          Keys.do_decrypt(record, params, rsa)
      end
    end)
  end

  defp kw_alg_request?(%{"alg" => alg}) when alg in ["A256KW", "A192KW", "A128KW"], do: true
  defp kw_alg_request?(%{"alg" => _}), do: false
  defp kw_alg_request?(_), do: false

  defp kw_multiple?(bin) when rem(byte_size(bin), 8) == 0, do: :ok

  defp kw_multiple?(_) do
    {:error, 400, Keys.bad_request("InvalidValue", "AES-KW value must be a multiple of 8 bytes")}
  end

  defp kw_alg(%{"alg" => "A256KW"}, key) when byte_size(key) == 32, do: {:ok, "A256KW"}
  defp kw_alg(%{"alg" => "A192KW"}, key) when byte_size(key) == 24, do: {:ok, "A192KW"}
  defp kw_alg(%{"alg" => "A128KW"}, key) when byte_size(key) == 16, do: {:ok, "A128KW"}

  defp kw_alg(%{"alg" => kw}, _key) when kw in ["A256KW", "A192KW", "A128KW"] do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "oct key size does not match requested KW alg")}
  end

  defp kw_alg(%{"alg" => other}, _key) do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "unsupported alg " <> other)}
  end

  defp kw_alg(_params, _key) do
    {:error, 400, Keys.bad_request("InvalidAlgorithm", "alg is required")}
  end

  # ---------------------------------------------------------------------------
  # w6bc: AES-KW core (RFC 3394). OTP 28 :crypto has no :aes_kw cipher, so the
  # wrap/unwrap is the standard algorithm in pure Elixir (same approach as the
  # landed hand-built EMSA-PSS in kv_pss.ex). RFC 3394 B.2 vector asserted
  # byte-exact in the w6bc witness.
  # ---------------------------------------------------------------------------

  @kw_iv <<0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6>>

  defp kw_wrap(kek, plain) do
    n = div(byte_size(plain), 8)
    rs = for i <- 1..n, do: binary_part(plain, (i - 1) * 8, 8)
    [a | rest] = kw_loop(kek, @kw_iv, rs, n, 0)
    a <> Enum.join(rest)
  end

  defp kw_loop(_kek, a, rs, _n, 6), do: [a | rs]

  defp kw_loop(kek, a, rs, n, j) do
    {a2, rs2} =
      Enum.reduce(1..n, {a, rs}, fn i, {acc_a, acc_r} ->
        b = aes_block(kek, acc_a <> Enum.at(acc_r, i - 1))
        t = n * j + i
        <<msb::binary-size(8), lsb::binary-size(8)>> = b
        {kw_xor8(msb, t), List.replace_at(acc_r, i - 1, lsb)}
      end)

    kw_loop(kek, a2, rs2, n, j + 1)
  end

  defp kw_unwrap(kek, wrapped) do
    n = div(byte_size(wrapped) - 8, 8)
    <<a::binary-size(8), rest::binary>> = wrapped
    rs = for <<r::binary-size(8) <- rest>>, do: r
    [_a2 | rs2] = kw_unloop(kek, a, rs, n, 5)
    IO.iodata_to_binary(rs2)
  end

  defp kw_unloop(_kek, a, rs, _n, j) when j < 0, do: [a | rs]

  defp kw_unloop(kek, a, rs, n, j) do
    {a2, rs2} =
      Enum.reduce(n..1//-1, {a, rs}, fn i, {acc_a, acc_r} ->
        t = n * j + i
        xored = kw_xor8(acc_a, t)
        b = aes_block(kek, xored <> Enum.at(acc_r, i - 1), false)
        <<msb::binary-size(8), lsb::binary-size(8)>> = b
        {msb, List.replace_at(acc_r, i - 1, lsb)}
      end)

    kw_unloop(kek, a2, rs2, n, j - 1)
  end

  defp aes_block(kek, block, encrypt? \\ true) do
    cipher = :"aes_#{byte_size(kek) * 8}_ecb"
    :crypto.crypto_one_time(cipher, kek, block, encrypt?)
  end

  defp kw_xor8(<<a::integer-size(64)>>, t) do
    import Bitwise
    <<bxor(a, t)::integer-size(64)>>
  end
end
