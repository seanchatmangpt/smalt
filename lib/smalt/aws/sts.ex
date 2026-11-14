defmodule Smalt.AWS.STS do
  @moduledoc """
  STS (Query protocol, `Action=...`, XML responses) (AS2).

  `GetCallerIdentity` and `AssumeRole`. AssumeRole mints temporary SigV4 credentials
  (`ASIA...` key id, 40-char secret, session token, expiry) stored in `:smalt_cosmos_docs` under
  `{:aws_sts, akid}`; `secret_for/1` resolves them (expired -> `:error`) so the router verifies
  SigV4 signatures made with the issued keys. `X-Amz-Security-Token` is not cross-checked
  (UNSUPPORTED). Role trust policies are not evaluated (UNSUPPORTED, any caller may assume).
  """
  alias Smalt.Store

  @table :smalt_cosmos_docs
  @account "000000000000"
  @ns "https://sts.amazonaws.com/doc/2011-06-15/"

  def secret_for(akid) do
    case Store.get(@table, {:aws_sts, akid}) do
      {:ok, %{secret: s, expires: e}} -> if e > System.os_time(:second), do: {:ok, s}, else: :error
      :error -> :error
    end
  end

  @doc "Mint temporary credentials. Returns the stored credential map."
  def assume_role(role_arn, session_name, duration \\ 3600) do
    akid = "ASIA" <> rand_str(16, ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    role_name = role_arn |> String.split("/") |> List.last()
    cred = %{
      akid: akid,
      secret: rand_str(40, ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
      token: Base.encode64(:crypto.strong_rand_bytes(48)),
      expires: System.os_time(:second) + duration,
      role_arn: role_arn,
      account: account_of(role_arn),
      arn: "arn:aws:sts::#{account_of(role_arn)}:assumed-role/#{role_name}/#{session_name}",
      user_id: "AROA" <> rand_str(17, ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") <> ":" <> session_name
    }

    :ok = Store.insert_new(@table, {:aws_sts, akid}, cred)
    cred
  end

  defp account_of(arn) do
    case String.split(arn, ":") do
      ["arn", _, "iam", _, acct | _] when acct != "" -> acct
      _ -> @account
    end
  end

  defp rand_str(n, alphabet) do
    for(<<b <- :crypto.strong_rand_bytes(n)>>, into: "", do: <<Enum.at(alphabet, rem(b, length(alphabet)))>>)
  end

  def dispatch(%{"Action" => "GetCallerIdentity"}, akid, identities) do
    id =
      case Store.get(@table, {:aws_sts, akid}) do
        {:ok, c} -> %{account: c.account, arn: c.arn, user_id: c.user_id}
        :error -> Map.get(identities, akid, %{account: @account, arn: "arn:aws:iam::#{@account}:user/smalt", user_id: akid || "AIDASMALT"})
      end

    {200,
     resp("GetCallerIdentity", "<Arn>#{esc(id.arn)}</Arn><UserId>#{esc(id.user_id)}</UserId><Account>#{esc(id.account)}</Account>")}
  end

  def dispatch(%{"Action" => "AssumeRole"} = p, _akid, _identities) do
    with arn when is_binary(arn) <- p["RoleArn"],
         name when is_binary(name) <- p["RoleSessionName"],
         true <- Regex.match?(~r/^[\w+=,.@-]{2,64}$/, name),
         dur when dur in 900..43200 <- parse_dur(p["DurationSeconds"]) do
      c = assume_role(arn, name, dur)
      exp = c.expires |> DateTime.from_unix!() |> DateTime.to_iso8601()

      {200,
       resp(
         "AssumeRole",
         "<Credentials><AccessKeyId>#{c.akid}</AccessKeyId><SecretAccessKey>#{c.secret}</SecretAccessKey>" <>
           "<SessionToken>#{c.token}</SessionToken><Expiration>#{exp}</Expiration></Credentials>" <>
           "<AssumedRoleUser><AssumedRoleId>#{esc(c.user_id)}</AssumedRoleId><Arn>#{esc(c.arn)}</Arn></AssumedRoleUser>"
       )}
    else
      _ -> {400, error_xml("ValidationError", "Invalid RoleArn, RoleSessionName or DurationSeconds", "Sender")}
    end
  end

  def dispatch(%{"Action" => a}, _, _), do: {400, error_xml("InvalidAction", "Could not find operation #{a} for version 2011-06-15", "Sender")}
  def dispatch(_, _, _), do: {400, error_xml("MissingAction", "Missing Action", "Sender")}

  defp parse_dur(nil), do: 3600

  defp parse_dur(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> -1
    end
  end

  defp resp(action, inner) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n<#{action}Response xmlns="#{@ns}"><#{action}Result>#{inner}</#{action}Result>) <>
      "<ResponseMetadata><RequestId>#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}</RequestId></ResponseMetadata></#{action}Response>"
  end

  def error_xml(code, msg, type \\ "Sender") do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n<ErrorResponse xmlns="#{@ns}"><Error><Type>#{type}</Type><Code>#{code}</Code>) <>
      "<Message>#{esc(msg)}</Message></Error><RequestId>#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}</RequestId></ErrorResponse>"
  end

  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
end
