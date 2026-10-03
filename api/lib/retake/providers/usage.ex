defmodule Retake.Providers.Usage do
  @moduledoc """
  Rate-limit windows and budget spend (decision D16: in memory, behind this module).

  Reservations are atomic: the check and the count happen in one call, so
  parallel scenes cannot both slip under a limit. Time is passed in as `now`
  (milliseconds) so tests never sleep. Windows are rolling (minute, hour, day,
  30 days), not calendar. Counters reset when the app restarts.
  """

  use GenServer

  @day 86_400_000
  @month 30 * @day
  @windows [
    minute: {:requests_per_minute, 60_000},
    hour: {:requests_per_hour, 3_600_000},
    day: {:requests_per_day, @day},
    month: {:requests_per_month, @month}
  ]

  @type server :: GenServer.server()
  @type limits :: %{optional(atom()) => pos_integer()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @doc """
  Counts one call to `provider` unless a limit in `limits` is already reached.
  A refused call is not counted. `retry_after` is milliseconds until the oldest
  call in the exceeded window expires.
  """
  @spec reserve(server(), String.t(), limits(), integer()) ::
          :ok | {:error, {:rate_limited, :minute | :hour | :day | :month, non_neg_integer()}}
  def reserve(server, provider, limits, now) do
    GenServer.call(server, {:reserve, provider, limits, now})
  end

  @doc """
  Checks the per-video cap (for `video_id`, when given) and the rolling 24 hour cap.
  A cap is reached when spend is at or above it. A missing cap is no cap.
  """
  @spec check_budget(server(), map(), String.t() | nil, integer()) ::
          :ok | {:error, {:budget_exceeded, :video | :day}}
  def check_budget(server, budget, video_id, now) do
    GenServer.call(server, {:check_budget, budget, video_id, now})
  end

  @doc "Records `cost_usd` spent on `video_id` (may be nil: counts toward the day only)."
  @spec charge(server(), String.t() | nil, number(), integer()) :: :ok
  def charge(server, video_id, cost_usd, now) do
    GenServer.call(server, {:charge, video_id, cost_usd, now})
  end

  # --- server --------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{calls: %{}, charges: [], video_spend: %{}}}

  @impl true
  def handle_call({:reserve, provider, limits, now}, _from, state) do
    calls =
      state.calls
      |> Map.get(provider, [])
      |> Enum.filter(&(&1 > now - @month))

    case violation(calls, limits, now) do
      nil -> {:reply, :ok, %{state | calls: Map.put(state.calls, provider, [now | calls])}}
      error -> {:reply, {:error, error}, %{state | calls: Map.put(state.calls, provider, calls)}}
    end
  end

  def handle_call({:check_budget, budget, video_id, now}, _from, state) do
    video_spent = if video_id, do: Map.get(state.video_spend, video_id, 0.0), else: 0.0

    day_spent =
      state.charges
      |> Enum.filter(fn {at, _cost} -> at > now - @day end)
      |> Enum.map(fn {_at, cost} -> cost end)
      |> Enum.sum()

    reply =
      cond do
        video_id && reached?(video_spent, budget[:max_cost_per_video_usd]) ->
          {:error, {:budget_exceeded, :video}}

        reached?(day_spent, budget[:max_cost_per_day_usd]) ->
          {:error, {:budget_exceeded, :day}}

        true ->
          :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:charge, _video_id, cost, _now}, _from, state) when cost <= 0 do
    {:reply, :ok, state}
  end

  def handle_call({:charge, video_id, cost, now}, _from, state) do
    recent = Enum.filter(state.charges, fn {at, _cost} -> at > now - @day end)

    video_spend =
      if video_id,
        do: Map.update(state.video_spend, video_id, cost, &(&1 + cost)),
        else: state.video_spend

    {:reply, :ok, %{state | charges: [{now, cost} | recent], video_spend: video_spend}}
  end

  defp reached?(_spent, nil), do: false
  defp reached?(spent, cap), do: spent >= cap

  # The first window whose limit is already used up, or nil.
  defp violation(calls, limits, now) do
    Enum.find_value(@windows, fn {window, {limit_key, span}} ->
      with limit when is_integer(limit) <- Map.get(limits, limit_key),
           in_window = Enum.filter(calls, &(&1 > now - span)),
           true <- length(in_window) >= limit do
        {:rate_limited, window, Enum.min(in_window) + span - now}
      else
        _ -> nil
      end
    end)
  end
end
