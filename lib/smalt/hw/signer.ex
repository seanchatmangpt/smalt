defmodule Smalt.Hw.Signer do
  @moduledoc """
  Deterministic Ed25519 signer for the virtual HIL device.

  Key material derives from `SMALT_HW_SEED` (any string; default
  "smalt-dev-seed") via SHA-256 -> 32-byte Ed25519 seed, so the same env
  reproduces the same device identity across restarts.

  ## Honest scope

  GATE2 passes on flow success: ENROLL -> CAPABILITIES advertising
  "sim-0.1+ed25519" -> SIGN_CHALLENGE -> 64-byte signature in the wire slot.
  Cryptographic end-to-end validation (a validator branch that verifies the
  receipt signature against the device public key) is a SEPARATE TASK —
  `attest.py` currently captures the signature with `verified: false`
  ("public key not provisioned"). Export `public_key/0` here is the seam the
  future validator branch will provision.
  """

  @doc "Ed25519 seed (32 bytes) derived from SMALT_HW_SEED."
  def seed do
    seed_str = System.get_env("SMALT_HW_SEED") || "smalt-dev-seed"
    :crypto.hash(:sha256, seed_str)
  end

  @doc "{public_key(32B), private_key(32B seed)} — deterministic from the seed."
  def keypair do
    :crypto.generate_key(:eddsa, :ed25519, seed())
  end

  @doc "64-byte Ed25519 signature over a binary digest. Deterministic."
  def sign(digest) when is_binary(digest) do
    {_pub, priv} = keypair()
    :crypto.sign(:eddsa, :none, digest, [priv, :ed25519])
  end

  @doc "Device public key (32 bytes) — provisioning seam for the validator."
  def public_key do
    {pub, _priv} = keypair()
    pub
  end

  @doc "Deterministic chipset serial derived from the public key."
  def serial do
    ("SIM-SMALT-" <> Base.encode16(:crypto.hash(:sha256, public_key()), case: :lower))
    |> binary_part(0, 12)
  end
end
