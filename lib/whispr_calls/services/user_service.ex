defmodule WhisprCalls.Services.UserService do
  @moduledoc """
  Facade qui delegue au client user-service configure via l'application
  env `:user_service_client`.

  Deux implementations :

    * `Stub` — renvoie toujours `{:ok, false}` (jamais bloque). Default en
      `dev` / `test` et pour les envs ou user-service n'est pas joignable.
    * `HttpUserServiceClient` — appelle l'API HTTP interne de user-service.
      Wire en runtime.exs (prod) avec le secret partage `INTERNAL_API_TOKEN`.

  Les tests qui veulent asserter le chemin "bloque" swappent l'impl pour
  un mock Mox au runtime.
  """

  @behaviour WhisprCalls.Services.UserServiceBehaviour

  @impl true
  def check_user_blocked(user_a, user_b) do
    impl().check_user_blocked(user_a, user_b)
  end

  @doc """
  URL de base de l'API interne user-service, ex
  `http://user-service:3000/internal/v1`. Lue depuis l'application env
  `:user_service_internal_url`.
  """
  @spec internal_base_url() :: String.t()
  def internal_base_url do
    Application.fetch_env!(:whispr_calls, :user_service_internal_url)
  end

  @doc """
  Token partage envoye dans le header `x-internal-token`. `nil` ou chaine
  vide => header omis (le client tombera alors sur un 401 cote
  user-service, traite comme fail-closed).
  """
  @spec internal_token() :: String.t() | nil
  def internal_token do
    Application.get_env(:whispr_calls, :user_service_internal_token)
  end

  @doc """
  Timeout court (ms) sur les appels internes. On ne veut pas qu'un
  user-service lent bloque l'initiation d'appel : le fail-closed prend le
  relais des le timeout.
  """
  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    Application.get_env(:whispr_calls, :user_service_timeout_ms, 3_000)
  end

  # Pas de default fail-open en prod : si la cle n'est pas set on raise
  # plutot que de laisser le Stub renvoyer {:ok, false} et faire passer
  # tous les appels (un user bloque pourrait appeler).
  defp impl do
    case Application.get_env(:whispr_calls, :user_service_client) do
      nil ->
        if Application.get_env(:whispr_calls, :env) == :prod do
          raise """
          :user_service_client is not configured in production.
          Set it in config/runtime.exs (e.g.
          WhisprCalls.Services.HttpUserServiceClient) before serving
          traffic. Without this, the block check would silently pass for
          everyone (a blocked user could call the person who blocked them).
          """
        else
          __MODULE__.Stub
        end

      mod ->
        mod
    end
  end

  defmodule Stub do
    @moduledoc """
    Fallback en dev / test : personne n'est jamais bloque. Les tests qui
    veulent asserter le refus swappent `WhisprCalls.Services.UserServiceMock`.
    """

    @behaviour WhisprCalls.Services.UserServiceBehaviour

    @impl true
    def check_user_blocked(_user_a, _user_b), do: {:ok, false}
  end
end
