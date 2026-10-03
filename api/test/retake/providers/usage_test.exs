defmodule Retake.Providers.UsageTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Usage

  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  setup do
    %{usage: start_supervised!(Usage)}
  end

  describe "reserve/4: rate limits" do
    test "allows calls up to the limit, then refuses", %{usage: usage} do
      limits = %{requests_per_minute: 2}
      assert Usage.reserve(usage, "groq", limits, 0) == :ok
      assert Usage.reserve(usage, "groq", limits, 1_000) == :ok
      assert {:error, {:rate_limited, :minute, _}} = Usage.reserve(usage, "groq", limits, 2_000)
    end

    test "says how long until the oldest call leaves the window", %{usage: usage} do
      limits = %{requests_per_minute: 1}
      :ok = Usage.reserve(usage, "groq", limits, 10_000)

      assert {:error, {:rate_limited, :minute, retry_after}} =
               Usage.reserve(usage, "groq", limits, 25_000)

      assert retry_after == 10_000 + @minute - 25_000
    end

    test "the window slides: calls expire", %{usage: usage} do
      limits = %{requests_per_minute: 1}
      :ok = Usage.reserve(usage, "groq", limits, 0)

      assert {:error, {:rate_limited, :minute, _}} =
               Usage.reserve(usage, "groq", limits, @minute - 1)

      assert Usage.reserve(usage, "groq", limits, @minute) == :ok
    end

    test "a refused call is not counted", %{usage: usage} do
      limits = %{requests_per_minute: 1}
      :ok = Usage.reserve(usage, "groq", limits, 0)
      {:error, _} = Usage.reserve(usage, "groq", limits, 1_000)
      {:error, _} = Usage.reserve(usage, "groq", limits, 2_000)
      assert Usage.reserve(usage, "groq", limits, @minute) == :ok
    end

    test "hour, day and month windows are enforced too", %{usage: usage} do
      assert {:error, {:rate_limited, :hour, _}} =
               fill(usage, %{requests_per_hour: 3}, 4, @minute)

      assert {:error, {:rate_limited, :day, _}} = fill(usage, %{requests_per_day: 3}, 4, @hour)
      assert {:error, {:rate_limited, :month, _}} = fill(usage, %{requests_per_month: 3}, 4, @day)
    end

    test "providers are counted separately", %{usage: usage} do
      limits = %{requests_per_minute: 1}
      assert Usage.reserve(usage, "groq", limits, 0) == :ok
      assert Usage.reserve(usage, "pexels", limits, 0) == :ok
    end

    test "no limits means no refusals", %{usage: usage} do
      for i <- 1..50, do: assert(Usage.reserve(usage, "ollama", %{}, i) == :ok)
    end

    test "concurrent reservations never exceed the limit", %{usage: usage} do
      limits = %{requests_per_minute: 10}

      results =
        1..50
        |> Task.async_stream(fn _ -> Usage.reserve(usage, "groq", limits, 0) end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 10
    end
  end

  describe "budget" do
    @budget %{max_cost_per_video_usd: 0.5, max_cost_per_day_usd: 1.0}

    test "is fine until a cap is reached", %{usage: usage} do
      assert Usage.check_budget(usage, @budget, "v1", 0) == :ok
      :ok = Usage.charge(usage, "v1", 0.3, 0)
      assert Usage.check_budget(usage, @budget, "v1", 1) == :ok
    end

    test "stops a video at its cap", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.5, 0)
      assert Usage.check_budget(usage, @budget, "v1", 1) == {:error, {:budget_exceeded, :video}}
    end

    test "another video is unaffected by the first video's spend", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.5, 0)
      assert Usage.check_budget(usage, @budget, "v2", 1) == :ok
    end

    test "stops everything at the daily cap", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.4, 0)
      :ok = Usage.charge(usage, "v2", 0.4, 0)
      :ok = Usage.charge(usage, "v3", 0.3, 0)
      assert Usage.check_budget(usage, @budget, "v4", 1) == {:error, {:budget_exceeded, :day}}
    end

    test "the daily window rolls: old spend expires", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.4, 0)
      :ok = Usage.charge(usage, "v2", 0.4, 0)
      :ok = Usage.charge(usage, "v3", 0.3, 0)
      assert Usage.check_budget(usage, @budget, "v4", @day) == :ok
    end

    test "without a video id only the daily cap applies", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.9, 0)
      assert Usage.check_budget(usage, @budget, nil, 1) == :ok
    end

    test "a missing cap means no cap", %{usage: usage} do
      :ok = Usage.charge(usage, "v1", 100.0, 0)
      assert Usage.check_budget(usage, %{}, "v1", 1) == :ok
    end
  end

  # Reserves `count` times, `step` ms apart, and returns the last result.
  defp fill(usage, limits, count, step) do
    for i <- 0..(count - 1), reduce: nil do
      _ -> Usage.reserve(usage, "p-#{map_size(limits)}-#{inspect(limits)}", limits, i * step)
    end
  end
end
