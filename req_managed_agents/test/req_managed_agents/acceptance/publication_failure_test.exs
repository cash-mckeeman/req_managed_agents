defmodule ReqManagedAgents.Acceptance.PublicationFailureTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.{Config, Context, Output, Runner, Source}
  alias ReqManagedAgents.Evidence.{Options, Recorder}
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client

  test "CMA artifact collision preserves created-session ownership and never invokes again" do
    parent = Path.join(System.tmp_dir!(), "cma-publication-#{System.unique_integer([:positive])}")
    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    out = Path.join(parent, "run")
    revision = String.duplicate("a", 40)

    data = %{
      "schema_version" => 1,
      "provider" => "claude-managed-agents",
      "scenario" => "basic",
      "resource" => %{"reference" => "agent", "environment_id" => "environment"},
      "source_revision" => revision,
      "retain_until" => "2099-01-01T00:00:00Z",
      "content" => "drop",
      "bounds" => %{"calls" => 1, "records" => 100, "bytes" => 100_000, "timeout_ms" => 1000},
      "inputs" => %{
        "prompt" => "Synthetic hello",
        "max_list_cost_cents" => 1,
        "history_pages" => 2
      }
    }

    {:ok, config} = Config.parse(Jason.encode!(data))
    state = start_supervised!({Agent, fn -> %{creates: 0, stream: nil} end})

    terminal = %{
      "id" => "terminal",
      "type" => "session.status_idle",
      "stop_reason" => %{"type" => "end_turn"}
    }

    adapter = fn request ->
      body =
        case {request.method, request.url.path} do
          {:post, "/v1/sessions"} ->
            Agent.update(state, &%{&1 | creates: &1.creates + 1})

            %{
              "id" => "owned-created-session",
              "budget" => %{
                "type" => "limit",
                "max_list_cost" => %{"amount" => "1", "currency" => "USD"}
              }
            }

          {:get, "/v1/sessions/owned-created-session/events/stream"} ->
            stream = {self(), make_ref()}
            Agent.update(state, &%{&1 | stream: stream})
            {pid, ref} = stream

            %Req.Response.Async{
              pid: pid,
              ref: ref,
              stream_fun: fn _, {_, part} -> {:ok, [part]} end,
              cancel_fun: fn _ -> :ok end
            }

          {:post, "/v1/sessions/owned-created-session/events"} ->
            {pid, ref} = Agent.get(state, & &1.stream)
            send(pid, {ref, {:data, "data: " <> Jason.encode!(terminal) <> "\n\n"}})
            %{"data" => []}

          {:get, "/v1/sessions/owned-created-session/events"} ->
            %{"data" => [terminal], "has_more" => false}

          {:get, "/v1/sessions/owned-created-session/threads"} ->
            File.write!(Path.join(out, "evidence.json"), "foreign original")
            %{"data" => [], "has_more" => false}
        end

      {request, Req.Response.new(status: 200, body: body)}
    end

    client =
      Client.new(
        api_key: "invented",
        req_options: [
          adapter: ReqManagedAgents.Test.AcceptanceAdapter,
          finch_private: %{acceptance_adapter: adapter},
          retry: false
        ]
      )

    {:ok, proposal} = Acceptance.propose(config)

    {:ok, options} =
      Options.new(
        content: :retain,
        max_bytes: config.bounds.bytes,
        timeout_ms: config.bounds.timeout_ms
      )

    recorder = start_supervised!({Recorder, options})
    {:ok, source} = source_fixture(config, parent)
    {:ok, context} = Context.new(config, proposal, source, recorder, out, client: client)
    :ok = Output.create(out)
    {:error, report} = Runner.run(context)
    assert Agent.get(state, & &1.creates) == 1
    assert File.read!(Path.join(out, "evidence.json")) == "foreign original"

    assert report.cleanup.status == :pending
    assert Enum.map(report.cleanup.owned_resources, & &1.reference) == ["owned-created-session"]
    wire = out |> Path.join("report.json") |> File.read!() |> Jason.decode!()
    assert wire["cleanup"]["status"] == "pending"

    assert wire["cleanup"]["owned_resources"] == [
             %{"kind" => "claude_session", "reference" => "owned-created-session"}
           ]
  end

  defp source_fixture(config, root) do
    {:ok, %Source{revision: config.source_revision, tree: String.duplicate("b", 40), root: root}}
  end
end
