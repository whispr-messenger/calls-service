defmodule WhisprCalls.Calls.CallParticipant do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @statuses ~w(invited joined left declined missed)

  schema "call_participants" do
    belongs_to :call, WhisprCalls.Calls.Call, primary_key: true
    field :user_id, :binary_id, primary_key: true
    field :invited_at, :utc_datetime_usec
    field :joined_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec
    field :status, :string
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:call_id, :user_id, :invited_at, :joined_at, :left_at, :status])
    |> validate_required([:call_id, :user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:call_id, :user_id],
      name: :call_participants_call_id_user_id_index
    )
  end
end
