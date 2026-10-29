defmodule Smalt.Powl2.HsmSigner do
  @moduledoc """
  POWL-8 in-memory HSM signer: a GenServer holding an EC secp256r1 keypair.
  `sign_digest/2` enforces a 32-byte digest (typed 400 otherwise) and signs
  the pre-hashed digest with `:public_key.sign({:digest, d}, :sha256, priv)`.
  `verify_digest/3` verifies against the derived `{:ECPoint, _}` public point.

  PPlan receipt-engine seam (NOT yet landed — lib/smalt/pplan/ carries only
  task.ex): when the receipt engine arrives, wire the signer as its optional
  signer fun --

      signer_fun = fn digest ->
        case Smalt.Powl2.HsmSigner.sign_digest(digest) do
          {:ok, sig} -> sig
          {:error, 400, _} = e -> raise ArgumentError, inspect(e)
        end
      end

  passed at engine config as `signer: signer_fun` so the engine stays
  signer-pluggable (software key vs HSM-style key).
  """

  use GenServer

  @curve_oid {1, 2, 840, 10045, 3, 1, 7}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Sign a 32-byte digest. `{:ok, sig}` or typed 400 `{:error, 400, msg}`."
  def sign_digest(pid_or_name \\ __MODULE__, digest) when is_binary(digest) do
    if byte_size(digest) == 32 do
      priv = GenServer.call(pid_or_name, :priv)
      {:ok, :public_key.sign({:digest, digest}, :sha256, priv)}
    else
      {:error, 400, "InvalidDigest: expected 32-byte digest, got #{byte_size(digest)} bytes"}
    end
  end

  @doc "true/false; malformed keys or digests verify false, never raise."
  def verify_digest(pid_or_name \\ __MODULE__, digest, sig) do
    pub = GenServer.call(pid_or_name, :pub)

    if byte_size(digest) == 32 do
      :public_key.verify({:digest, digest}, :sha256, sig, pub)
    else
      false
    end
  rescue
    _ -> false
  end

  def public_key(pid_or_name \\ __MODULE__), do: GenServer.call(pid_or_name, :pub)

  ## Server

  def init(:ok) do
    rec = :public_key.generate_key({:namedCurve, :secp256r1})
    priv_int = :erlang.element(3, rec) |> :binary.decode_unsigned()
    priv_bin = <<priv_int::unsigned-big-integer-size(32)-unit(8)>>
    {pt, _} = :crypto.generate_key(:ecdh, :secp256r1, priv_bin)
    pub = {{:ECPoint, pt}, {:namedCurve, @curve_oid}}
    {:ok, %{priv: rec, pub: pub}}
  end

  def handle_call(:priv, _from, st), do: {:reply, st.priv, st}
  def handle_call(:pub, _from, st), do: {:reply, st.pub, st}
end
