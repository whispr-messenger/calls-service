defmodule WhisprCallsWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom body reader that captures the raw request body for downstream
  signature verification. Used by `Plug.Parsers` so we can compute the
  HMAC digest on LiveKit webhook bodies after they have been JSON-decoded.

  The raw body is stashed in `conn.assigns[:livekit_raw_body]`. Only the
  first 1 MiB is stored to avoid DoS through huge payloads; anything larger
  is truncated (webhook bodies are always under a few kilobytes).
  """
  @max_bytes 1_048_576

  @spec read_body(Plug.Conn.t(), keyword) ::
          {:ok, binary, Plug.Conn.t()} | {:more, binary, Plug.Conn.t()} | {:error, term}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, stash(conn, body)}

      {:more, body, conn} ->
        {:more, body, stash(conn, body)}

      {:error, _} = err ->
        err
    end
  end

  defp stash(conn, body) do
    previous = conn.assigns[:livekit_raw_body] || ""
    combined = previous <> body

    trimmed =
      if byte_size(combined) > @max_bytes do
        binary_part(combined, 0, @max_bytes)
      else
        combined
      end

    Plug.Conn.assign(conn, :livekit_raw_body, trimmed)
  end
end
