defmodule WhisprCalls.Repo.Migrations.CreateCallParticipants do
  use Ecto.Migration

  def change do
    create table(:call_participants, primary_key: false) do
      add :call_id, references(:calls, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :invited_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :joined_at, :utc_datetime_usec
      add :left_at, :utc_datetime_usec
      add :status, :string, size: 20, null: false
    end

    create unique_index(:call_participants, [:call_id, :user_id])
    create index(:call_participants, [:user_id, :invited_at])
  end
end
