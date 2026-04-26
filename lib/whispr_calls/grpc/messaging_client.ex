defmodule WhisprCalls.Grpc.MessagingClient do
  @moduledoc """
  Client contract for checking whether a user is a member of a conversation
  on messaging-service.

  Two implementations are provided:

    * `Stub`  — always returns `{:ok, :member}`. Default in `dev` / `test`
      and handy for environments where messaging-service isn't reachable.
    * `HTTP`  — calls the messaging-service REST API. Used until a proper
      gRPC proto / stub lands on messaging-service side.

  The active implementation is selected via the `:messaging_client`
  application env. Tests that want to assert the not-member path can
  swap the implementation for a Mox mock at runtime.
  """

  @callback verify_membership(conversation_id :: String.t(), user_id :: String.t()) ::
              {:ok, :member} | {:error, :not_member | term()}

  @callback list_members(conversation_id :: String.t()) ::
              {:ok, :any | [String.t()]} | {:error, term()}

  @spec verify_membership(String.t(), String.t()) ::
          {:ok, :member} | {:error, :not_member | term()}
  def verify_membership(conversation_id, user_id) do
    impl().verify_membership(conversation_id, user_id)
  end

  @spec list_members(String.t()) :: {:ok, :any | [String.t()]} | {:error, term()}
  def list_members(conversation_id) do
    impl().list_members(conversation_id)
  end

  defp impl do
    Application.get_env(:whispr_calls, :messaging_client, __MODULE__.Stub)
  end

  defmodule Stub do
    @moduledoc """
    Fallback used when messaging-service is not available (tests and dev).
    Always returns `{:ok, :member}` so the happy path works end-to-end.

    `list_members/1` returns `{:ok, :any}` to signal "treat any user_id as
    a valid member" so callers don't have to special-case the stub.
    """

    @behaviour WhisprCalls.Grpc.MessagingClient

    @impl true
    def verify_membership(_conversation_id, _user_id), do: {:ok, :member}

    @impl true
    def list_members(_conversation_id), do: {:ok, :any}
  end

  defmodule HTTP do
    @moduledoc """
    HTTP fallback using messaging-service's REST API to verify that a user
    is a member of a conversation.

    Used until messaging-service exposes a gRPC membership endpoint.
    Expects the following application env to be set:

      * `:messaging_http_endpoint` — base URL (e.g. `"http://messaging-service:4000"`)
      * `:messaging_service_token` — bearer token used for service-to-service auth
    """

    @behaviour WhisprCalls.Grpc.MessagingClient

    require Logger

    @impl true
    def verify_membership(conversation_id, user_id) do
      case list_members(conversation_id) do
        {:ok, members} when is_list(members) ->
          if user_id in members, do: {:ok, :member}, else: {:error, :not_member}

        {:error, :not_member} = err ->
          err

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def list_members(conversation_id) do
      base = Application.fetch_env!(:whispr_calls, :messaging_http_endpoint)
      token = Application.fetch_env!(:whispr_calls, :messaging_service_token)

      url = "#{base}/messaging/api/v1/conversations/#{conversation_id}/members"

      req_opts =
        [
          url: url,
          headers: [{"authorization", "Bearer #{token}"}],
          receive_timeout: 2_000
        ]
        |> Keyword.merge(Application.get_env(:whispr_calls, :messaging_http_req_options, []))

      case Req.get(req_opts) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, extract_member_ids(body)}

        {:ok, %{status: 403}} ->
          {:error, :not_member}

        {:ok, %{status: 404}} ->
          {:error, :not_member}

        {:ok, %{status: status}} ->
          Logger.warning("messaging membership check returned HTTP #{status}")
          {:error, :not_member}

        {:error, err} ->
          Logger.error("messaging membership check failed: #{inspect(err)}")
          {:error, err}
      end
    end

    defp extract_member_ids(%{"members" => members}) when is_list(members),
      do: Enum.flat_map(members, &member_id/1)

    defp extract_member_ids(members) when is_list(members),
      do: Enum.flat_map(members, &member_id/1)

    defp extract_member_ids(_), do: []

    defp member_id(%{"user_id" => uid}) when is_binary(uid), do: [uid]
    defp member_id(%{"userId" => uid}) when is_binary(uid), do: [uid]
    defp member_id(_), do: []
  end
end
