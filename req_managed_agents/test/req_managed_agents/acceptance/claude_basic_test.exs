defmodule ReqManagedAgents.Acceptance.ClaudeBasicTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Context, Source}
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
