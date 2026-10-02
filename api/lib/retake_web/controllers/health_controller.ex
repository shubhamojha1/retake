defmodule RetakeWeb.HealthController do
  use RetakeWeb, :controller

  @doc "Liveness plus a database round trip."
  def show(conn, _params) do
    %{rows: [[1]]} = Ecto.Adapters.SQL.query!(Retake.Repo, "select 1", [])
    json(conn, %{status: "ok"})
  end
end
