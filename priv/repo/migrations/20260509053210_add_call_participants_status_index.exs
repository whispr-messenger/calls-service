defmodule WhisprCalls.Repo.Migrations.AddCallParticipantsStatusIndex do
  use Ecto.Migration

  def change do
    # Queries filter call_participants on (call_id, status) to check ringing/joined/left counts.
    # The existing unique index on (call_id, user_id) does not cover status filtering.
    create index(:call_participants, [:call_id, :status])
  end
end
