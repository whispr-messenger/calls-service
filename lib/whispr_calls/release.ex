defmodule WhisprCalls.Release do
  @moduledoc """
  Release-time tasks (mix is not available at runtime).

  Invoked from the production Docker entrypoint:

      bin/whispr_calls eval "WhisprCalls.Release.migrate()"
  """

  @app :whispr_calls

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
