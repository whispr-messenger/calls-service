defmodule WhisprCalls.Repo.Migrations.CreateCalls do
  use Ecto.Migration

  def change do
    execute "CREATE TYPE call_type AS ENUM ('audio', 'video')",
            "DROP TYPE call_type"

    execute "CREATE TYPE call_status AS ENUM ('ringing', 'connected', 'ended', 'missed', 'declined', 'failed')",
            "DROP TYPE call_status"

    create table(:calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :initiator_id, :binary_id, null: false
      add :conversation_id, :binary_id, null: false
      add :type, :call_type, null: false
      add :status, :call_status, null: false, default: "ringing"
      add :livekit_room, :string, size: 128, null: false
      add :started_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :connected_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :duration_seconds, :integer
      add :end_reason, :string, size: 50

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:calls, [:livekit_room])
    create index(:calls, [:conversation_id, :started_at])
    create index(:calls, [:initiator_id, :started_at])
    create index(:calls, [:status, :started_at])
  end
end
