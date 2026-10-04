defmodule Retake.Test.NoopRunner do
  @moduledoc """
  Stands in for `Retake.Videos.Runner` in controller tests (`config :retake, :video_runner`):
  a started job is only reported to the test process, nothing runs. A controller test runs the
  request in the test process, so `self()` is the test.
  """

  def start(video) do
    send(self(), {:runner_started, video.id})
    {:ok, self()}
  end
end

defmodule Retake.Test.RefusingRunner do
  @moduledoc "A runner that cannot start a job."

  def start(_video), do: {:error, :too_many_jobs}
end
