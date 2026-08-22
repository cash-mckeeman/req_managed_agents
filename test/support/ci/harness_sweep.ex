defmodule ReqManagedAgents.CI.HarnessSweep do
  @moduledoc """
  Reclaims the Bedrock AgentCore harnesses the live canary left allocated.

  This is CI tooling, not consumer surface, so it lives under `test/support`
  and never ships in the package. It is a module rather than a script inlined
  in the workflow because it issues `DeleteHarness` against a real account:
  here every decision it makes is formatted, linted, typed and pinned by a
  test.

  `DeleteHarness` is asynchronous, so a name match alone cannot mean "leaked".
  A successful run's own teardown returns on the 2xx while its harnesses are
  still `DELETING`; reclaiming those would re-delete a resource that is already
  going away and would report a leak on every green run. `DELETE_FAILED` is the
  status that actually strands one.

  `ListHarnesses` is paginated and this reads one page — the client grows no
  `nextToken` loop here, since that is library behaviour with its own callers.
  What the sweep owes its reader instead is honesty: a truncated listing sets
  `Report.complete?` to false, and nothing downstream may call the account
  clean without it.
  """

  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.CI.HarnessSweep.Report
  alias ReqManagedAgents.Providers.BedrockAgentCore.HarnessStatus

  @prefix "rma_live"

  @typedoc """
  Seams and knobs. `:list_fun` / `:delete_fun` keep the default suite off the
  network; `:prefix` exists for tests only — the canary always sweeps `prefix/0`.
  """
  @type option ::
          {:list_fun, (-> {:ok, map()} | {:error, term()})}
          | {:delete_fun, (String.t() -> {:ok, map()} | {:error, term()})}
          | {:prefix, String.t()}
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
  Lists the account's harnesses and deletes the leaked ones.

  Never raises on a provider error: a sweep that crashes reports nothing, and
  the report is the only durable record of what was left allocated.
  """
  @spec run([option()]) :: Report.t()
  def run(opts \\ []) do
    list_fun = opts[:list_fun] || default_list_fun(opts)
    delete_fun = opts[:delete_fun] || default_delete_fun(opts)
    prefix = opts[:prefix] || @prefix

    case list_fun.() do
      {:ok, %{"harnesses" => harnesses} = body} when is_list(harnesses) ->
        harnesses
        |> Enum.filter(&matches?(&1, prefix))
        |> reclaim(delete_fun, complete?(body))

      {:ok, other} ->
        list_failure({:unexpected_list_shape, other})

      {:error, reason} ->
        list_failure({:list_harnesses_failed, reason})
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
    prefix = opts[:prefix] || @prefix

    IO.puts("sweep: #{length(report.matched)} harness(es) matching #{prefix}*")

    Enum.each(report.skipped, fn h ->
      IO.puts("sweep: #{name(h)} is #{status(h)} — a teardown already in flight, not a leak")
    end)

    Enum.each(report.reclaimed, fn h ->
      IO.puts("::warning::reclaimed leaked harness #{name(h)} (#{id(h)}, status #{status(h)})")
    end)

    Enum.each(report.unreclaimed, fn {h, reason} ->
      IO.puts("SWEEP_UNRECLAIMED #{label(h)} #{inspect(reason)}")
    end)

    unless report.complete? do
      IO.puts(
        "::warning::SWEEP_INCOMPLETE the harness listing was truncated or failed, so only " <>
          "part of the account was scanned — an orphan outside it was neither seen nor reclaimed"
      )
    end

    :ok
  end

  # A `nextToken` means the account holds more harnesses than this page shows.
  defp complete?(body), do: not is_binary(Map.get(body, "nextToken"))

  defp from_status(status) do
    case HarnessStatus.classify(status) do
      :terminating -> :skip
      _ -> :reclaim
    end
  end

  defp reclaim(matched, delete_fun, complete?) do
    {leaked, skipped} = Enum.split_with(matched, &(action(&1) == :reclaim))
    {reclaimed, unreclaimed} = Enum.reduce(leaked, {[], []}, &delete_one(&1, &2, delete_fun))

    %Report{
      matched: matched,
      skipped: skipped,
      reclaimed: Enum.reverse(reclaimed),
      unreclaimed: Enum.reverse(unreclaimed),
      complete?: complete?
    }
  end

  defp delete_one(harness, {reclaimed, unreclaimed}, delete_fun) do
    case delete_fun.(id(harness)) do
      {:ok, _} -> {[harness | reclaimed], unreclaimed}
      {:error, reason} -> {reclaimed, [{harness, reason} | unreclaimed]}
      other -> {reclaimed, [{harness, {:unexpected_delete_result, other}} | unreclaimed]}
    end
  end

  # A listing that never arrived establishes nothing about the account either.
  defp list_failure(reason) do
    %Report{
      matched: [],
      skipped: [],
      reclaimed: [],
      unreclaimed: [{nil, reason}],
      complete?: false
    }
  end

  defp matches?(harness, prefix), do: String.starts_with?(name(harness), prefix)

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
