defmodule WhisprCallsWeb.FallbackController do
  @moduledoc """
  Translates context-layer errors into standardized JSON responses for the
  REST API. Used via `action_fallback WhisprCallsWeb.FallbackController` in
  controllers.
  """
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, :not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  def call(conn, {:error, :call_not_found}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  def call(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  def call(conn, {:error, :not_invited}),
    do: conn |> put_status(403) |> json(%{error: "not_invited"})

  def call(conn, {:error, :not_participant}),
    do: conn |> put_status(403) |> json(%{error: "not_participant"})

  def call(conn, {:error, :not_member}),
    do: conn |> put_status(403) |> json(%{error: "not_member"})

  def call(conn, {:error, :already_joined_or_declined}),
    do: conn |> put_status(409) |> json(%{error: "already_resolved"})

  def call(conn, {:error, :call_already_ended}),
    do: conn |> put_status(409) |> json(%{error: "call_already_ended"})

  def call(conn, {:error, :invalid_request}),
    do: conn |> put_status(422) |> json(%{error: "invalid_request"})

  def call(conn, {:error, %Ecto.Changeset{}}),
    do: conn |> put_status(422) |> json(%{error: "validation_failed"})

  def call(conn, {:error, reason}) do
    conn |> put_status(500) |> json(%{error: inspect(reason)})
  end
end
