defmodule WhisprCalls.Services.HttpUserServiceClient do
  @moduledoc """
  Implementation reelle de `WhisprCalls.Services.UserServiceBehaviour` qui
  dialogue avec user-service en HTTP via le secret partage
  `x-internal-token`.

  Mirror du `HttpUserServiceClient` de messaging-service : meme endpoint
  `GET /internal/v1/contacts/check?ownerId=&contactId=`, meme header, meme
  politique fail-closed sur erreur transitoire.

  L'URL de base et le token viennent de l'application env (cf.
  `config/runtime.exs`). On utilise `Req` (deja present dans calls-service)
  plutot que `Finch` pour rester coherent avec le reste du repo.
  """

  @behaviour WhisprCalls.Services.UserServiceBehaviour

  require Logger

  alias WhisprCalls.Services.UserService

  @doc """
  Renvoie `{:ok, true}` si l'un des deux utilisateurs a bloque l'autre,
  `{:ok, false}` si aucun des deux ne l'a fait, et `{:error, _}` en cas
  d'echec.

  Politique fail-closed : les appelants DOIVENT traiter `{:error, _}`
  comme bloque. On ne renvoie pas `{:ok, false}` sur erreur transitoire,
  sinon des utilisateurs bloques pourraient initier des appels quand
  user-service est degrade. `isBlocked` est bidirectionnel cote
  user-service, un seul appel suffit.
  """
  @impl true
  def check_user_blocked(user_a, user_b) do
    owner = String.trim(to_string(user_a))
    contact = String.trim(to_string(user_b))

    case do_check(owner, contact) do
      {:ok, %{"isBlocked" => is_blocked}} ->
        {:ok, is_blocked == true}

      {:ok, _payload} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_check(owner_id, contact_id) do
    url = UserService.internal_base_url() <> "/contacts/check"

    req_opts =
      [
        url: url,
        params: [ownerId: owner_id, contactId: contact_id],
        headers: build_headers(),
        receive_timeout: UserService.timeout_ms()
      ]
      |> Keyword.merge(Application.get_env(:whispr_calls, :user_service_req_options, []))

    case Req.get(req_opts) do
      {:ok, %{status: 200, body: body}} ->
        normalize_body(body)

      {:ok, %{status: status}} when status in [401, 403] ->
        Logger.error("user-service rejected internal token",
          status: status,
          domain: :user_service
        )

        {:error, :unauthorized}

      {:ok, %{status: status}} when status >= 500 ->
        Logger.warning("user-service 5xx on internal contacts check",
          status: status,
          domain: :user_service
        )

        {:error, :transient}

      {:ok, %{status: status}} ->
        Logger.warning("user-service unexpected status on internal contacts check",
          status: status,
          domain: :user_service
        )

        {:error, :request_failed}

      {:error, reason} ->
        Logger.warning("user-service request failed",
          reason: inspect(reason),
          domain: :user_service
        )

        {:error, :transient}
    end
  end

  # Req decode le JSON automatiquement quand le content-type est json, mais
  # on couvre aussi le cas binaire brut par prudence.
  defp normalize_body(%{} = json), do: {:ok, json}

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_body(_), do: {:error, :invalid_response}

  defp build_headers do
    base = [{"accept", "application/json"}]

    case UserService.internal_token() do
      token when is_binary(token) and token != "" ->
        base ++ [{"x-internal-token", token}]

      _ ->
        base
    end
  end
end
