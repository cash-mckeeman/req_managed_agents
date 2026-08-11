defmodule ReqManagedAgents.Providers.BedrockAgentCore.WaitBudget do
  @moduledoc """
  The single wall-clock budget a `BedrockAgentCore.provision/2` call spends across
  **all** of its waits.

  One provision can wait twice — first for a same-name harness to finish deleting,
  then for the new one to reach READY. Bounding each wait by a poll *count* made
  those budgets additive and left the wall-clock cost unbounded in both directions:
  a count says nothing about how long one poll's HTTP call takes, and two counted
  waits spend two full budgets. A `%WaitBudget{}` is built once at the entry to
  `provision/2` and threaded through every wait, so `deadline_at` is one absolute
  monotonic instant that all of them share.

  ## The two budget shapes

  `:timeout` (ms) is the whole budget, and the deadline alone bounds the loops.
  The legacy `:ready_poll_ms` / `:ready_max_polls` pair is still accepted and keeps
  its count semantics, under a deadline derived from `poll_ms * (max_polls + 1)`
  — every poll the count allows, so the count is what binds — floored at the
  default. The floor matters: `ready_poll_ms: 0` means "poll as fast
  as you can, N times" — attempts, not time — and deriving a zero-length wall-clock
  budget from it would end the wait after a single poll.

  ## Why `next/1` stops early

  `next/1` returns `:poll` only while a *whole* poll interval still fits inside what
  is left, not merely while time remains. A wait must stop while it still has time
  to return its named error tuple; overrunning the deadline and being killed from
  outside is the failure this module exists to prevent.
  """

  @default_poll_ms 5_000
  @default_max_polls 72

  # The wall-clock the legacy poll opts describe at their defaults. It is the
  # floor for every derived budget, and the default when no :timeout is given.
  #
  # `max_polls + 1` because a count of N permits N+1 polls: the first is free and
  # each unit of the count buys one more. Deriving only `poll_ms * max_polls`
  # leaves the deadline expiring one poll early, which would silently shorten
  # every legacy wait the count was supposed to govern.
  @default_timeout_ms @default_poll_ms * (@default_max_polls + 1)

  @enforce_keys [:deadline_at, :poll_ms, :polls_left]
  defstruct [:deadline_at, :poll_ms, :polls_left]

  @typedoc """
  `deadline_at` is an absolute `System.monotonic_time(:millisecond)` instant, not a
  duration — it is what makes the budget shareable across two sequential waits.
  `polls_left` is `:infinity` when the caller gave an explicit `:timeout`.
  """
  @type t :: %__MODULE__{
          deadline_at: integer(),
          poll_ms: non_neg_integer(),
          polls_left: non_neg_integer() | :infinity
        }

  @typedoc "Whether a wait may poll once more, or has run out of budget."
  @type verdict :: :poll | :expired

  @doc """
  Builds the budget for one `provision/2` call from its opts, starting the clock.

  Reads `:timeout` (ms) and the legacy `:ready_poll_ms` / `:ready_max_polls`.
  Returns `{:error, {:invalid_opts, :timeout}}` for a `:timeout` that is not a
  non-negative integer — including `:infinity`, which this budget deliberately
  cannot express.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, {:invalid_opts, :timeout}}
  def new(opts) do
    poll_ms = opts[:ready_poll_ms] || @default_poll_ms
    max_polls = opts[:ready_max_polls] || @default_max_polls

    with {:ok, timeout_ms, polls_left} <- budget(opts[:timeout], poll_ms, max_polls) do
      {:ok,
       %__MODULE__{
         deadline_at: System.monotonic_time(:millisecond) + timeout_ms,
         poll_ms: poll_ms,
         polls_left: polls_left
       }}
    end
  end

  # An explicit :timeout drops the legacy count rather than silently capping a
  # caller who asked for more time than 72 polls happen to describe.
  defp budget(ms, _poll_ms, _max_polls) when is_integer(ms) and ms >= 0, do: {:ok, ms, :infinity}

  defp budget(nil, poll_ms, max_polls),
    do: {:ok, max(poll_ms * (max_polls + 1), @default_timeout_ms), max_polls}

  defp budget(_other, _poll_ms, _max_polls), do: {:error, {:invalid_opts, :timeout}}

  @doc "Milliseconds left before the deadline; negative once it has passed."
  @spec remaining(t()) :: integer()
  def remaining(%__MODULE__{deadline_at: at}), do: at - System.monotonic_time(:millisecond)

  @doc """
  Whether the wait may sleep and poll once more.

  `:poll` requires both that the legacy count is not exhausted and that a whole
  `poll_ms` sleep fits inside the time left.
  """
  @spec next(t()) :: verdict()
  def next(%__MODULE__{poll_ms: poll_ms} = budget) do
    if polls_left?(budget.polls_left) and remaining(budget) > poll_ms,
      do: :poll,
      else: :expired
  end

  defp polls_left?(:infinity), do: true
  defp polls_left?(n), do: n > 0

  @doc "Records one poll against the legacy count. A `:timeout`-shaped budget is unchanged."
  @spec spend(t()) :: t()
  def spend(%__MODULE__{polls_left: :infinity} = budget), do: budget
  def spend(%__MODULE__{polls_left: n} = budget), do: %{budget | polls_left: n - 1}

  @doc """
  The `receive_timeout` one HTTP attempt of a poll may use.

  Bounded by the smaller of the client's configured timeout and what is left of the
  budget, then divided by `attempts` — the poll's transport retries the request, so
  a per-attempt timeout equal to the whole remaining budget would let one hung poll
  spend it several times over. Never returns less than 1: a poll on a spent budget
  degrades to "try once, briefly", and a non-positive `receive_timeout` is rejected
  by the transport.
  """
  @spec attempt_timeout(t(), timeout(), pos_integer()) :: pos_integer()
  def attempt_timeout(%__MODULE__{} = budget, :infinity, attempts),
    do: per_attempt(remaining(budget), attempts)

  def attempt_timeout(%__MODULE__{} = budget, configured, attempts)
      when is_integer(configured),
      do: per_attempt(min(configured, remaining(budget)), attempts)

  defp per_attempt(ms, attempts) when is_integer(attempts) and attempts > 0,
    do: max(div(ms, attempts), 1)
end
