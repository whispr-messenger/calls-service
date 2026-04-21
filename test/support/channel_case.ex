defmodule WhisprCallsWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests. It sets
  up the DB sandbox and imports Phoenix.ChannelTest helpers. For database
  isolation use `async: false` when calling with Mox/DataCase setup.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import WhisprCallsWeb.ChannelCase

      # The default endpoint for testing
      @endpoint WhisprCallsWeb.Endpoint
    end
  end

  setup tags do
    WhisprCalls.DataCase.setup_sandbox(tags)
    :ok
  end
end
