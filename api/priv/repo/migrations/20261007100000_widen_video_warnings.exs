defmodule Retake.Repo.Migrations.WidenVideoWarnings do
  use Ecto.Migration

  # A warning can carry a provider's error text. As varchar(255)[] one long warning made the save
  # of a finished video fail ("value too long for type character varying(255)"), so the page
  # never learned that the video was done.
  def change do
    alter table(:videos) do
      modify :warnings, {:array, :text}, from: {:array, :string}
    end
  end
end
