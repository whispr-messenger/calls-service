defmodule WhisprCalls.Calls.LiveKitClientHTTPTest do
  use ExUnit.Case, async: false

  alias WhisprCalls.Calls.LiveKitClientHTTP

  setup do
    # generate_access_token n appelle pas Req : c est juste une signature Joken.
    # On force des creds en application env pour que fetch_env! reussisse.
    prev_key = Application.get_env(:whispr_calls, :livekit_api_key)
    prev_secret = Application.get_env(:whispr_calls, :livekit_api_secret)
    prev_url = Application.get_env(:whispr_calls, :livekit_api_url)

    Application.put_env(:whispr_calls, :livekit_api_key, "devkey")
    Application.put_env(:whispr_calls, :livekit_api_secret, "devsecret123456789012345678901234")
    Application.put_env(:whispr_calls, :livekit_api_url, "http://livekit.test")

    on_exit(fn ->
      put_or_delete(:livekit_api_key, prev_key)
      put_or_delete(:livekit_api_secret, prev_secret)
      put_or_delete(:livekit_api_url, prev_url)
    end)

    :ok
  end

  describe "generate_access_token/3 default TTL" do
    test "default TTL est 120 secondes (WHISPR-1363, plus 7200)" do
      user = "user-1"
      room = "call_default"

      {:ok, token} = LiveKitClientHTTP.generate_access_token(user, room, [])

      claims = decode_unverified_claims(token)
      assert claims["exp"] - claims["nbf"] == 120
      assert claims["sub"] == user
      assert get_in(claims, ["video", "room"]) == room
    end

    test "opt :ttl override le default" do
      {:ok, token} = LiveKitClientHTTP.generate_access_token("user-2", "room-2", ttl: 60)
      claims = decode_unverified_claims(token)
      assert claims["exp"] - claims["nbf"] == 60
    end
  end

  defp decode_unverified_claims(token) do
    [_h, payload, _s] = String.split(token, ".")

    payload
    |> pad_base64()
    |> Base.url_decode64!()
    |> Jason.decode!()
  end

  # Joken / JWT base64url tronque les paddings, on les rajoute pour Base.url_decode64!
  defp pad_base64(payload) do
    case rem(byte_size(payload), 4) do
      0 -> payload
      n -> payload <> String.duplicate("=", 4 - n)
    end
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:whispr_calls, key)
  defp put_or_delete(key, value), do: Application.put_env(:whispr_calls, key, value)
end
