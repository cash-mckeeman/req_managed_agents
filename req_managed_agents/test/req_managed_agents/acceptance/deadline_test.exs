defmodule ReqManagedAgents.Acceptance.DeadlineTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Acceptance
  alias ReqManagedAgents.Acceptance.Config
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: Managed
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Client
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.Test.AcceptanceAdapter

  @budget %{
    "type" => "limit",
    "max_list_cost" => %{"amount" => "1", "currency" => "USD"}
  }

  test "an expired or invalid absolute deadline refuses provider activity" do
    owner = self()

    client =
      client(fn request ->
        send(owner, :request)
        {request, Req.Response.new(status: 503, body: %{})}
      end)

    for deadline <- [nil, :infinity, "100", 1.5] do
      assert {:error, {:invalid_opts, :deadline}} =
               Session.run(Managed, options(client, deadline))
    end

    assert {:error, :timeout} =
             Session.run(Managed, options(client, now() - 1))

    refute_receive :request
  end

  test "the absolute deadline includes a blocked provider open" do
    owner = self()

    client =
      client(fn request ->
        send(owner, {:creating, self()})
        Process.sleep(700)
        {request, Req.Response.new(status: 503, body: %{})}
      end)

    started = now()
    assert {:error, :timeout} = Session.run(Managed, options(client, started + 200))
    assert now() - started < 350
    assert_receive {:creating, session}
    assert_dead(session)
    refute_receive {:creating, _}
  end

  test "timeout reaps a session blocked sending its kickoff and its stream consumer" do
    owner = self()

    client =
      client(fn request ->
        case {request.method, request.url.path} do
          {:post, "/v1/sessions"} ->
            response(request, %{"id" => "owned-session"})

          {:get, "/v1/sessions/owned-session/events/stream"} ->
            send(owner, {:consumer, self()})
            response(request, async_response())

          {:post, "/v1/sessions/owned-session/events"} ->
            send(owner, {:kickoff, self()})
            Process.sleep(700)
            response(request, %{})
        end
      end)

    started = now()
    assert {:error, :timeout} = Session.run(Managed, options(client, started + 200))
    assert now() - started < 350
    assert_receive {:kickoff, session}
    assert_receive {:consumer, consumer}
    assert_dead(session)
    assert_dead(consumer)
    refute_receive {:kickoff, _}
  end

  test "public acceptance shares one deadline across sequential native requests" do
    owner = self()
    created = Req.Response.new(status: 200, body: %{"id" => "owned-session", "budget" => @budget})
    prompted = Req.Response.new(status: 200, body: %{})
    streaming = Req.Response.new(status: 200, body: async_response())

    client =
      client(fn request ->
        send(owner, {:request, request.method, request.url.path, self(), now()})

        prepared =
          case {request.method, request.url.path} do
            {:post, "/v1/sessions"} ->
              :erlang.trace(self(), true, [:procs, :monotonic_timestamp, {:tracer, owner}])
              Process.sleep(600)
              created

            {:get, "/v1/sessions/owned-session/events/stream"} ->
              %{streaming | body: %{streaming.body | pid: self()}}

            {:post, "/v1/sessions/owned-session/events"} ->
              Process.sleep(600)
              prompted
          end

        {request, prepared}
      end)

    assert {:error, report} = execute(client, 1000)
    assert report.outcome == :failed
    assert report.cleanup.status == :pending
    assert Enum.map(report.cleanup.owned_resources, & &1.reference) == ["owned-session"]
    assert_receive {:request, :post, "/v1/sessions", session, started}
    assert_receive {:request, :get, "/v1/sessions/owned-session/events/stream", consumer, _}
    assert_receive {:request, :post, "/v1/sessions/owned-session/events", ^session, _}
    assert_dead(session)
    assert_dead(consumer)
    refute_receive {:request, _, _, _, _}
    assert_receive {:trace_ts, ^session, :exit, _reason, ended}
    assert System.convert_time_unit(ended, :native, :millisecond) - started < 1400
  end

  test "interrupted creation reports unknown ownership without a guessed resource" do
    owner = self()

    client =
      client(fn request ->
        send(owner, {:creating, self(), now()})
        Process.sleep(700)
        {request, Req.Response.new(status: 503, body: %{})}
      end)

    assert {:error, report} = execute(client)
    finished = now()
    assert_receive {:creating, session, started}
    assert finished - started < 350
    assert_dead(session)
    assert report.cleanup.status == :unknown
    assert report.cleanup.owned_resources == []
    assert report.consumed.invocations == nil
    refute_receive {:creating, _, _}
  end

  test "blocked budget rollback preserves the known session and reaps its one archive worker" do
    owner = self()

    client =
      client(fn request ->
        send(owner, {:request, request.method, request.url.path, self(), now()})

        case request.url.path do
          "/v1/sessions" ->
            response(request, %{"id" => "owned-session"})

          "/v1/sessions/owned-session/archive" ->
            Process.sleep(700)
            response(request, %{})
        end
      end)

    assert {:error, report} = execute(client)
    finished = now()
    assert_receive {:request, :post, "/v1/sessions", session, started}
    assert finished - started < 350
    assert_receive {:request, :post, "/v1/sessions/owned-session/archive", worker, _}
    assert_dead(session)
    assert_dead(worker)
    assert report.cleanup.status == :pending
    assert Enum.map(report.cleanup.owned_resources, & &1.reference) == ["owned-session"]
    assert report.consumed.invocations == nil
    refute_receive {:request, _, _, _, _}
  end

  test "deadline rollback worker is reaped when its open caller dies" do
    owner = self()

    client =
      client(fn request ->
        case request.url.path do
          "/v1/sessions" ->
            response(request, %{"id" => "owned-session"})

          "/v1/sessions/owned-session/archive" ->
            send(owner, {:archive_worker, self()})
            Process.sleep(700)
            response(request, %{})
        end
      end)

    caller =
      spawn(fn ->
        Managed.open(options(client, now() + 5000) ++ [budget: %{max_list_cost_cents: 1}], self())
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:archive_worker, worker}
    monitor = Process.monitor(worker)
    on_exit(fn -> Process.exit(worker, :kill) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 150
  end

  test "public acceptance reaps its archive worker even while the request guard is suspended" do
    owner = self()
    {:ok, suspended} = Agent.start(fn -> nil end)
    on_exit(fn -> cleanup_suspended_archive(suspended) end)

    client =
      client(fn request ->
        send(owner, {:rollback_request, request.url.path})

        case request.url.path do
          "/v1/sessions" ->
            response(request, %{"id" => "owned-session"})

          "/v1/sessions/owned-session/archive" ->
            {:links, [guard]} = Process.info(self(), :links)
            worker = self()
            Agent.update(suspended, fn _ -> {worker, guard} end)
            :erlang.suspend_process(guard)
            send(owner, {:suspended_archive, self(), guard})
            receive do: (:release_archive -> response(request, %{}))
        end
      end)

    assert {:error, report} = execute(client)
    assert_receive {:suspended_archive, worker, guard}

    refute Process.alive?(worker)
    assert_dead(guard)
    assert report.cleanup.status == :pending
    assert Enum.map(report.cleanup.owned_resources, & &1.reference) == ["owned-session"]
    assert_receive {:rollback_request, "/v1/sessions"}
    assert_receive {:rollback_request, "/v1/sessions/owned-session/archive"}
    refute_receive {:rollback_request, _}
  end

  defp cleanup_suspended_archive(state) do
    case Agent.get(state, & &1) do
      {worker, guard} ->
        Process.exit(worker, :kill)
        assert_dead(worker)

        assert_dead(guard)

      nil ->
        :ok
    end
  after
    Agent.stop(state)
  end

  test "caller death reaps a deadline session during provider initialization" do
    owner = self()

    client =
      client(fn request ->
        send(owner, {:creating, self()})
        Process.sleep(700)
        {request, Req.Response.new(status: 503, body: %{})}
      end)

    caller = spawn(fn -> Session.run(Managed, options(client, now() + 5000)) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:creating, session}
    monitor = Process.monitor(session)
    on_exit(fn -> Process.exit(session, :kill) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, _}, 150
  end

  defp execute(client, timeout_ms \\ 200) do
    root = Path.expand("../../../..", __DIR__)

    {revision, 0} =
      if File.dir?(Path.join(root, ".jj")) do
        System.cmd("jj", [
          "--ignore-working-copy",
          "-R",
          root,
          "log",
          "-r",
          "@",
          "--no-graph",
          "-T",
          "if(empty, parents.map(|c| c.commit_id()).join(\" \"), commit_id)"
        ])
      else
        System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
      end

    parent =
      Path.join(System.tmp_dir!(), "acceptance-deadline-#{System.unique_integer([:positive])}")

    File.mkdir!(parent)
    File.chmod!(parent, 0o700)
    out = Path.join(parent, "run")
    on_exit(fn -> File.rm_rf!(parent) end)

    {:ok, config} =
      Config.parse(
        Jason.encode!(%{
          "schema_version" => 1,
          "provider" => "claude-managed-agents",
          "scenario" => "basic",
          "resource" => %{"reference" => "agent", "environment_id" => "environment"},
          "source_revision" => String.trim(revision),
          "retain_until" => "2099-01-01T00:00:00Z",
          "content" => "drop",
          "bounds" => %{
            "calls" => 1,
            "records" => 100,
            "bytes" => 100_000,
            "timeout_ms" => timeout_ms
          },
          "inputs" => %{"prompt" => "Say hello", "max_list_cost_cents" => 1, "history_pages" => 2}
        })
      )

    result =
      Acceptance.run(config,
        out: out,
        execute: config.digest,
        approval_ref: "offline-test",
        transport: [client: client]
      )

    assert_artifacts(result, out)
    result
  end

  defp assert_artifacts({_, %{artifacts: artifacts} = report}, out) do
    for artifact <- artifacts do
      bytes = File.read!(Path.join(out, artifact.relative_path))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == artifact.sha256
      assert {:ok, capture} = bytes |> Jason.decode!() |> Evidence.from_wire()
      assert_owned_session(capture, report.cleanup.owned_resources)
    end
  end

  defp assert_artifacts(_, _), do: :ok

  defp assert_owned_session(capture, resources) do
    for resource <- resources, do: assert(capture.session_id == resource.reference)
  end

  defp options(client, deadline),
    do: [
      client: client,
      agent_id: "agent",
      environment_id: "environment",
      prompt: "hello",
      handler: fn _, _, _ -> {:ok, "ok"} end,
      timeout: 200,
      deadline: deadline
    ]

  defp client(adapter),
    do:
      Client.new(
        api_key: "invented",
        req_options: [
          adapter: AcceptanceAdapter,
          finch_private: %{acceptance_adapter: adapter},
          retry: false
        ]
      )

  defp response(request, body), do: {request, Req.Response.new(status: 200, body: body)}
  defp now, do: System.monotonic_time(:millisecond)

  defp assert_dead(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 100
  end

  defp async_response do
    %Req.Response.Async{
      pid: self(),
      ref: make_ref(),
      stream_fun: fn _, {_, part} -> {:ok, [part]} end,
      cancel_fun: fn _ -> :ok end
    }
  end
end
