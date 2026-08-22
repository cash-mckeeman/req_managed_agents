defmodule ReqManagedAgents.CI.HarnessSweep do
  @moduledoc """
  Reclaims the Bedrock AgentCore harnesses the live canary left allocated.

  This is CI tooling, not consumer surface, so it lives under `test/support`
  and never ships in the package. It is a module rather than a script inlined
  in the workflow because it issues `DeleteHarness` against a real account:
  here every decision it makes is formatted, linted, typed and pinned by a
  test.

  Three properties of the AgentCore control plane shape everything below.

    * `DeleteHarness` is asynchronous, so a name match alone cannot mean
      "leaked". A successful run's own teardown returns on the 2xx while its
      harnesses are still `DELETING`; reclaiming those would re-delete a
      resource already going away and would report a leak on every green run.
      `DELETE_FAILED` is the status that actually strands one.
    * A 2xx from `DeleteHarness` is an acceptance, not a deletion — the harness
      can still land in `DELETE_FAILED`. Nothing is counted as reclaimed until
      a later listing no longer shows it.
    * `ListHarnesses` is paginated and this reads one page. The client grows no
      `nextToken` loop here: that is library behaviour with its own callers.
      What the sweep owes its reader instead is honesty — a truncated listing
      sets `Report.complete?` to false, and nothing downstream may call the
      account clean without it.
  """

  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.CI.HarnessSweep.Report
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatus

  # The separator is part of the prefix. `Name.compose/3` keeps 24 bytes of base
  # before the truncation hash and every canary base begins `rma_live_` (9
  # bytes), so no harness this project ever created — however old its naming
  # scheme — can have lost it. Matching bare `rma_live` buys nothing and would
  # claim an unrelated `rma_liveness_probe`.
  @prefix "rma_live_"

  # Bounds the post-delete confirmation. Only paid when something was actually
  # reclaimed: a run whose own teardown worked reaches the confirm loop with
  # nothing pending.
  @confirm_attempts 6
  @confirm_interval_ms 10_000

  @typedoc """
  Seams and knobs. `:list_fun`, `:delete_fun` and `:sleep_fun` keep the default
  suite off the network and off the clock; the confirm bounds are tunable so a
  test does not have to wait out the real budget.
  """
  @type option ::
          {:list_fun, (-> {:ok, map()} | {:error, term()})}
          | {:delete_fun, (String.t() -> {:ok, map()} | {:error, term()})}
          | {:sleep_fun, (non_neg_integer() -> any())}
          | {:confirm_attempts, pos_integer()}
          | {:confirm_interval_ms, non_neg_integer()}
          | {:client, Client.t()}

  @doc "The harness-name prefix the canary owns."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Whether a listed harness is a leak this sweep should reclaim.

  `:skip` is reserved for a teardown already in flight. Every other status —
  `READY`, `CREATING`, a `*_FAILED`, or one this library does not recognise —
  is a harness still billing after the suite finished, which is the whole
  reason the step exists.
  """
  @spec action(Report.harness()) :: :reclaim | :skip
  def action(harness) when is_map(harness) do
    case Map.get(harness, "status") do
      status when is_binary(status) -> from_status(status)
      _ -> :reclaim
    end
  end

  @doc """
  Lists the account's harnesses, deletes the leaked ones and confirms they went.

  Never raises on a provider error: a sweep that crashes reports nothing, and
  the report is the only durable record of what was left allocated.
  """
  @spec run([option()]) :: Report.t()
  def run(opts \\ []) do
    ctx = context(opts)

    case ctx.list_fun.() do
      {:ok, body} when is_map(body) -> sweep_page(body, ctx)
      {:ok, other} -> list_failure({:unexpected_list_shape, other})
      {:error, reason} -> list_failure({:list_harnesses_failed, reason})
    end
  end

  @doc """
  Runs the sweep and prints its report to stdout.

  Two markers are machine-read by the workflow step and must keep their
  spelling: `SWEEP_UNRECLAIMED` at the start of a line is a harness still
  allocated, and the step fails on it; `SWEEP_INCOMPLETE` is a sweep that
  cannot vouch for the account, and the step stays green but says so.
  """
  @spec main([option()]) :: :ok
  def main(opts \\ []) do
    report = run(opts)

    IO.puts("sweep: #{length(report.matched)} harness(es) matching #{@prefix}*")
    Enum.each(report.skipped, &IO.puts(skipped_line(&1)))
    Enum.each(report.reclaimed, &IO.puts(reclaimed_line(&1)))
    Enum.each(report.unconfirmed, &IO.puts(unconfirmed_line(&1)))
    Enum.each(report.unreclaimed, fn {h, why} -> IO.puts(unreclaimed_line(h, why)) end)

    unless report.complete? do
      IO.puts(
        "::warning::SWEEP_INCOMPLETE the harness listing was truncated or failed, so only " <>
          "part of the account was scanned — an orphan outside it was neither seen nor reclaimed"
      )
    end

    :ok
  end

  defp skipped_line(harness),
    do: "sweep: #{name(harness)} is #{status(harness)} — a teardown already in flight, not a leak"

  defp reclaimed_line(harness),
    do: "::warning::reclaimed leaked harness #{name(harness)} (#{id(harness)}) — confirmed gone"

  defp unconfirmed_line(harness) do
    "::warning::SWEEP_INCOMPLETE #{name(harness)} (#{id(harness)}) accepted DeleteHarness " <>
      "but was still deleting when the confirm budget ran out — not confirmed gone"
  end

  defp unreclaimed_line(harness, why),
    do: "SWEEP_UNRECLAIMED #{label(harness)} #{inspect(why)}"

  defp context(opts) do
    %{
      list_fun: opts[:list_fun] || default_list_fun(opts),
      delete_fun: opts[:delete_fun] || default_delete_fun(opts),
      sleep_fun: opts[:sleep_fun] || (&Process.sleep/1),
      attempts: opts[:confirm_attempts] || @confirm_attempts,
      interval_ms: opts[:confirm_interval_ms] || @confirm_interval_ms
    }
  end

  # Several AWS list APIs omit the collection key entirely when it is empty, so
  # an absent "harnesses" is an account holding none — the one outcome the sweep
  # most wants, and previously the one it reported as an unreclaimable failure.
  defp sweep_page(body, ctx) do
    case Map.get(body, "harnesses", []) do
      harnesses when is_list(harnesses) ->
        harnesses
        |> Enum.filter(&mine?/1)
        |> reclaim(ctx, complete?(body))

      other ->
        list_failure({:unexpected_list_shape, %{"harnesses" => other}})
    end
  end

  # A `nextToken` means the account holds more harnesses than this page shows.
  defp complete?(body), do: not is_binary(Map.get(body, "nextToken"))

  defp from_status(status) do
    case HarnessStatus.classify(status) do
      :terminating -> :skip
      _ -> :reclaim
    end
  end

  defp reclaim(matched, ctx, complete?) do
    {leaked, skipped} = Enum.split_with(matched, &(action(&1) == :reclaim))
    {accepted, rejected} = Enum.reduce(leaked, {[], []}, &delete_one(&1, &2, ctx.delete_fun))
    {gone, unconfirmed, present, saw_whole_account?} = confirm(Enum.reverse(accepted), ctx)

    %Report{
      matched: matched,
      skipped: skipped,
      reclaimed: gone,
      unconfirmed: unconfirmed,
      unreclaimed: Enum.reverse(rejected) ++ Enum.map(present, &{&1, :present_after_delete}),
      complete?: complete? and saw_whole_account?
    }
  end

  defp delete_one(harness, {accepted, rejected}, delete_fun) do
    case delete_fun.(id(harness)) do
      {:ok, _} -> {[harness | accepted], rejected}
      {:error, reason} -> {accepted, [{harness, reason} | rejected]}
      other -> {accepted, [{harness, {:unexpected_delete_result, other}} | rejected]}
    end
  end

  # Re-lists until every accepted delete has either disappeared or stopped being
  # `DELETING`. A 2xx only said the request was taken; a harness that lands in
  # `DELETE_FAILED` is still allocated and still billing, and calling that
  # "deleted" is the assumption this loop exists to replace with evidence.
  defp confirm([], _ctx), do: {[], [], [], true}

  defp confirm(accepted, ctx) do
    Enum.reduce_while(1..ctx.attempts, {[], accepted, [], true}, fn _attempt, _acc ->
      ctx.sleep_fun.(ctx.interval_ms)
      settle(accepted, ctx)
    end)
  end

  defp settle(accepted, ctx) do
    with {:ok, body} when is_map(body) <- ctx.list_fun.(),
         page when is_list(page) <- Map.get(body, "harnesses", []) do
      partition(accepted, page, complete?(body))
    else
      _ -> {:halt, {[], accepted, [], false}}
    end
  end

  defp partition(accepted, page, complete?) do
    statuses = Map.new(page, &{id(&1), status(&1)})
    {present, absent} = Enum.split_with(accepted, &Map.has_key?(statuses, id(&1)))

    {deleting, stuck} =
      Enum.split_with(present, fn h ->
        HarnessStatus.classify(Map.get(statuses, id(h), "")) == :terminating
      end)

    # A truncated page cannot prove absence — the harness may simply be on
    # another one. Absence counts as evidence only when the page was whole.
    {gone, pending} = if complete?, do: {absent, deleting}, else: {[], deleting ++ absent}

    verdict(gone, pending, stuck, complete?)
  end

  defp verdict(gone, [], stuck, complete?), do: {:halt, {gone, [], stuck, complete?}}
  defp verdict(gone, pending, stuck, complete?), do: {:cont, {gone, pending, stuck, complete?}}

  # A listing that never arrived establishes nothing about the account either.
  defp list_failure(reason) do
    %Report{
      matched: [],
      skipped: [],
      reclaimed: [],
      unconfirmed: [],
      unreclaimed: [{nil, reason}],
      complete?: false
    }
  end

  defp mine?(harness), do: String.starts_with?(name(harness), @prefix)

  defp name(harness), do: string(harness, "harnessName")
  defp id(harness), do: string(harness, "harnessId")
  defp status(harness), do: string(harness, "status")

  defp string(harness, key) do
    case Map.get(harness, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp label(nil), do: "ListHarnesses"
  defp label(harness), do: "#{name(harness)} #{id(harness)}"

  defp default_list_fun(opts) do
    client = client(opts)
    fn -> Client.list_harnesses(client) end
  end

  defp default_delete_fun(opts) do
    client = client(opts)
    fn id -> Client.delete_harness(client, id) end
  end

  defp client(opts), do: opts[:client] || Client.new()
end
