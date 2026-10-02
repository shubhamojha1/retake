defmodule Retake.Repo do
  use Ecto.Repo,
    otp_app: :retake,
    adapter: Ecto.Adapters.Postgres
end
