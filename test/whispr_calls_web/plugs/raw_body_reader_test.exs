defmodule WhisprCallsWeb.Plugs.RawBodyReaderTest do
  @moduledoc """
  Couvre les branches `:more`, `:error` et la troncature au-dela de 1 MiB
  de `read_body/2`. Les tests passent par un adaptateur Plug factice qui
  retourne le verdict souhaite a `read_req_body/2`.
  """
  use ExUnit.Case, async: true

  alias Plug.Conn
  alias WhisprCallsWeb.Plugs.RawBodyReader

  defp conn_with(adapter_state) do
    %Conn{adapter: {__MODULE__.FakeAdapter, adapter_state}}
  end

  describe "stash branches" do
    test ":ok stores the body in assigns under :livekit_raw_body" do
      conn = conn_with({:ok, "hello"})
      assert {:ok, "hello", new_conn} = RawBodyReader.read_body(conn, [])
      assert new_conn.assigns[:livekit_raw_body] == "hello"
    end

    test ":more chunk path stashes progressively" do
      conn = conn_with({:more, "chunk"})
      assert {:more, "chunk", new_conn} = RawBodyReader.read_body(conn, [])
      assert new_conn.assigns[:livekit_raw_body] == "chunk"
    end

    test ":error path bubbles up unchanged" do
      conn = conn_with({:error, :boom})
      assert {:error, :boom} = RawBodyReader.read_body(conn, [])
    end

    test "trims combined body to 1 MiB when previous + body exceeds it" do
      previous = String.duplicate("a", 1_048_500)
      addition = String.duplicate("b", 5_000)

      conn =
        conn_with({:ok, addition})
        |> Conn.assign(:livekit_raw_body, previous)

      assert {:ok, _body, new_conn} = RawBodyReader.read_body(conn, [])
      stashed = new_conn.assigns[:livekit_raw_body]
      assert byte_size(stashed) == 1_048_576
    end
  end

  defmodule FakeAdapter do
    @moduledoc false

    def read_req_body(state, _opts) do
      case state do
        {:ok, body} -> {:ok, body, :read}
        {:more, body} -> {:more, body, state}
        {:error, _} = err -> err
      end
    end
  end
end
