defmodule TeslaMate.Log.ImportMetadata do
  use Ecto.Schema
  import Ecto.Changeset

  alias TeslaMate.Log.Car

  schema "import_metadata" do
    field :source, :string
    field :imported_at, :utc_datetime_usec
    field :source_car_id, :integer
    field :positions_count, :integer, default: 0
    field :drives_count, :integer, default: 0
    field :charges_count, :integer, default: 0
    field :charging_processes_count, :integer, default: 0
    field :states_count, :integer, default: 0
    field :updates_count, :integer, default: 0
    field :warnings_count, :integer, default: 0
    field :config, :map

    belongs_to :car, Car

    timestamps()
  end

  @doc false
  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :source, :imported_at, :car_id, :source_car_id,
      :positions_count, :drives_count, :charges_count,
      :charging_processes_count, :states_count, :updates_count,
      :warnings_count, :config
    ])
    |> validate_required([:source, :imported_at])
    |> foreign_key_constraint(:car_id)
  end
end
