defmodule Smalt.MixAuthScope do
  @moduledoc """
  Scopes the process-global `auth_mode` flip inside mix tasks that need the
  anonymous dev loop (apply/destroy/doctor/native_ladder). The flip is
  snapshot → set → restore-in-`after`, so the anonymous mode can never leak
  past the task body (a later `mix run` in the same VM would otherwise serve
  :anonymous).
  """

  @spec with_anonymous_auth((-> term())) :: term()
  def with_anonymous_auth(fun) do
    prev = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    try do
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:smalt, :auth_mode)
        prev -> Application.put_env(:smalt, :auth_mode, prev)
      end
    end
  end
end
