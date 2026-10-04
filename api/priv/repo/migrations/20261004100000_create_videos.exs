defmodule Retake.Repo.Migrations.CreateVideos do
  use Ecto.Migration

  def change do
    create table(:videos, primary_key: false) do
      # The video's id is also the spec's id and the file name: "v-" and ten hex digits.
      add :id, :string, primary_key: true
      add :status, :string, null: false, default: "queued"
      add :brief, :map, null: false
      add :profile, :string
      add :title, :string
      add :progress, :map, null: false, default: %{}
      add :spec, :map
      add :output_path, :string
      add :duration_ms, :integer
      add :warnings, {:array, :string}, null: false, default: []
      add :error, :map

      timestamps(type: :utc_datetime)
    end

    create index(:videos, [:inserted_at])
    create index(:videos, [:status])
  end
end
