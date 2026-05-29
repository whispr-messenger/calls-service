defmodule WhisprCalls.Services.UserServiceBehaviour do
  @moduledoc """
  Contrat du client user-service consomme par calls-service.

  Les implementations parlent a user-service via l'API HTTP interne
  (`/internal/v1/...`) authentifiee par le secret partage
  `x-internal-token`, exactement comme messaging-service.

  Sert a appliquer le blocage utilisateur sur l'initiation d'appel : un
  user bloque ne doit pas pouvoir appeler la personne qui l'a bloque.
  """

  @doc """
  Renvoie `{:ok, true}` quand `user_a` a bloque `user_b` ou l'inverse
  (semantique bidirectionnelle cote user-service), `{:ok, false}` sinon.

  Politique fail-closed : sur `{:error, _}` (timeout, 5xx, reseau) les
  appelants DOIVENT considerer l'appel comme bloque et le refuser. Une
  indispo de user-service ne doit jamais ouvrir une faille de
  confidentialite (un user bloque qui passe au travers).
  """
  @callback check_user_blocked(user_a :: String.t(), user_b :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
end
