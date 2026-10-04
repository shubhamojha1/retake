defmodule Retake.Test.FakeAdapter do
  @moduledoc """
  A provider adapter for tests. It tells the calling process about every call
  (`{:adapter_called, provider_name, api_key, request}`) and answers from
  `Process.put(:fake_adapter_answers, %{"provider name" => answer})`, where an
  answer is a result tuple or a one-argument function of the request.

  Adapters run in the calling process, so each (async) test has its own answers.
  An unanswered call is an error: tests never reach a real provider.
  """

  @behaviour Retake.Providers.Adapter

  @impl true
  def call(provider, api_key, request) do
    send(self(), {:adapter_called, provider.name, api_key, request})

    case Map.fetch(Process.get(:fake_adapter_answers, %{}), provider.name) do
      {:ok, answer} when is_function(answer, 1) -> answer.(request)
      {:ok, answer} -> answer
      :error -> {:error, :no_answer_configured}
    end
  end
end
