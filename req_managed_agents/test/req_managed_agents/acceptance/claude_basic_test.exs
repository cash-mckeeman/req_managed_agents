defmodule ReqManagedAgents.Acceptance.ClaudeBasicTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance

  alias ReqManagedAgents.Acceptance.{
    Cleanup,
    Config,
    Consumption,
    Context,
    Coverage,
    Report,
    Source
  }

  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Acceptance, as: CMA
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  alias ReqManagedAgents.Test.AcceptanceAdapter

  test "fresh native CMA open, stream, prompt and bounded history retain separate sources" do
    owner = self()

    terminal = %{
      "id" => "terminal",
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "end_turn"}
    }

    {:ok, state} = start_supervised({Agent, fn -> nil end})

    adapter = fn request ->
      send(owner, {:request, request.method, request.url.path})

      body =
        case {request.method, request.url.path} do
          {:post, "/v1/sessions"} ->
            %{
              "id" => "session",
              "budget" => %{
                "type" => "limit",
                "max_list_cost" => %{"amount" => "1", "currency" => "USD"}
              }
            }

          {:get, "/v1/sessions/session/events/stream"} ->
            stream = {self(), make_ref()}
            Agent.update(state, fn _ -> stream end)
            async_response(stream)

          {:post, "/v1/sessions/session/events"} ->
            {pid, ref} = Agent.get(state, & &1)
            send(pid, {ref, {:data, "data: " <> Jason.encode!(terminal) <> "\n\n"}})
            %{"data" => []}

          {:get, "/v1/sessions/session/events"} ->
            %{"data" => [terminal], "has_more" => false}

          {:get, "/v1/sessions/session/threads"} ->
            %{"data" => [], "has_more" => false}
        end

      {request, Req.Response.new(status: 200, body: body)}
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

    context = context(client)

    assert {:ok, observations} =
             CMA.run(context)

    assertions =
      CMA.assess(context, observations)

    assert Enum.map(assertions, & &1.outcome) == [:passed, :passed, :passed]
    assert_receive {:request, :post, "/v1/sessions"}
    assert_receive {:request, :get, "/v1/sessions/session/events/stream"}
    assert_receive {:request, :post, "/v1/sessions/session/events"}
    assert_receive {:request, :get, "/v1/sessions/session/events"}
    assert_receive {:request, :get, "/v1/sessions/session/threads"}
    refute_receive {:request, _, _}
    capture = List.last(observations).capture
    assert Enum.any?(capture.sources, &(&1.pages > 0))
    assert Enum.any?(capture.records, &(&1.source_id == "native"))
    assert Enum.any?(capture.records, &(&1.source_id != "native" and &1.kind == :native))
  end

  test "budget mismatch retains exact owned session cleanup without echoed private bodies" do
    owner = self()

    for {status, expected} <- [{200, :complete}, {500, :pending}] do
      adapter = fn request ->
        send(owner, {:budget_request, request.url.path})

        case request.url.path do
          "/v1/sessions" ->
            {request,
             Req.Response.new(
               status: 200,
               body: %{
                 "id" => "created-session",
                 "budget" => %{"private" => "PRIVATE_ECHO_SENTINEL"}
               }
             )}

          "/v1/sessions/created-session/archive" ->
            {request, Req.Response.new(status: status, body: %{})}
        end
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

      context = context(client)
      assert {:error, :execution_failed, observations} = CMA.run(context)
      cleanup = List.last(observations).cleanup
      assert cleanup.status == expected
      assert Enum.map(cleanup.owned_resources, & &1.reference) == ["created-session"]
      refute inspect(observations) =~ "PRIVATE_ECHO_SENTINEL"
      {:ok, capture} = Recorder.snapshot(context.recorder)
      {:ok, coverage} = Coverage.new(context.config, capture, observations)
      {:ok, consumed} = Consumption.new(capture, 0)
      {:ok, cleanup} = Cleanup.from_observations(context.config, capture, observations)

      {:ok, report} =
        Report.new(%{
          context: context,
          assertions: CMA.assess(context, observations),
          coverage: coverage,
          consumed: consumed,
          cleanup: cleanup,
          artifacts: []
        })

      wire = report |> Report.to_wire() |> Jason.encode!()
      assert wire =~ "created-session"
      refute wire =~ "PRIVATE_ECHO_SENTINEL"
      output = ExUnit.CaptureIO.capture_io(fn -> Mix.shell().info(wire) end)
      assert output =~ "created-session"
      refute output =~ "PRIVATE_ECHO_SENTINEL"
      assert_receive {:budget_request, "/v1/sessions"}
      assert_receive {:budget_request, "/v1/sessions/created-session/archive"}
      refute_receive {:budget_request, _}
      stop_supervised(Recorder)
    end
  end

  defp context(client) do
    data = %{
      "schema_version" => 1,
      "provider" => "claude-managed-agents",
      "scenario" => "basic",
      "resource" => %{"reference" => "agent", "environment_id" => "environment"},
      "source_revision" => String.duplicate("a", 40),
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => %{"prompt" => "Say hello", "max_list_cost_cents" => 1, "history_pages" => 2}
    }

    {:ok, config} = Config.parse(Jason.encode!(data))
    {:ok, proposal} = Acceptance.propose(config)
    {:ok, options} = Options.new(content: :retain, max_bytes: 100_000)
    recorder = start_supervised!({Recorder, options})
    root = System.tmp_dir!()

    source = %Source{
      revision: config.source_revision,
      tree: String.duplicate("b", 40),
      root: root
    }

    {:ok, context} = Context.new(config, proposal, source, recorder, root, client: client)
    context
  end

  defp async_response({pid, ref}) do
    %Req.Response.Async{
      pid: pid,
      ref: ref,
      stream_fun: fn
        _, {_, {:error, reason}} -> {:error, reason}
        _, {_, part} -> {:ok, [part]}
      end,
      cancel_fun: fn _ -> :ok end
    }
  end
end
