defmodule WhisprCalls.Calls.Call do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(audio video)
  @statuses ~w(ringing connected ended missed declined failed)

  schema "calls" do
    field :initiator_id, :binary_id
    field :conversation_id, :binary_id
    field :type, :string
    field :status, :string, default: "ringing"
    field :livekit_room, :string
    field :started_at, :utc_datetime_usec
    field :connected_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_seconds, :integer
    field :end_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :initiator_id,
      :conversation_id,
      :type,
      :status,
      :livekit_room,
      :started_at,
      :connected_at,
      :ended_at,
      :duration_seconds,
      :end_reason
    ])
    |> validate_required([:initiator_id, :conversation_id, :type, :livekit_room])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:livekit_room)
  end
end
