defmodule WhisprCalls.Repo.Migrations.RecreateCallParticipantsStatusIndexConcurrently do
  use Ecto.Migration

  # L'index initial (20260509053210) a ete cree sans `concurrently: true`,
  # ce qui pose un ACCESS EXCLUSIVE lock sur call_participants pendant la
  # creation. Sur une table a fort throughput (signalling temps reel) ca
  # bloque les inserts/updates le temps du build. On le recree proprement
  # ici sans bloquer la table.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    drop_if_exists index(:call_participants, [:call_id, :status])
    create index(:call_participants, [:call_id, :status], concurrently: true)
  end

  def down do
    drop index(:call_participants, [:call_id, :status])
    create index(:call_participants, [:call_id, :status])
  end
end
