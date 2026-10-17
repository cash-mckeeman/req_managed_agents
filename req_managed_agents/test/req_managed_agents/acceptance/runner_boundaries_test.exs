defmodule ReqManagedAgents.Acceptance.RunnerBoundariesTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Context, Output, Runner, Source}
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  alias ReqManagedAgents.Test.AcceptanceAdapter

  test "record and byte ceilings preserve explicit incomplete coverage and bounded artifacts" do
    owner = self()

    for limits <- [%{"records" => 1}, %{"bytes" => 1000}] do
      context =
        agentcore_context(limits, fn _ ->
          send(owner, :invoked)

          {:ok,
           [
             %{"messageStart" => %{"role" => "assistant"}},
             %{"messageStop" => %{"stopReason" => "end_turn"}}
           ]}
        end)

      assert {:error, report} = Runner.run(context)
      assert report.outcome == :inconclusive
      assert predicate(report, "bounded_capture").outcome == :inconclusive
      assert_receive :invoked
      refute_receive :invoked
      capture = artifact(context, report)
      assert length(capture.records) <= context.config.bounds.records

      assert File.stat!(Path.join(context.root, "evidence.json")).size <=
               context.config.bounds.bytes

      assert Enum.any?(capture.diagnostics, &(&1.code in [:capture_gap, :bound_exceeded]))
      assert Enum.any?(capture.sources, &(&1.status == :partial))
    end
  end

  test "unbounded-control evidence is nonempty and native completion actually passes" do
    context =
      agentcore_context(%{}, fn _ ->
        {:ok,
         [
           %{"messageStart" => %{"role" => "assistant"}},
           %{"messageStop" => %{"stopReason" => "end_turn"}}
         ]}
      end)

    assert {:ok, report} = Runner.run(context)
    capture = artifact(context, report)
    assert Enum.count(capture.records, &(&1.kind == :native)) == 2
    assert predicate(report, "native_completion").outcome == :passed
    assert predicate(report, "bounded_capture").outcome == :passed
  end

  test "in-flight timeout preserves failure evidence and stops the owned invocation task" do
    owner = self()

    context =
      agentcore_context(%{}, fn _ ->
        send(owner, {:invoked, self()})
        receive do: (:never_sent -> {:ok, []})
      end)

    context = %{context | deadline: System.monotonic_time(:millisecond) + 200}
    assert {:error, report} = Runner.run(context)
    assert report.outcome == :failed
    assert predicate(report, "bounded_capture").outcome == :failed
    assert_receive {:invoked, worker}
    refute_receive {:invoked, _}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    assert artifact(context, report).records != []
  end

  for mode <- [:denied, :malformed, :capped] do
    @mode mode
    test "#{mode} CMA history preserves inline identity and cannot pass full coverage" do
      {context, state} = cma_context(@mode)
      assert {:error, report} = Runner.run(context)
      assert report.outcome in [:failed, :inconclusive]
      assert predicate(report, "bounded_capture").outcome != :passed
      capture = artifact(context, report)

      assert Enum.any?(
               capture.records,
               &(&1.source_id == "native" and &1.native_id == "live-terminal")
             )

      assert Enum.any?(capture.sources, &(&1.status != :complete))

      historical =
        Enum.filter(capture.records, &(&1.kind == :native and &1.source_id != "native"))

      if @mode == :capped do
        assert historical != []
        assert Enum.any?(historical, &(&1.native_id == "persisted-terminal"))
        assert Enum.all?(historical, &is_nil(&1.attempt_id))
      else
        assert historical == []
      end

      assert report.cleanup.status == :pending
      assert Enum.map(report.cleanup.owned_resources, & &1.reference) == ["owned-session"]
      requests = Agent.get(state, & &1.requests)
      assert Enum.count(requests, &(&1 == {:post, "/v1/sessions"})) == 1
      assert Enum.count(requests, &(&1 == {:get, "/v1/sessions/owned-session/events"})) == 1

      expected = [
        {:post, "/v1/sessions"},
        {:get, "/v1/sessions/owned-session/events/stream"},
        {:post, "/v1/sessions/owned-session/events"},
        {:get, "/v1/sessions/owned-session/events"}
      ]

      expected =
        if @mode == :capped,
          do: expected,
          else: expected ++ [{:get, "/v1/sessions/owned-session/threads"}]

      assert Enum.sort(requests) == Enum.sort(expected)
    end
  end

  test "drained empty CMA history remains explicitly empty beside live execution evidence" do
    {context, state} = cma_context(:empty)
    assert {:ok, report} = Runner.run(context)
    capture = artifact(context, report)

    assert Enum.any?(
             capture.records,
             &(&1.source_id == "native" and &1.native_id == "live-terminal")
           )

    historical = Enum.filter(capture.sources, &(&1.pages > 0))
    assert historical != []
    assert Enum.all?(historical, &(&1.records_seen == 0 and &1.status == :complete))
    reported = Enum.filter(report.coverage.sources, &(&1.pages > 0))
    assert reported != []
    assert Enum.all?(reported, &(&1.records_seen == 0 and &1.status == :complete))
    refute Enum.any?(capture.records, &(&1.kind == :native and &1.source_id != "native"))

    assert Enum.all?(
             predicate(report, "native_completion").evidence,
             &String.starts_with?(&1, "native:")
           )

    assert length(Agent.get(state, & &1.requests)) == 5
  end

  defp predicate(report, name), do: Enum.find(report.assertions, &(&1.name == name))

  defp artifact(context, report) do
    assert [reference] = report.artifacts
    bytes = File.read!(Path.join(context.root, reference.relative_path))
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == reference.sha256
    assert {:ok, capture} = Evidence.from_wire(Jason.decode!(bytes))
    assert Bitwise.band(File.stat!(Path.join(context.root, "report.json")).mode, 0o777) == 0o600
    capture
  end

  defp agentcore_context(limits, invoke) do
    data = base("agentcore")
    data = %{data | "bounds" => Map.merge(data["bounds"], limits)}
    context(data, invoke_fun: invoke)
  end

  defp cma_context(mode) do
    state = start_supervised!({Agent, fn -> %{stream: nil, requests: []} end})

    terminal = %{
      "id" => "live-terminal",
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "end_turn"}
    }

    adapter = fn request ->
      Agent.update(state, &%{&1 | requests: &1.requests ++ [{request.method, request.url.path}]})
      {status, body} = cma_response(request, state, terminal, mode)
      {request, Req.Response.new(status: status, body: body)}
    end

    client =
      Client.new(
        api_key: "invented",
        req_options: [
          adapter: AcceptanceAdapter,
          finch_private: %{acceptance_adapter: adapter},
          retry: false
        ]
      )

    data = base("claude-managed-agents")
    data = if mode == :capped, do: put_in(data, ["inputs", "history_pages"], 1), else: data
    {context(data, client: client), state}
  end

  defp cma_response(%{method: :post, url: %{path: "/v1/sessions"}}, _, _, _),
    do:
      {200,
       %{
         "id" => "owned-session",
         "budget" => %{
           "type" => "limit",
           "max_list_cost" => %{"amount" => "1", "currency" => "USD"}
         }
       }}

  defp cma_response(
         %{method: :get, url: %{path: "/v1/sessions/owned-session/events/stream"}},
         state,
         _,
         _
       ) do
    {pid, ref} = stream = {self(), make_ref()}
    Agent.update(state, &%{&1 | stream: stream})

    {200,
     %Req.Response.Async{
       pid: pid,
       ref: ref,
       stream_fun: fn _, {_, part} -> {:ok, [part]} end,
       cancel_fun: fn _ -> :ok end
     }}
  end

  defp cma_response(
         %{method: :post, url: %{path: "/v1/sessions/owned-session/events"}},
         state,
         terminal,
         _
       ) do
    {pid, ref} = Agent.get(state, & &1.stream)
    send(pid, {ref, {:data, "data: " <> Jason.encode!(terminal) <> "\n\n"}})
    {200, %{"data" => []}}
  end

  defp cma_response(
         %{method: :get, url: %{path: "/v1/sessions/owned-session/events"}},
         _,
         _,
         :denied
       ),
       do: {403, %{}}

  defp cma_response(
         %{method: :get, url: %{path: "/v1/sessions/owned-session/events"}},
         _,
         _,
         :malformed
       ),
       do: {200, %{"data" => "invalid"}}

  defp cma_response(
         %{method: :get, url: %{path: "/v1/sessions/owned-session/events"}},
         _,
         _,
         :capped
       ),
       do:
         {200,
          %{
            "data" => [
              %{
                "id" => "persisted-terminal",
                "type" => "session.status_idle",
                "stop_reason" => %{"type" => "end_turn"}
              }
            ],
            "next_page" => "more"
          }}

  defp cma_response(%{method: :get, url: %{path: "/v1/sessions/owned-session/threads"}}, _, _, _),
    do: {200, %{"data" => [], "has_more" => false}}

  defp cma_response(%{method: :get}, _, _, :empty),
    do: {200, %{"data" => [], "has_more" => false}}

  defp context(data, transport) do
    {:ok, config} = Config.parse(Jason.encode!(data))
    {:ok, proposal} = Acceptance.propose(config)

    {:ok, options} =
      Options.new(
        content: :retain,
        max_records: config.bounds.records,
        max_bytes: config.bounds.bytes,
        timeout_ms: config.bounds.timeout_ms
      )

    recorder = start_supervised!({Recorder, options}, id: make_ref())

    parent =
      Path.join(System.tmp_dir!(), "acceptance-boundary-#{System.unique_integer([:positive])}")

    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    root = Path.join(parent, "run")
    :ok = Output.create(root)

    source = %Source{
      revision: config.source_revision,
      tree: String.duplicate("b", 40),
      root: parent
    }

    {:ok, context} = Context.new(config, proposal, source, recorder, root, transport)
    context
  end

  defp base(provider) do
    {resource, inputs} =
      case provider do
        "agentcore" ->
          {%{
             "reference" => "arn:aws:bedrock-agentcore:us-east-1:000000000000:harness/invented",
             "region" => "us-east-1",
             "runtime_session_id" => String.duplicate("a", 33)
           },
           %{
             "prompt" => "Synthetic hello",
             "model" => nil,
             "max_tokens" => 16,
             "timeout_seconds" => 1
           }}

        "claude-managed-agents" ->
          {%{"reference" => "agent", "environment_id" => "environment"},
           %{"prompt" => "Synthetic hello", "max_list_cost_cents" => 1, "history_pages" => 2}}
      end

    %{
      "schema_version" => 1,
      "provider" => provider,
      "scenario" => "basic",
      "resource" => resource,
      "source_revision" => String.duplicate("a", 40),
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => inputs
    }
  end
end
