defmodule Asas.RateLimit do
  @moduledoc """
  Per-key fixed-window rate limiter over one public ETS table.

  `hit/3` bumps the counter for the caller's current window: `{:ok, remaining}`
  under the limit, `{:error, retry_after_seconds}` over. Counting is a single
  `:ets.update_counter/4` with a default, so the hot path is lock-free and
  needs no read-then-write race. A sweep every two windows drops stale rows so
  the table stays bounded.

  Add it to the supervision tree:

      children = [Asas.RateLimit, ...]

  ponytail: fixed window, so a burst straddling a boundary can reach ~2× the
  limit — fine for abuse control, wrong for billing. Counters are per node, so
  in a cluster the effective limit is limit × nodes. Move to a shared store
  (or take `hammer`) the day either of those matters; until then this is
  forty lines and no dependency.
  """
  use GenServer

  @table :asas_rate_limit
  @window_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records a request for `key`.

  `opts[:window_ms]` defaults to 60s. The window is derived from wall-clock
  time rather than stored per key, which is what lets the counter be a single
  atomic operation.
  """
  @spec hit(term, pos_integer, keyword) :: {:ok, non_neg_integer} | {:error, pos_integer}
  def hit(key, limit, opts \\ []) do
    window_ms = opts[:window_ms] || @window_ms
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0})

    if count > limit do
      {:error, max(1, div((window + 1) * window_ms - now, 1000))}
    else
      {:ok, limit - count}
    end
  end

  @doc "`hit/3` as a boolean, for call sites that only gate."
  @spec allow?(term, pos_integer, keyword) :: boolean
  def allow?(key, limit, opts \\ []), do: match?({:ok, _}, hit(key, limit, opts))

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    window_ms = opts[:window_ms] || @window_ms
    :timer.send_interval(window_ms * 2, :sweep)
    {:ok, %{window_ms: window_ms}}
  end

  @impl true
  def handle_info(:sweep, %{window_ms: window_ms} = state) do
    old = div(System.system_time(:millisecond), window_ms) - 1
    # rows are {{key, window}, count}; drop anything older than the previous window.
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", old}], [true]}])
    {:noreply, state}
  end
end
