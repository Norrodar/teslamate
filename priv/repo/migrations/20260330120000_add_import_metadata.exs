defmodule TeslaMate.Repo.Migrations.AddImportMetadata do
  use Ecto.Migration

  def change do
    create table(:import_metadata) do
      add :source, :string, null: false
      add :imported_at, :utc_datetime_usec, null: false
      add :car_id, references(:cars, on_delete: :delete_all)
      add :source_car_id, :integer
      add :positions_count, :integer, default: 0
      add :drives_count, :integer, default: 0
      add :charges_count, :integer, default: 0
      add :charging_processes_count, :integer, default: 0
      add :states_count, :integer, default: 0
      add :updates_count, :integer, default: 0
      add :warnings_count, :integer, default: 0
      add :config, :map

      timestamps()
    end

    create index(:import_metadata, [:car_id])
    create index(:import_metadata, [:source])
  end
end
