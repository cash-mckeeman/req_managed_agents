# RMA 0.3.0 — Session Artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the session-artifacts release — `SessionInfo` threading to handlers, CMA files primitives, AgentCore `environment` pass-through + `InvokeAgentRuntimeCommand`, and the `Artifacts` behaviour with `ClaudeFiles` and `AgentCoreSessionStorage` stores — as v0.3.0.

**Architecture:** Strict one-way layering: Client primitives (CMA files endpoints; AgentCore command endpoint) → `Artifacts` behaviour impls compose the primitives → handlers receive `%SessionInfo{}` and may call `Artifacts` from inside a tool. `Session`'s loop is unchanged except info threading. All additions are backward-compatible (optional callbacks, additive struct fields, optional spec fields).

**Tech Stack:** Elixir, ExUnit, Req 0.6 (`into:` streaming), Bypass (AgentCore event streams), Req.Test (CMA client), `aws_event_stream` via `EventStream.decode/1`.

**Spec:** `docs/superpowers/specs/2026-07-03-rma-030-session-artifacts-design.md`

## Global Constraints

- **jj, not git**: commit with `jj describe -m '<msg>' && jj new`. Workspace root: `.claude/worktrees/rma-030-artifacts/`.
- **Vocabulary is structs (spec D2):** `SessionInfo`, `Artifact`, `AgentCore.CommandResult` are `@derive Jason.Encoder` defstructs with `@type t`, one file each, matching `usage.ex`'s style.
- **Backward compatibility:** every existing 3-arity/2-arity handler, every existing spec map, every existing Client caller compiles and behaves unchanged. New callbacks are `@optional_callbacks`; new struct fields default nil; new spec fields optional.
- **One name per verb (spec D4):** no `fetch_output` on Client — the verb is `Artifacts.fetch/3`.
- **Error normalization (spec §5):** missing name → `{:error, :not_found}`; SessionStorage verb with unexpected non-zero exit → `{:error, {:command_failed, %CommandResult{}}}`; CMA duplicate filenames → `list` returns all, `fetch`/`delete` act on newest `created_at`.
- **No MIM-refs in lib/ moduledocs** (hexdocs-shipped). Tests/commits may reference MIM/GH issues.
- **Quality gates per task:** `mix format`, full `mix test` (0 failures), and the suite must stay warning-free; `mix credo --strict` is the CI gate.
- **Wire names (verified 2026-07-03):** CreateHarness body fields `"environment"` / `"environmentVariables"`; command endpoint `POST /runtimes/{agentRuntimeArn}/commands` (+ optional `qualifier` query param), header `X-Amzn-Bedrock-AgentCore-Runtime-Session-Id`, body `{"command", "timeout"}` (timeout: server-side seconds, service default 300, max 3600), response events `chunk` → `contentStart` / `contentDelta{stdout,stderr}` / `contentStop{exitCode,status}`.

---

### Task 1: `SessionInfo` struct + `SessionResult.session_id`

**Files:**
- Create: `lib/req_managed_agents/session_info.ex`
- Modify: `lib/req_managed_agents/session_result.ex`
- Test: `test/req_managed_agents/vocabulary_test.exs` (append)

**Interfaces:**
- Produces: `%ReqManagedAgents.SessionInfo{session_id: String.t() | nil, provider: module() | nil}`; `%SessionResult{}` gains `session_id: String.t() | nil` (default nil). Tasks 2, 7, 8, 11 consume these exact names.

- [ ] **Step 1: Write the failing tests (append inside the module in `vocabulary_test.exs`)**

```elixir
  test "SessionInfo constructs with nil defaults and encodes to JSON" do
    info = %ReqManagedAgents.SessionInfo{}
    assert info.session_id == nil
    assert info.provider == nil

    full = %ReqManagedAgents.SessionInfo{
      session_id: "sess_1",
      provider: ReqManagedAgents.Providers.ClaudeManagedAgents
    }

    assert %{"session_id" => "sess_1"} = Jason.decode!(Jason.encode!(full))
  end

  test "SessionResult carries session_id (default nil)" do
    assert %ReqManagedAgents.SessionResult{}.session_id == nil

    r = %ReqManagedAgents.SessionResult{session_id: "sess_2"}
    assert %{"session_id" => "sess_2"} = Jason.decode!(Jason.encode!(r))
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/vocabulary_test.exs`
Expected: FAIL — `ReqManagedAgents.SessionInfo.__struct__/1 is undefined` and a KeyError for `:session_id`.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/session_info.ex
defmodule ReqManagedAgents.SessionInfo do
  @moduledoc """
  Runtime identity of the session a callback is executing in — passed as the
  optional extra argument to `c:ReqManagedAgents.Handler.handle_tool_call/4`
  and `c:ReqManagedAgents.Handler.handle_event/3`.

  Grows by fields, never by arity: future runtime facts land here.
  """
  @derive Jason.Encoder
  defstruct session_id: nil, provider: nil

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          provider: module() | nil
        }
end
```

In `lib/req_managed_agents/session_result.ex`, add the field and type (after `stop_reason:` in both):

```elixir
            session_id: nil,
```

```elixir
          session_id: String.t() | nil,
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/req_managed_agents/vocabulary_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `mix format && mix test` — 0 failures.

```bash
jj describe -m 'feat(vocabulary): SessionInfo struct + SessionResult.session_id (MIM-67)' && jj new
```

---

### Task 2: SessionInfo threading — Handler optional callbacks, `Tools.run/7`, Session wiring

**Files:**
- Modify: `lib/req_managed_agents/handler.ex`, `lib/req_managed_agents/tools.ex`, `lib/req_managed_agents/session.ex`, `lib/req_managed_agents/providers/bedrock_agent_core.ex` (one line in `open/2`), `lib/req_managed_agents/provider.ex` (doc comment `Tools.run/6` → `/7`)
- Test: `test/req_managed_agents/session_info_test.exs` (new)

**Interfaces:**
- Consumes: Task 1's `%SessionInfo{}`.
- Produces: `Tools.run(handler, id, name, input, context, info, meta \\ %{})` (arity 7); Session state key `info: SessionInfo.t()`; conn key `session_id` on BOTH providers (Claude already sets it; Bedrock adds `session_id: sid`); `SessionResult.session_id` filled. Handler gains optional `handle_tool_call/4` + `handle_event/3`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/session_info_test.exs
defmodule ReqManagedAgents.SessionInfoTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{SessionInfo, TurnResult}

  # request_response fake whose conn carries a session_id (like both real providers post-0.3).
  defmodule InfoRR do
    @behaviour ReqManagedAgents.Provider

    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _subscriber), do: {:ok, %{session_id: "sess-info-1"}}
    @impl true
    def kickoff_input(_opts), do: [:kickoff]
    @impl true
    def user_input(text), do: [{:user, text}]
    @impl true
    def resume_input(_uses, _results), do: [:resume]

    @impl true
    def poll_turn(conn, [:kickoff]) do
      {:ok,
       [
         %{"type" => "tool", "id" => "tu_1", "name" => "whoami", "input" => %{}},
         %{"type" => "stop", "terminal" => :requires_action}
       ], conn}
    end

    def poll_turn(conn, [:resume]) do
      {:ok, [%{"type" => "stop", "terminal" => :end_turn}], conn}
    end

    @impl true
    def normalize(events) do
      customs =
        for %{"type" => "tool", "id" => id, "name" => n, "input" => i} <- events,
            do: %ReqManagedAgents.ToolUse{id: id, name: n, input: i}

      terminal =
        case List.last(events) do
          %{"type" => "stop", "terminal" => t} -> t
          _ -> :terminated
        end

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        text: "",
        custom_tool_uses: customs,
        server_tool_uses: [],
        usage: nil,
        events: events
      }
    end
  end

  defmodule FourArityHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call(_name, _input, _ctx), do: {:ok, "three-arity fallback"}

    @impl true
    def handle_tool_call("whoami", _input, %{test_pid: pid}, %SessionInfo{} = info) do
      send(pid, {:tool_saw_info, info})
      {:ok, "session #{info.session_id}"}
    end

    @impl true
    def handle_event(_ev, %{test_pid: pid}, %SessionInfo{} = info) do
      send(pid, {:event_saw_info, info.session_id})
      :ok
    end
  end

  defmodule ThreeArityHandler do
    @behaviour ReqManagedAgents.Handler

    @impl true
    def handle_tool_call("whoami", _input, %{test_pid: pid}) do
      send(pid, :three_arity_called)
      {:ok, "legacy"}
    end

    @impl true
    def handle_event(_ev, _ctx), do: :ok
  end

  test "module handler: 4-arity handle_tool_call and 3-arity handle_event receive SessionInfo" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: FourArityHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert_received {:tool_saw_info, %SessionInfo{session_id: "sess-info-1", provider: InfoRR}}
    assert_received {:event_saw_info, "sess-info-1"}
    assert result.session_id == "sess-info-1"
  end

  test "module handler: 3-arity handler still works unchanged (fallback dispatch)" do
    assert {:ok, result} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: ThreeArityHandler,
               context: %{test_pid: self()},
               prompt: "go"
             )

    assert_received :three_arity_called
    assert result.terminal == :end_turn
  end

  test "fn handler: 4-arity fun receives SessionInfo; 3-arity fun still works" do
    test_pid = self()

    assert {:ok, _} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: fn _name, _input, _ctx, %SessionInfo{session_id: sid} ->
                 send(test_pid, {:fn4, sid})
                 {:ok, "ok"}
               end,
               context: %{},
               prompt: "go"
             )

    assert_received {:fn4, "sess-info-1"}

    assert {:ok, _} =
             ReqManagedAgents.Session.run(InfoRR,
               handler: fn _name, _input, _ctx ->
                 send(test_pid, :fn3)
                 {:ok, "ok"}
               end,
               context: %{},
               prompt: "go"
             )

    assert_received :fn3
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/session_info_test.exs`
Expected: FAIL — 4-arity clauses never invoked (no `:tool_saw_info`), `result.session_id == nil`. (The 3-arity tests may pass pre-implementation — the 4-arity ones are the red anchor.)

- [ ] **Step 3: Implement**

`lib/req_managed_agents/handler.ex` — add after the existing `handle_event/2` callback:

```elixir
  @doc """
  Optional richer form of `c:handle_tool_call/3`: also receives the
  `ReqManagedAgents.SessionInfo` for the running session (its `session_id`,
  provider module). When a module exports the 4-arity form it is preferred;
  otherwise the 3-arity form is called. Fn handlers may likewise be 3- or
  4-arity.
  """
  @callback handle_tool_call(
              name :: String.t(),
              input :: map(),
              ctx :: term(),
              info :: ReqManagedAgents.SessionInfo.t()
            ) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Optional richer form of `c:handle_event/2` that also receives the `ReqManagedAgents.SessionInfo`."
  @callback handle_event(event :: map(), ctx :: term(), info :: ReqManagedAgents.SessionInfo.t()) ::
              :ok
```

and change the optional list to:

```elixir
  @optional_callbacks handle_event: 2, handle_event: 3, handle_tool_call: 3, handle_tool_call: 4
```

(Note: `handle_tool_call/3` must move into `@optional_callbacks` — a handler may now implement only the 4-arity form. The moduledoc gains one sentence: implement either arity of `handle_tool_call`; the 4-arity form wins when both exist.)

`lib/req_managed_agents/tools.ex` — `run/6` becomes `run/7` (single call site updated below; the module is `@moduledoc false` internal):

```elixir
  @spec run(
          module() | handler_fun(),
          String.t(),
          String.t(),
          map(),
          term(),
          ReqManagedAgents.SessionInfo.t(),
          map()
        ) :: map()
  def run(handler, id, name, input, context, info, meta \\ %{}) do
    :telemetry.span([:req_managed_agents, :tool], Map.merge(meta, %{tool: name}), fn ->
      event = do_run(handler, id, name, input, context, info)
      {event, Map.merge(meta, %{tool: name, is_error: event["is_error"] == true})}
    end)
  end

  defp do_run(handler, id, name, input, context, info) do
    result =
      cond do
        is_function(handler, 4) -> handler.(name, input, context, info)
        is_function(handler, 3) -> handler.(name, input, context)
        exports?(handler, :handle_tool_call, 4) ->
          handler.handle_tool_call(name, input, context, info)
        true -> handler.handle_tool_call(name, input, context)
      end

    case result do
      {:ok, text} -> Event.custom_tool_result(id, to_string(text))
      {:error, text} -> Event.custom_tool_result(id, to_string(text), is_error: true)
    end
  catch
    kind, reason ->
      Event.custom_tool_result(id, "tool #{kind}: #{inspect(reason)}", is_error: true)
  end

  # ensure_loaded first: a handler that exports ONLY the 4-arity form may not be
  # loaded when its first tool call arrives (function_exported?/3 alone would
  # miss it and misroute to the 3-arity call).
  defp exports?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
```

Also update `handler_fun` type to admit both arities:

```elixir
  @type handler_fun ::
          (String.t(), map(), term() -> {:ok, String.t()} | {:error, String.t()})
          | (String.t(), map(), term(), ReqManagedAgents.SessionInfo.t() ->
               {:ok, String.t()} | {:error, String.t()})
```

`lib/req_managed_agents/session.ex` — four changes:

1. Alias: add `SessionInfo` to the existing `alias ReqManagedAgents.{…}` line.
2. In `init/1`, add to the state map (after `conn: conn,`):

```elixir
          info: build_info(provider, conn),
```

3. In `handle_info(:reconnect, s)`'s success branch, add to the state-update map (after `conn: conn,`):

```elixir
            info: build_info(s.provider, conn),
```

4. Replace `run_tools/2`'s `Tools.run` call and `forward_raw/2`, and fill the result; add the builder next to `forward_raw/2`:

```elixir
        wire = Tools.run(s.handler, id, name, input, s.context, s.info, s.meta)
```

```elixir
  defp forward_raw(%{handler: h, context: ctx, info: info}, ev) when is_atom(h) and h != nil do
    cond do
      Code.ensure_loaded?(h) and function_exported?(h, :handle_event, 3) ->
        h.handle_event(ev, ctx, info)

      function_exported?(h, :handle_event, 2) ->
        h.handle_event(ev, ctx)

      true ->
        :ok
    end

    :ok
  end

  defp forward_raw(_s, _ev), do: :ok

  # Session identity for handler callbacks: providers standardize a :session_id
  # conn key (Claude mints it at open; Bedrock echoes the caller-supplied id).
  defp build_info(provider, conn),
    do: %SessionInfo{session_id: Map.get(conn, :session_id), provider: provider}
```

In `session_result/3`, add (after `stop_reason: tr.stop_reason,`):

```elixir
      session_id: s.info.session_id,
```

`lib/req_managed_agents/providers/bedrock_agent_core.ex` — in `open/2`'s conn map, add after `sid: Keyword.fetch!(opts, :runtime_session_id),`:

```elixir
       session_id: Keyword.fetch!(opts, :runtime_session_id),
```

`lib/req_managed_agents/provider.ex:86` — change the doc comment text `Tools.run/6` to `Tools.run/7`.

- [ ] **Step 4: Run new tests, then full suite**

Run: `mix test test/req_managed_agents/session_info_test.exs && mix test`
Expected: ALL PASS — every existing session/provider/live-events test unchanged and green (3-arity paths are behavior-identical).

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(session): thread SessionInfo to handlers — optional handle_tool_call/4 + handle_event/3 (MIM-67)' && jj new
```

---

### Task 3: CMA files primitives — `Client.list_files/2` + `Client.delete_file/2`

**Files:**
- Modify: `lib/req_managed_agents/client.ex` (files section), `lib/req_managed_agents/client/behaviour.ex`
- Test: `test/req_managed_agents/client_test.exs` (append)

**Interfaces:**
- Consumes: existing `file_req/4`, `file_headers/2`, `span/3`, client struct fields `files_beta`/`beta`.
- Produces: `Client.list_files(client, opts \\ [])` (`opts[:params]` map → query string) and `Client.delete_file(client, file_id)`, both `{:ok, map()} | {:error, term()}`, both on `Client.Behaviour`. Task 7 consumes these exact names via a behaviour mock.

- [ ] **Step 1: Write the failing tests (append; follow the file's Req.Test stub style)**

```elixir
  test "list_files sends GET /v1/files with scope_id param and BOTH beta headers", %{
    client: client
  } do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/files"
      assert conn.query_string =~ "scope_id=sess_1"

      assert {"anthropic-beta", beta} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "anthropic-beta" end)

      assert beta =~ "files-api-2025-04-14"
      assert beta =~ "managed-agents-2026-04-01"

      Req.Test.json(conn, %{
        "data" => [%{"id" => "file_1", "filename" => "report.md", "size_bytes" => 12}]
      })
    end)

    assert {:ok, %{"data" => [%{"id" => "file_1"}]}} =
             ReqManagedAgents.Client.list_files(client, params: %{scope_id: "sess_1"})
  end

  test "list_files without params sends no query string", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.request_path == "/v1/files"
      assert conn.query_string == ""
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, %{"data" => []}} = ReqManagedAgents.Client.list_files(client)
  end

  test "delete_file sends DELETE /v1/files/{id} with both beta headers", %{client: client} do
    Req.Test.stub(ReqManagedAgents.ClientTest, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/files/file_9"

      assert {"anthropic-beta", beta} =
               Enum.find(conn.req_headers, fn {k, _} -> k == "anthropic-beta" end)

      assert beta =~ "files-api-2025-04-14"
      Req.Test.json(conn, %{"id" => "file_9", "deleted" => true})
    end)

    assert {:ok, %{"deleted" => true}} = ReqManagedAgents.Client.delete_file(client, "file_9")
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/client_test.exs`
Expected: FAIL — `Client.list_files/2` undefined.

- [ ] **Step 3: Implement (in the `# ---- Files (separate beta)` section, after `download_file/2`)**

```elixir
  @impl true
  def list_files(c, opts \\ []) do
    # Session-scoped listing (scope_id) requires BOTH betas — same combination
    # download_file/2 sends; harmless when unscoped.
    combined = "#{c.files_beta},#{c.beta}"

    span(:get, "/v1/files", fn ->
      c
      |> file_req("/v1/files", file_headers(c, combined), [])
      |> Req.get(params: opts[:params] || %{})
    end)
  end

  @impl true
  def delete_file(c, file_id) do
    combined = "#{c.files_beta},#{c.beta}"

    span(:delete, "/v1/files/#{file_id}", fn ->
      c
      |> file_req("/v1/files/#{file_id}", file_headers(c, combined), [])
      |> Req.delete()
    end)
  end
```

`lib/req_managed_agents/client/behaviour.ex` — add after `attach_file_to_session`:

```elixir
  @callback list_files(Client.t(), keyword()) :: result()
  @callback delete_file(Client.t(), String.t()) :: result()
```

If the compiler warns that the live `Client` misses `@impl` coherence, mirror the existing pattern (the module declares `@behaviour ReqManagedAgents.Client.Behaviour`; `@impl true` on both new functions as written).

- [ ] **Step 4: Run tests, full suite**

Run: `mix test test/req_managed_agents/client_test.exs && mix test`
Expected: ALL PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(client): list_files/2 + delete_file/2 on the Files API + Behaviour (MIM-66, closes GH #29 surface)' && jj new
```

---

### Task 4: AgentCore `environment` + `environment_variables` spec fields

**Files:**
- Modify: `lib/req_managed_agents/agent_core/client.ex` (`create_harness/2` body pipeline), `lib/req_managed_agents/providers/bedrock_agent_core.ex` (`provision/2` harness_spec + moduledoc sentence)
- Test: `test/req_managed_agents/agent_core/client_test.exs` (append), `test/req_managed_agents/providers/bedrock_agent_core_test.exs` (append)

**Interfaces:**
- Produces: optional provision-spec fields `:environment` (wire `"environment"`) and `:environment_variables` (wire `"environmentVariables"`), opaque pass-through; both participate in `harness_name/2`'s spec-hash. Task 11's mount leg consumes this.

- [ ] **Step 1: Write the failing tests**

Append to `test/req_managed_agents/agent_core/client_test.exs` (uses its existing `bypass`/`client` setup):

```elixir
  test "create_harness passes environment + environmentVariables opaquely (absent when unset)",
       %{bypass: bypass, client: client} do
    env = %{
      "agentCoreRuntimeEnvironment" => %{
        "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
      }
    }

    Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["environment"] == env
      assert decoded["environmentVariables"] == %{"LOG_LEVEL" => "debug"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harness":{"arn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/e","harnessId":"e-1","status":"CREATING"}})
      )
    end)

    spec = %{
      name: "e",
      execution_role_arn: "arn:aws:iam::123456789012:role/AgentCoreRole",
      system_prompt: "x",
      tools: [],
      model: %{"bedrockModelConfig" => %{"modelId" => "m"}},
      environment: env,
      environment_variables: %{"LOG_LEVEL" => "debug"}
    }

    assert {:ok, _} = ReqManagedAgents.AgentCore.Client.create_harness(client, spec)

    Bypass.expect_once(bypass, "POST", "/harnesses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "environment")
      refute Map.has_key?(decoded, "environmentVariables")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s({"harness":{"arn":"arn:aws:bedrock-agentcore:us-east-1:1:harness/e","harnessId":"e-2","status":"CREATING"}})
      )
    end)

    bare = Map.drop(spec, [:environment, :environment_variables])
    assert {:ok, _} = ReqManagedAgents.AgentCore.Client.create_harness(client, bare)
  end
```

Append to `test/req_managed_agents/providers/bedrock_agent_core_test.exs` (use its existing alias for the provider):

```elixir
  test "provision threads environment fields into the harness spec, and the spec-hash covers them" do
    base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}

    with_env =
      Map.merge(base, %{
        environment: %{
          "agentCoreRuntimeEnvironment" => %{
            "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
          }
        },
        environment_variables: %{"A" => "1"}
      })

    # Differently-mounted specs must provision under different deterministic names —
    # otherwise they'd collide in the Provisioner cache.
    refute P.harness_name(base, "t") == P.harness_name(with_env, "t")

    test_pid = self()

    create_fun = fn harness_spec ->
      send(test_pid, {:harness_spec, harness_spec})

      {:ok,
       %{"harness" => %{"arn" => "arn:aws:bedrock-agentcore:us-east-1:1:harness/x", "harnessId" => "x"}}}
    end

    get_fun = fn _ -> {:ok, %{"harness" => %{"status" => "READY"}}} end

    assert {:ok, _} =
             P.provision(with_env,
               execution_role_arn: "arn:aws:iam::1:role/r",
               create_fun: create_fun,
               get_fun: get_fun
             )

    assert_received {:harness_spec, hs}
    assert hs.environment == with_env.environment
    assert hs.environment_variables == %{"A" => "1"}
  end
```

(If the test file aliases the provider under a different name than `P`, adapt the alias reference; assertions stay identical.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs test/req_managed_agents/providers/bedrock_agent_core_test.exs`
Expected: FAIL — `environment` absent from body / KeyError on `hs.environment`.

- [ ] **Step 3: Implement**

`lib/req_managed_agents/agent_core/client.ex`, `create_harness/2` body pipeline — extend:

```elixir
      |> maybe_put("timeoutSeconds", Map.get(spec, :timeout_seconds))
      |> maybe_put("environment", Map.get(spec, :environment))
      |> maybe_put("environmentVariables", Map.get(spec, :environment_variables))
```

`lib/req_managed_agents/providers/bedrock_agent_core.ex`, `provision/2` harness_spec map — add:

```elixir
      environment: Map.get(spec, :environment),
      environment_variables: Map.get(spec, :environment_variables),
```

Because these ride the **spec map**, `harness_name/2` (which hashes the whole spec) covers them with no further change. Append one moduledoc sentence to the provider: `The provision spec may carry opaque \`environment\`/\`environment_variables\` maps that pass through to CreateHarness verbatim (filesystem mounts, custom containers, env vars — never interpreted by this library).`

- [ ] **Step 4: Run tests + full suite**

Run: `mix test test/req_managed_agents/agent_core/client_test.exs test/req_managed_agents/providers/bedrock_agent_core_test.exs && mix test`
Expected: ALL PASS. (`create_harness` sends nil-valued keys through `maybe_put`, so unset fields stay absent — the negative assertions prove it.)

- [ ] **Step 5: Commit**

```bash
jj describe -m 'feat(agent_core): opaque environment/environmentVariables provision spec fields (MIM-65)' && jj new
```

---

### Task 5: `CommandResult` + `Client.invoke_agent_runtime_command/2`

**Files:**
- Create: `lib/req_managed_agents/agent_core/command_result.ex`
- Modify: `lib/req_managed_agents/agent_core/client.ex`
- Test: `test/req_managed_agents/agent_core/command_test.exs` (new; Bypass, reuse `ReqManagedAgents.EventStreamFrames.frame/1`)

**Interfaces:**
- Consumes: Task-1-era conventions; existing `stream_reducer/1`, `streamed_events/1`, `streamed_body/1`, `span/5`, `SigV4.sign_request/4`, `EventStreamFrames.frame/1` test helper.
- Produces: `%ReqManagedAgents.AgentCore.CommandResult{stdout: binary(), stderr: binary(), exit_code: integer() | nil}`; `Client.invoke_agent_runtime_command(client, inv)` with `inv :: %{agent_runtime_arn:, runtime_session_id:, command:, optional timeout_seconds:, idle_timeout: (default 300_000), on_output: ((:stdout | :stderr, binary()) -> any()) | nil, qualifier:}` → `{:ok, CommandResult.t()} | {:error, term()}`. Task 8 consumes exactly this.

- [ ] **Step 1: Create the struct**

```elixir
# lib/req_managed_agents/agent_core/command_result.ex
defmodule ReqManagedAgents.AgentCore.CommandResult do
  @moduledoc """
  Collected output of one `InvokeAgentRuntimeCommand` execution. Not an error
  shape — callers branch on `exit_code` (0 = success; the command's own exit
  status otherwise).
  """
  @derive Jason.Encoder
  defstruct stdout: "", stderr: "", exit_code: nil

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit_code: integer() | nil
        }
end
```

- [ ] **Step 2: Write the failing tests**

```elixir
# test/req_managed_agents/agent_core/command_test.exs
defmodule ReqManagedAgents.AgentCore.CommandTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.AgentCore.{Client, CommandResult}
  import ReqManagedAgents.EventStreamFrames, only: [frame: 1]

  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  @arn "arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/ba-x1"
  @sid "test-session-id-long-enough-to-satisfy-min-length-33"

  defp inv(extra \\ []) do
    Map.merge(
      %{agent_runtime_arn: @arn, runtime_session_id: @sid, command: "echo hi"},
      Map.new(extra)
    )
  end

  setup do
    bypass = Bypass.open()
    client = Client.new(credentials: @creds, base_url: "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, client: client}
  end

  defp chunked(conn, frames) do
    conn = Plug.Conn.send_chunked(conn, 200)

    Enum.reduce(frames, conn, fn part, conn ->
      case Plug.Conn.chunk(conn, part) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)
  end

  test "collects stdout/stderr/exitCode from chunk-wrapped events; ARN rides the path; session header set",
       %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, fn conn ->
      # Catch-all route: the path embeds the percent-encoded ARN, so we assert on it here.
      assert conn.method == "POST"
      assert conn.request_path =~ "/runtimes/"
      assert conn.request_path =~ "/commands"
      assert conn.request_path =~ "runtime%2Fba-x1" or conn.request_path =~ "runtime/ba-x1"

      assert {_, @sid} =
               Enum.find(conn.req_headers, fn {k, _} ->
                 k == "x-amzn-bedrock-agentcore-runtime-session-id"
               end)

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"command" => "echo hi"} = Jason.decode!(body)

      chunked(conn, [
        frame(~s({"chunk":{"contentStart":{}}})),
        frame(~s({"chunk":{"contentDelta":{"stdout":"hi"}}})),
        frame(~s({"chunk":{"contentDelta":{"stderr":"warn"}}})),
        frame(~s({"chunk":{"contentDelta":{"stdout":"!\\n"}}})),
        frame(~s({"chunk":{"contentStop":{"exitCode":0,"status":"completed"}}}))
      ])
    end)

    assert {:ok, %CommandResult{stdout: "hi!\n", stderr: "warn", exit_code: 0}} =
             Client.invoke_agent_runtime_command(client, inv())
  end

  test "bare (unwrapped) events are tolerated; non-zero exit is NOT an error", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, fn conn ->
      assert conn.method == "POST"

      chunked(conn, [
        frame(~s({"contentDelta":{"stderr":"boom"}})),
        frame(~s({"contentStop":{"exitCode":3,"status":"completed"}}))
      ])
    end)

    assert {:ok, %CommandResult{stderr: "boom", exit_code: 3}} =
             Client.invoke_agent_runtime_command(client, inv())
  end

  test "on_output streams labeled chunks in order before return; timeout_seconds serializes", %{
    bypass: bypass,
    client: client
  } do
    test_pid = self()

    Bypass.expect_once(bypass, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"timeout" => 120} = Jason.decode!(body)

      chunked(conn, [
        frame(~s({"chunk":{"contentDelta":{"stdout":"a"}}})),
        frame(~s({"chunk":{"contentDelta":{"stderr":"b"}}})),
        frame(~s({"chunk":{"contentStop":{"exitCode":0,"status":"completed"}}}))
      ])
    end)

    assert {:ok, _} =
             Client.invoke_agent_runtime_command(
               client,
               inv(
                 timeout_seconds: 120,
                 on_output: fn stream, chunk -> send(test_pid, {:out, stream, chunk}) end
               )
             )

    assert_received {:out, :stdout, "a"}
    assert_received {:out, :stderr, "b"}
  end

  test "a stalled stream fails with a transport timeout at idle_timeout", %{
    bypass: bypass,
    client: client
  } do
    Bypass.expect_once(bypass, fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, frame(~s({"chunk":{"contentStart":{}}})))
      Process.sleep(800)

      case Plug.Conn.chunk(conn, frame(~s({"chunk":{"contentStop":{"exitCode":0}}}))) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Client.invoke_agent_runtime_command(client, inv(idle_timeout: 300))

    Bypass.pass(bypass)
  end

  test "an exception frame surfaces as an error", %{bypass: bypass, client: client} do
    Bypass.expect_once(bypass, fn conn ->
      chunked(conn, [
        frame(
          ~s({"__stream_error__":{"type":"validationException","message":{"message":"bad"}}})
        )
      ])
    end)

    assert {:error, {:command_stream_error, "validationException", _}} =
             Client.invoke_agent_runtime_command(client, inv())
  end
end
```

(Note the exception-frame test: real exception frames arrive with `:message-type` exception headers which `EventStream` maps to `%{"__stream_error__" => …}`; the headerless test frame carries that envelope literally, which exercises the same detection path — the pattern used by the existing invoke tests.)

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/req_managed_agents/agent_core/command_test.exs`
Expected: FAIL — `invoke_agent_runtime_command/2` undefined.

- [ ] **Step 4: Implement (in `lib/req_managed_agents/agent_core/client.ex`, after `invoke_harness/2`)**

```elixir
  @doc """
  Data-plane `InvokeAgentRuntimeCommand` — run a shell command inside the session's
  microVM (no model loop, no token cost) and collect its streamed output.

  `inv` requires `:agent_runtime_arn` (the harness/runtime ARN — it rides the URI
  path), `:runtime_session_id`, and `:command`. Optional: `:timeout_seconds`
  (server-side cap, service default 300, max 3600), `:idle_timeout` (inter-chunk
  liveness guard, default 300_000 ms), `:on_output` (fn `(:stdout | :stderr, chunk)`
  called per delta, in order), `:qualifier` (endpoint name).

  Returns `{:ok, %ReqManagedAgents.AgentCore.CommandResult{}}` — a non-zero
  `exit_code` is a RESULT, not an error. Transport/stream failures return
  `{:error, term()}`.
  """
  @spec invoke_agent_runtime_command(t(), map()) ::
          {:ok, ReqManagedAgents.AgentCore.CommandResult.t()} | {:error, term()}
  def invoke_agent_runtime_command(
        c,
        %{agent_runtime_arn: arn, runtime_session_id: sid, command: command} = inv
      ) do
    path = "/runtimes/#{URI.encode_www_form(arn)}/commands"

    span(c, :post, "/runtimes/{arn}/commands", :invoke_agent_runtime_command, fn ->
      body =
        %{"command" => command}
        |> maybe_put("timeout", inv[:timeout_seconds])

      qs = if inv[:qualifier], do: "?" <> URI.encode_query([{"qualifier", inv[:qualifier]}]), else: ""
      url = c.base_url <> path <> qs
      json = Jason.encode!(body)

      headers =
        SigV4.sign_request(:post, url, json,
          service: c.service,
          credentials: c.credentials,
          headers: [
            {"content-type", "application/json"},
            {"X-Amzn-Bedrock-AgentCore-Runtime-Session-Id", sid}
          ]
        )

      case request(c, :post, url, headers, json,
             receive_timeout: inv[:idle_timeout] || @default_idle_timeout,
             into: stream_reducer(command_on_event(inv[:on_output]))
           ) do
        {:ok, %{status: s} = resp} when s in 200..299 ->
          events = streamed_events(resp)

          case command_stream_error(events) do
            {type, message} -> {:error, {:command_stream_error, type, message}}
            nil -> {:ok, command_result(events)}
          end

        {:ok, %{status: s} = resp} ->
          {:error, {:http_error, s, streamed_body(resp)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Bridge decoded command events to the caller's on_output callback (per delta, in order).
  defp command_on_event(nil), do: nil

  defp command_on_event(on_output) when is_function(on_output, 2) do
    fn ev ->
      case unwrap_chunk(ev) do
        %{"contentDelta" => d} ->
          if is_binary(d["stdout"]) and d["stdout"] != "", do: on_output.(:stdout, d["stdout"])
          if is_binary(d["stderr"]) and d["stderr"] != "", do: on_output.(:stderr, d["stderr"])

        _ ->
          :ok
      end
    end
  end

  defp command_result(events) do
    Enum.reduce(events, %ReqManagedAgents.AgentCore.CommandResult{}, fn ev, acc ->
      case unwrap_chunk(ev) do
        %{"contentDelta" => d} ->
          %{
            acc
            | stdout: acc.stdout <> (d["stdout"] || ""),
              stderr: acc.stderr <> (d["stderr"] || "")
          }

        %{"contentStop" => stop} ->
          %{acc | exit_code: stop["exitCode"]}

        _ ->
          acc
      end
    end)
  end

  # The wire wraps command events in a "chunk" envelope; tolerate bare events too.
  defp unwrap_chunk(%{"chunk" => inner}) when is_map(inner), do: inner
  defp unwrap_chunk(ev), do: ev

  defp command_stream_error(events) do
    Enum.find_value(events, fn
      %{"__stream_error__" => %{"type" => t, "message" => m}} -> {t, m}
      _ -> nil
    end)
  end
```

**Known-risk note for the implementer:** the ARN is percent-encoded into the path (`URI.encode_www_form/1`). SigV4 canonical-URI handling of pre-encoded path segments is signer-dependent; offline tests can't falsify the signature. If the live canary later returns 403 `SignatureDoesNotMatch`, the documented fallback is `URI.encode(arn, &URI.char_unreserved?/1)` — do NOT churn on this offline; the Bypass test only asserts the path shape.

- [ ] **Step 5: Run tests, full suite**

Run: `mix test test/req_managed_agents/agent_core/command_test.exs && mix test`
Expected: ALL PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m 'feat(agent_core): InvokeAgentRuntimeCommand — CommandResult + streamed on_output (MIM-65)' && jj new
```

---

### Task 6: `Artifact` struct + `Artifacts` behaviour/facade

**Files:**
- Create: `lib/req_managed_agents/artifact.ex`, `lib/req_managed_agents/artifacts.ex`
- Test: `test/req_managed_agents/artifacts_test.exs` (new)

**Interfaces:**
- Produces: `%ReqManagedAgents.Artifact{name, size, ref, raw}`; behaviour callbacks `list(store, opts)`, `fetch(store, name, opts)`, `put(store, name, contents, opts)`, `delete(store, name, opts)`; facade functions of the same names dispatching on `{impl_module, store}`. Tasks 7/8 implement the behaviour; Task 11 calls the facade.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/artifacts_test.exs
defmodule ReqManagedAgents.ArtifactsTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Artifact, Artifacts}

  defmodule EchoStore do
    @behaviour ReqManagedAgents.Artifacts

    @impl true
    def list(store, opts), do: {:ok, [%Artifact{name: "seen", ref: {store, opts}}]}
    @impl true
    def fetch(_store, name, _opts), do: {:ok, "bytes-of-" <> name}
    @impl true
    def put(_store, _name, _contents, _opts), do: :ok
    @impl true
    def delete(_store, "missing", _opts), do: {:error, :not_found}
    def delete(_store, _name, _opts), do: :ok
  end

  test "facade dispatches every verb to the impl with the store" do
    store = {EchoStore, %{tag: :s1}}

    assert {:ok, [%Artifact{name: "seen", ref: {%{tag: :s1}, [scope: :x]}}]} =
             Artifacts.list(store, scope: :x)

    assert {:ok, "bytes-of-report.md"} = Artifacts.fetch(store, "report.md")
    assert :ok = Artifacts.put(store, "in.csv", "a,b")
    assert :ok = Artifacts.delete(store, "report.md")
    assert {:error, :not_found} = Artifacts.delete(store, "missing")
  end

  test "Artifact struct defaults + JSON encoding" do
    a = %Artifact{name: "r.md", size: 12, ref: "file_1"}
    assert %{"name" => "r.md", "size" => 12} = Jason.decode!(Jason.encode!(a))
    assert %Artifact{}.size == nil
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/artifacts_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/artifact.ex
defmodule ReqManagedAgents.Artifact do
  @moduledoc """
  A named file in a session's storage, provider-agnostic. `name` is the only
  identity the model ever sees; `ref` is the provider-native identity (a CMA
  file id, a sandbox path); `raw` is the unparsed provider record when one exists.
  """
  @derive Jason.Encoder
  defstruct name: nil, size: nil, ref: nil, raw: nil

  @type t :: %__MODULE__{
          name: String.t() | nil,
          size: non_neg_integer() | nil,
          ref: term(),
          raw: term()
        }
end
```

```elixir
# lib/req_managed_agents/artifacts.ex
defmodule ReqManagedAgents.Artifacts do
  @moduledoc """
  One artifacts vocabulary over provider-native session storage: `list/2`,
  `fetch/3`, `put/4`, `delete/3` — name-keyed and session-scoped, because a
  file's NAME is the only identity the model can ever reference.

  A store is `{impl_module, store_term}`; build the store_term with the impl's
  constructor:

    * `ReqManagedAgents.Artifacts.ClaudeFiles.store/2` — Anthropic Files API
    * `ReqManagedAgents.Artifacts.AgentCoreSessionStorage.store/4` — AgentCore
      `sessionStorage` mount, command-backed (report-scale artifacts)

  Error normalization across impls: a missing name is `{:error, :not_found}`;
  when duplicate names exist (re-runs accumulate on CMA), `list/2` returns all
  and `fetch`/`delete` act on the newest.
  """
  alias ReqManagedAgents.Artifact

  @type store :: {module(), term()}

  @callback list(store_term :: term(), opts :: keyword()) ::
              {:ok, [Artifact.t()]} | {:error, term()}
  @callback fetch(store_term :: term(), name :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
  @callback put(store_term :: term(), name :: String.t(), contents :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback delete(store_term :: term(), name :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @spec list(store(), keyword()) :: {:ok, [Artifact.t()]} | {:error, term()}
  def list({impl, store}, opts \\ []), do: impl.list(store, opts)

  @spec fetch(store(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch({impl, store}, name, opts \\ []), do: impl.fetch(store, name, opts)

  @spec put(store(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def put({impl, store}, name, contents, opts \\ []), do: impl.put(store, name, contents, opts)

  @spec delete(store(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete({impl, store}, name, opts \\ []), do: impl.delete(store, name, opts)
end
```

- [ ] **Step 4: Run tests + full suite; commit**

Run: `mix test test/req_managed_agents/artifacts_test.exs && mix format && mix test`
Expected: ALL PASS.

```bash
jj describe -m 'feat(artifacts): Artifact struct + Artifacts behaviour/facade — one vocabulary, provider-native stores' && jj new
```

---

### Task 7: `Artifacts.ClaudeFiles`

**Files:**
- Create: `lib/req_managed_agents/artifacts/claude_files.ex`
- Test: `test/req_managed_agents/artifacts/claude_files_test.exs` (new)

**Interfaces:**
- Consumes: Task 3's `list_files/2` + `delete_file/2`, existing `upload_file/2`, `download_file/2`, `attach_file_to_session/3` — all via an injectable `client_mod` (defaults `ReqManagedAgents.Client`; tests inject a stub module).
- Produces: `ClaudeFiles.store(client, session_id, opts \\ [])` → store term; the four behaviour verbs. Task 11's CMA leg uses `{ClaudeFiles, ClaudeFiles.store(client, session_id)}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/artifacts/claude_files_test.exs
defmodule ReqManagedAgents.Artifacts.ClaudeFilesTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.{Artifact, Artifacts}
  alias ReqManagedAgents.Artifacts.ClaudeFiles

  # Stub of the Client.Behaviour surface ClaudeFiles touches. Sends every call
  # to the test pid so interactions are assertable.
  defmodule StubClient do
    def list_files(_c, opts) do
      send(self_pid(), {:list_files, opts})

      {:ok,
       %{
         "data" => [
           %{"id" => "file_old", "filename" => "report.md", "size_bytes" => 10,
             "created_at" => "2026-07-01T00:00:00Z"},
           %{"id" => "file_new", "filename" => "report.md", "size_bytes" => 20,
             "created_at" => "2026-07-03T00:00:00Z"},
           %{"id" => "file_z", "filename" => "data.csv", "size_bytes" => 5,
             "created_at" => "2026-07-02T00:00:00Z"}
         ]
       }}
    end

    def download_file(_c, id) do
      send(self_pid(), {:download, id})
      {:ok, "bytes:" <> id}
    end

    def delete_file(_c, id) do
      send(self_pid(), {:delete, id})
      {:ok, %{"deleted" => true}}
    end

    def upload_file(_c, params) do
      send(self_pid(), {:upload, params})
      {:ok, %{"id" => "file_up"}}
    end

    def attach_file_to_session(_c, sid, params) do
      send(self_pid(), {:attach, sid, params})
      {:ok, %{"id" => "res_1"}}
    end

    defp self_pid, do: Process.get(:test_pid) || self()
  end

  setup do
    Process.put(:test_pid, self())
    store = {ClaudeFiles, ClaudeFiles.store(:fake_client, "sess_1", client_mod: StubClient)}
    {:ok, store: store}
  end

  test "list scopes by session and maps to Artifact structs", %{store: store} do
    assert {:ok, artifacts} = Artifacts.list(store)
    assert_received {:list_files, opts}
    assert opts[:params] == %{scope_id: "sess_1"}

    assert [%Artifact{name: "report.md", ref: "file_old", size: 10} | _] = artifacts
    assert length(artifacts) == 3
  end

  test "fetch downloads the NEWEST match by created_at", %{store: store} do
    assert {:ok, "bytes:file_new"} = Artifacts.fetch(store, "report.md")
    assert_received {:download, "file_new"}
  end

  test "fetch of a missing name is :not_found", %{store: store} do
    assert {:error, :not_found} = Artifacts.fetch(store, "nope.txt")
  end

  test "delete removes the newest match", %{store: store} do
    assert :ok = Artifacts.delete(store, "report.md")
    assert_received {:delete, "file_new"}
  end

  test "put uploads then attaches at the default mount path", %{store: store} do
    assert :ok = Artifacts.put(store, "in.csv", "a,b")
    assert_received {:upload, %{purpose: "agent", file: {"in.csv", "a,b"}}}
    assert_received {:attach, "sess_1", %{file_id: "file_up", mount_path: "/data/in.csv"}}
  end

  test "put honors a custom mount_path", %{store: store} do
    assert :ok = Artifacts.put(store, "in.csv", "a,b", mount_path: "/inputs/in.csv")
    assert_received {:attach, _, %{mount_path: "/inputs/in.csv"}}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/artifacts/claude_files_test.exs`
Expected: FAIL — `ClaudeFiles` undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/artifacts/claude_files.ex
defmodule ReqManagedAgents.Artifacts.ClaudeFiles do
  @moduledoc """
  `ReqManagedAgents.Artifacts` store over the Anthropic Files API, scoped to one
  session. `list` uses the session-scoped file listing (the only way to discover
  server-minted file ids for files the agent wrote); `fetch`/`delete` act on the
  newest record when a name appears more than once (re-runs accumulate);
  `put` uploads and attaches at `opts[:mount_path]` (default `"/data/<name>"`).
  """
  @behaviour ReqManagedAgents.Artifacts

  alias ReqManagedAgents.Artifact

  @doc "Build a store term. `client_mod` is injectable for tests (defaults to the live client)."
  def store(client, session_id, opts \\ []) do
    %{
      client: client,
      session_id: session_id,
      client_mod: opts[:client_mod] || ReqManagedAgents.Client
    }
  end

  @impl true
  def list(store, _opts \\ []) do
    with {:ok, %{"data" => files}} <-
           store.client_mod.list_files(store.client, params: %{scope_id: store.session_id}) do
      {:ok, Enum.map(files, &to_artifact/1)}
    end
  end

  @impl true
  def fetch(store, name, opts \\ []) do
    with {:ok, %{"id" => id}} <- newest(store, name, opts) do
      store.client_mod.download_file(store.client, id)
    end
  end

  @impl true
  def put(store, name, contents, opts \\ []) do
    mount_path = opts[:mount_path] || "/data/" <> name

    with {:ok, %{"id" => file_id}} <-
           store.client_mod.upload_file(store.client, %{purpose: "agent", file: {name, contents}}),
         {:ok, _} <-
           store.client_mod.attach_file_to_session(store.client, store.session_id, %{
             file_id: file_id,
             mount_path: mount_path
           }) do
      :ok
    end
  end

  @impl true
  def delete(store, name, opts \\ []) do
    with {:ok, %{"id" => id}} <- newest(store, name, opts),
         {:ok, _} <- store.client_mod.delete_file(store.client, id) do
      :ok
    end
  end

  defp newest(store, name, _opts) do
    with {:ok, %{"data" => files}} <-
           store.client_mod.list_files(store.client, params: %{scope_id: store.session_id}) do
      files
      |> Enum.filter(&(&1["filename"] == name))
      |> Enum.sort_by(& &1["created_at"], :desc)
      |> case do
        [newest | _] -> {:ok, newest}
        [] -> {:error, :not_found}
      end
    end
  end

  defp to_artifact(file) do
    %Artifact{
      name: file["filename"],
      size: file["size_bytes"],
      ref: file["id"],
      raw: file
    }
  end
end
```

(ISO-8601 UTC timestamps sort correctly as strings — no datetime parsing needed. If the live canary shows a different timestamp field name, `raw` preserves everything; adjust then.)

- [ ] **Step 4: Run tests + full suite; commit**

Run: `mix test test/req_managed_agents/artifacts/claude_files_test.exs && mix format && mix test`
Expected: ALL PASS.

```bash
jj describe -m 'feat(artifacts): ClaudeFiles store — session-scoped list/fetch/put/delete over the Files API (MIM-66)' && jj new
```

---

### Task 8: `Artifacts.AgentCoreSessionStorage`

**Files:**
- Create: `lib/req_managed_agents/artifacts/agent_core_session_storage.ex`
- Test: `test/req_managed_agents/artifacts/agent_core_session_storage_test.exs` (new)

**Interfaces:**
- Consumes: Task 5's `%CommandResult{}` and (via injectable `command_fun`) `invoke_agent_runtime_command/2`'s contract; Task 6's behaviour.
- Produces: `AgentCoreSessionStorage.store(client, agent_runtime_arn, runtime_session_id, base_path, opts \\ [])`; the four verbs, command-backed. Task 11's mount leg uses it live.

**Design notes binding this task (from the spec):** names are validated against `~r/^[A-Za-z0-9._-]+$/` (rejects `/`, quotes, `..` traversal — `{:error, {:invalid_name, name}}` otherwise); python3 one-liners take paths via `argv` (never interpolated into python source); file bytes transit as Base64 (binary-safe); `put` chunks the Base64 into ≤48_000-char appends because the wire caps `command` at 65_536 chars; exit code 3 is the impl's "not found" sentinel; any other non-zero exit → `{:error, {:command_failed, %CommandResult{}}}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/req_managed_agents/artifacts/agent_core_session_storage_test.exs
defmodule ReqManagedAgents.Artifacts.AgentCoreSessionStorageTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Artifacts
  alias ReqManagedAgents.Artifacts.AgentCoreSessionStorage, as: Storage
  alias ReqManagedAgents.Artifact
  alias ReqManagedAgents.AgentCore.CommandResult

  defp store(command_fun) do
    {Storage,
     Storage.store(:fake_client, "arn:aws:bedrock-agentcore:us-east-1:1:runtime/x",
       String.duplicate("s", 33), "/mnt/data", command_fun: command_fun)}
  end

  test "list runs a python scandir and maps its JSON to Artifacts" do
    test_pid = self()

    fun = fn inv ->
      send(test_pid, {:cmd, inv.command})

      {:ok,
       %CommandResult{
         stdout: ~s([{"name":"report.md","size":42},{"name":"data.csv","size":7}]),
         exit_code: 0
       }}
    end

    assert {:ok,
            [
              %Artifact{name: "report.md", size: 42, ref: "/mnt/data/report.md"},
              %Artifact{name: "data.csv", size: 7, ref: "/mnt/data/data.csv"}
            ]} = Artifacts.list(store(fun))

    assert_received {:cmd, cmd}
    assert cmd =~ "python3 -c"
    assert cmd =~ "'/mnt/data'"
  end

  test "fetch base64-decodes stdout; exit 3 maps to :not_found" do
    fun = fn inv ->
      assert inv.command =~ "'/mnt/data/report.md'"
      {:ok, %CommandResult{stdout: Base.encode64(<<0, 255, "binary!">>), exit_code: 0}}
    end

    assert {:ok, <<0, 255, "binary!">>} = Artifacts.fetch(store(fun), "report.md")

    missing = fn _inv -> {:ok, %CommandResult{stderr: "", exit_code: 3}} end
    assert {:error, :not_found} = Artifacts.fetch(store(missing), "report.md")
  end

  test "put chunks base64 appends within the 64KB command cap, then decodes into place" do
    test_pid = self()
    counter = :counters.new(1, [])

    fun = fn inv ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:cmd, :counters.get(counter, 1), inv.command})
      {:ok, %CommandResult{exit_code: 0}}
    end

    # ~100KB of contents -> base64 ~136k chars -> 3 append commands + 1 decode command.
    contents = :crypto.strong_rand_bytes(100_000)
    assert :ok = Artifacts.put(store(fun), "big.bin", contents)

    assert :counters.get(counter, 1) == 4
    assert_received {:cmd, 1, c1}
    assert String.length(c1) <= 65_536
    assert_received {:cmd, 4, c4}
    assert c4 =~ "base64" or c4 =~ "b64decode"
  end

  test "delete: ok, not_found, and command_failed carry the CommandResult" do
    ok_fun = fn _ -> {:ok, %CommandResult{exit_code: 0}} end
    assert :ok = Artifacts.delete(store(ok_fun), "report.md")

    nf = fn _ -> {:ok, %CommandResult{exit_code: 3}} end
    assert {:error, :not_found} = Artifacts.delete(store(nf), "report.md")

    boom = fn _ -> {:ok, %CommandResult{stderr: "denied", exit_code: 1}} end

    assert {:error, {:command_failed, %CommandResult{stderr: "denied", exit_code: 1}}} =
             Artifacts.delete(store(boom), "report.md")
  end

  test "names outside the safe charset are rejected before any command runs" do
    fun = fn _ -> flunk("no command should run") end

    assert {:error, {:invalid_name, "../etc/passwd"}} =
             Artifacts.fetch(store(fun), "../etc/passwd")

    assert {:error, {:invalid_name, "a'b"}} = Artifacts.delete(store(fun), "a'b")
  end

  test "transport errors pass through" do
    fun = fn _ -> {:error, :timeout} end
    assert {:error, :timeout} = Artifacts.list(store(fun))
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/req_managed_agents/artifacts/agent_core_session_storage_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/req_managed_agents/artifacts/agent_core_session_storage.ex
defmodule ReqManagedAgents.Artifacts.AgentCoreSessionStorage do
  @moduledoc """
  `ReqManagedAgents.Artifacts` store over an AgentCore harness `sessionStorage`
  mount (the no-VPC filesystem type), backed by `InvokeAgentRuntimeCommand`.

  Verbs run python3 one-liners in the session microVM (python3 is guaranteed in
  the base image); file bytes transit the command stream as Base64, so this
  store is for report-scale artifacts, not GB-scale data. Names are restricted
  to `[A-Za-z0-9._-]` (no separators, no traversal). A verb that exits non-zero
  unexpectedly returns `{:error, {:command_failed, %CommandResult{}}}` — stderr
  is never swallowed.
  """
  @behaviour ReqManagedAgents.Artifacts

  alias ReqManagedAgents.Artifact
  alias ReqManagedAgents.AgentCore.CommandResult

  @name_re ~r/^[A-Za-z0-9._-]+$/
  @not_found_exit 3
  # Wire caps "command" at 65_536 chars; leave headroom for the wrapper code.
  @b64_chunk 48_000

  @doc """
  Build a store term. `base_path` is the harness's `sessionStorage` mountPath
  (e.g. `"/mnt/data"`). `command_fun` is injectable for tests; defaults to
  `ReqManagedAgents.AgentCore.Client.invoke_agent_runtime_command/2` on `client`.
  """
  def store(client, agent_runtime_arn, runtime_session_id, base_path, opts \\ []) do
    %{
      arn: agent_runtime_arn,
      sid: runtime_session_id,
      base: String.trim_trailing(base_path, "/"),
      command_fun:
        opts[:command_fun] ||
          fn inv ->
            ReqManagedAgents.AgentCore.Client.invoke_agent_runtime_command(client, inv)
          end
    }
  end

  @impl true
  def list(store, _opts \\ []) do
    code = """
    import json,os,sys
    b=sys.argv[1]
    print(json.dumps([{"name":e.name,"size":e.stat().st_size} for e in os.scandir(b) if e.is_file()]))
    """

    with {:ok, %CommandResult{exit_code: 0, stdout: out}} <- run(store, code, [store.base]),
         {:ok, entries} <- Jason.decode(out) do
      {:ok,
       Enum.map(entries, fn %{"name" => n, "size" => s} ->
         %Artifact{name: n, size: s, ref: store.base <> "/" <> n, raw: nil}
       end)}
    else
      {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
      {:error, %Jason.DecodeError{} = e} -> {:error, {:unexpected_list_output, e}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(store, name, _opts \\ []) do
    with :ok <- validate(name) do
      code = """
      import base64,os,sys
      p=sys.argv[1]
      if not os.path.isfile(p): sys.exit(#{@not_found_exit})
      sys.stdout.write(base64.b64encode(open(p,"rb").read()).decode())
      """

      case run(store, code, [path(store, name)]) do
        {:ok, %CommandResult{exit_code: 0, stdout: b64}} -> Base.decode64(b64, ignore: :whitespace) |> ok_or(:bad_base64)
        {:ok, %CommandResult{exit_code: @not_found_exit}} -> {:error, :not_found}
        {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def put(store, name, contents, _opts \\ []) do
    with :ok <- validate(name) do
      tmp = path(store, name) <> ".rma_b64_part"
      chunks = contents |> Base.encode64() |> chunk_every(@b64_chunk)

      append_code = """
      import sys
      open(sys.argv[1],"a").write(sys.argv[2])
      """

      finish_code = """
      import base64,os,sys
      t,p=sys.argv[1],sys.argv[2]
      open(p,"wb").write(base64.b64decode(open(t).read()))
      os.remove(t)
      """

      with :ok <- run_all(store, append_code, tmp, chunks),
           {:ok, %CommandResult{exit_code: 0}} <- run(store, finish_code, [tmp, path(store, name)]) do
        :ok
      else
        {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(store, name, _opts \\ []) do
    with :ok <- validate(name) do
      code = """
      import os,sys
      p=sys.argv[1]
      if not os.path.isfile(p): sys.exit(#{@not_found_exit})
      os.remove(p)
      """

      case run(store, code, [path(store, name)]) do
        {:ok, %CommandResult{exit_code: 0}} -> :ok
        {:ok, %CommandResult{exit_code: @not_found_exit}} -> {:error, :not_found}
        {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp run(store, python_code, argv) do
    args = Enum.map_join(argv, " ", &("'" <> &1 <> "'"))

    store.command_fun.(%{
      agent_runtime_arn: store.arn,
      runtime_session_id: store.sid,
      command: "python3 -c '#{escape_single_quotes(python_code)}' #{args}"
    })
  end

  defp run_all(_store, _code, _tmp, []), do: :ok

  defp run_all(store, code, tmp, [chunk | rest]) do
    case run(store, code, [tmp, chunk]) do
      {:ok, %CommandResult{exit_code: 0}} -> run_all(store, code, tmp, rest)
      {:ok, %CommandResult{} = r} -> {:error, {:command_failed, r}}
      {:error, reason} -> {:error, reason}
    end
  end

  # POSIX single-quote escaping: close, escaped quote, reopen. argv values are
  # library-controlled (validated names, base_path, base64) — this guards the
  # python SOURCE, which contains no single quotes by construction, defensively.
  defp escape_single_quotes(s), do: String.replace(s, "'", "'\\''")

  defp chunk_every(string, size) do
    string |> :binary.bin_to_list() |> Enum.chunk_every(size) |> Enum.map(&:binary.list_to_bin/1)
  end

  defp path(store, name), do: store.base <> "/" <> name

  defp validate(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end

  defp ok_or({:ok, v}, _tag), do: {:ok, v}
  defp ok_or(:error, tag), do: {:error, tag}
end
```

- [ ] **Step 4: Run tests + full suite; commit**

Run: `mix test test/req_managed_agents/artifacts/agent_core_session_storage_test.exs && mix format && mix test`
Expected: ALL PASS. Also confirm zero compiler warnings (unused aliases in the test file, etc.).

```bash
jj describe -m 'feat(artifacts): AgentCoreSessionStorage store — command-backed, base64-safe, name-validated (MIM-65)' && jj new
```

---

### Task 9: Docs — README Artifacts section, moduledocs, CHANGELOG

**Files:**
- Modify: `README.md`, `lib/req_managed_agents/handler.ex` (moduledoc), `CHANGELOG.md`

**Interfaces:** consumes everything shipped in Tasks 1–8. No code changes.

- [ ] **Step 1: README — add an "Artifacts" section** after the "Files (Claude)" section:

````markdown
## Artifacts — retrieve what your agent built

An agent writes deliverables into its session sandbox; the file's **name** is the only
identity the model ever sees. `ReqManagedAgents.Artifacts` gives one vocabulary over
provider-native session storage — `list`, `fetch`, `put`, `delete`, name-keyed and
session-scoped:

```elixir
alias ReqManagedAgents.Artifacts
alias ReqManagedAgents.Artifacts.{ClaudeFiles, AgentCoreSessionStorage}

# Claude Managed Agents — the Files API, scoped to one session
store = {ClaudeFiles, ClaudeFiles.store(client, session_id)}
{:ok, artifacts} = Artifacts.list(store)             # [%ReqManagedAgents.Artifact{name: "report.md", …}]
{:ok, bytes}     = Artifacts.fetch(store, "report.md")

# Bedrock AgentCore — a sessionStorage mount (no VPC), command-backed
store =
  {AgentCoreSessionStorage,
   AgentCoreSessionStorage.store(ac_client, harness_arn, runtime_session_id, "/mnt/data")}
{:ok, bytes} = Artifacts.fetch(store, "report.md")
```

Handlers receive a `%ReqManagedAgents.SessionInfo{}` (optional 4th argument to
`handle_tool_call/4`) carrying the `session_id`, so a tool can build the store for its
OWN session and fetch what the agent just wrote.

The parity story, honestly: Anthropic offers a provider-hosted blob store (zero infra;
bytes on Anthropic); AWS mounts **your** storage into the microVM (`sessionStorage`
needs nothing; EFS/S3 mounts need VPC mode) plus direct shell access
(`AgentCore.Client.invoke_agent_runtime_command/2` — no model loop, no token cost).
The `sessionStorage` store handles report-scale artifacts (bytes transit the command
stream as Base64); an S3-mount store (host side = plain S3) is designed for 0.4.
Declare mounts via the opaque `environment` field on the provision spec.
````

Also update the "Layers" list: add `- \`ReqManagedAgents.Artifacts\` / \`.Artifact\` / \`.SessionInfo\` — name-keyed session-artifact verbs over provider-native stores + the runtime identity handed to handlers.`

- [ ] **Step 2: Handler moduledoc** — append one paragraph:

```markdown
  Both callbacks have optional richer forms — `handle_tool_call/4` and
  `handle_event/3` — that additionally receive the `ReqManagedAgents.SessionInfo`
  (session id, provider module) for the running session. Export the higher arity
  and it is preferred; otherwise the classic form is called.
```

- [ ] **Step 3: CHANGELOG** — add above `## v0.2.1`:

```markdown
## v0.3.0 (unreleased)

### Added
- `ReqManagedAgents.Artifacts` — one vocabulary (`list`/`fetch`/`put`/`delete`,
  name-keyed, session-scoped) over provider-native session storage, with two stores:
  `Artifacts.ClaudeFiles` (Anthropic Files API) and `Artifacts.AgentCoreSessionStorage`
  (AgentCore `sessionStorage` mount, command-backed, report-scale). `%Artifact{}` struct.
- `%SessionInfo{}` handed to handlers via optional `Handler.handle_tool_call/4` and
  `handle_event/3` (existing 3-/2-arity handlers work unchanged);
  `SessionResult.session_id`.
- CMA Files API completion: `Client.list_files/2` (session-scoped via `scope_id`) and
  `Client.delete_file/2`, on `Client.Behaviour` too.
- AgentCore: opaque `environment`/`environment_variables` provision-spec fields
  (filesystem mounts, custom containers, env vars — pass-through, spec-hash covered) and
  `Client.invoke_agent_runtime_command/2` (direct microVM shell; streamed
  stdout/stderr via optional `on_output`; `%AgentCore.CommandResult{}`).
```

(Version bump itself happens in Task 12.)

- [ ] **Step 4: Gates + commit**

Run: `MIX_ENV=dev mix docs --warnings-as-errors && mix format && mix test && mix credo --strict`
Expected: all clean.

```bash
jj describe -m 'docs: Artifacts vocabulary, SessionInfo callbacks, files/environment/command surfaces' && jj new
```

---

### Task 10: IAM — allow `InvokeAgentRuntimeCommand` (CONTROLLER-EXECUTED, not a subagent task)

**Files:** none in-repo (AWS account 819613816573; policy `rma-ci-harness-lifecycle`). Update `docs/aws-ci-setup.md` with the new action (one line in its action inventory).

- [ ] **Step 1 (controller):** fetch the current policy document, add `"bedrock-agentcore:InvokeAgentRuntimeCommand"` to the statement that carries `InvokeHarness`/`InvokeAgentRuntime` (same Resource list — both `runtime/*` and `harness/*` ARN families, per the dual-naming precedent), and `create-policy-version --set-as-default` (prune the oldest version if at the 5-version cap).
- [ ] **Step 2:** document the action in `docs/aws-ci-setup.md`, commit with jj.

---

### Task 11: Live canary legs — CMA files, AgentCore command, sessionStorage mount

**Files:**
- Modify: `test/live/live_smoke_test.exs` (append three tests; do NOT run live tests in the dev loop — no creds)

**Interfaces:** consumes Tasks 3–8 public surfaces exactly as named. Follow the file's existing conventions (`@moduletag :live`, generous `@tag timeout:`, `IO.inspect` labels, env-overridable models, try/after teardown).

- [ ] **Step 1: Append the three tests**

```elixir
  @tag timeout: 240_000
  @tag :live_cma_artifacts
  test "CMA artifacts: agent writes a file → Artifacts list/fetch/delete round-trip" do
    alias ReqManagedAgents.Artifacts
    alias ReqManagedAgents.Artifacts.ClaudeFiles
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)
    client = ReqManagedAgents.new()

    {:ok, %{"id" => env_id}} =
      ReqManagedAgents.Client.create_environment(client, %{
        name: "rma-v03-artifacts",
        config: %{type: "cloud", networking: %{type: "unrestricted"}}
      })

    # The built-in toolset provides the `write` tool the agent needs.
    {:ok, %{"id" => agent_id}} =
      ReqManagedAgents.Client.create_agent(client, %{
        name: "rma-v03-artifacts",
        model: System.get_env("CMA_LIVE_MODEL", "claude-haiku-4-5"),
        system:
          "When asked to save a note, write EXACTLY the requested text to the requested " <>
            "filename in the working directory, then stop.",
        tools: [%{type: "agent_toolset_20260401"}]
      })

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn, session_id: session_id}} =
             ReqManagedAgents.run_to_completion(
               client: client,
               agent_id: agent_id,
               environment_id: env_id,
               prompt: "Save a note: write the text 'artifact-canary-ok' to note.txt",
               handler: Handler,
               timeout: 180_000
             )

    assert is_binary(session_id)
    store = {ClaudeFiles, ClaudeFiles.store(client, session_id)}

    {:ok, artifacts} = Artifacts.list(store)
    IO.inspect(artifacts, label: "LIVE CMA artifacts")
    assert Enum.any?(artifacts, &(&1.name == "note.txt"))

    assert {:ok, bytes} = Artifacts.fetch(store, "note.txt")
    assert bytes =~ "artifact-canary-ok"

    assert :ok = Artifacts.delete(store, "note.txt")
  end

  @tag timeout: 600_000
  @tag :live_bedrock_command
  test "AgentCore command: exec into the session microVM — stdout, stderr, exit codes" do
    alias ReqManagedAgents.Providers.BedrockAgentCore
    alias ReqManagedAgents.AgentCore.{Client, CommandResult}
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role =
      System.get_env("HARNESS_EXECUTION_ROLE_ARN") ||
        "arn:aws:iam::819613816573:role/rma-ci-harness-exec"

    spec = %{
      system_prompt: "You are a terse assistant.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live"
      )

    try do
      client = Client.new()
      sid = "live-cmd-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      assert {:ok, %CommandResult{exit_code: 0} = ok} =
               Client.invoke_agent_runtime_command(client, %{
                 agent_runtime_arn: handle.harness_arn,
                 runtime_session_id: sid,
                 command: "echo canary-stdout && echo canary-stderr 1>&2"
               })

      IO.inspect(ok, label: "LIVE command result")
      assert ok.stdout =~ "canary-stdout"
      assert ok.stderr =~ "canary-stderr"

      assert {:ok, %CommandResult{exit_code: 7}} =
               Client.invoke_agent_runtime_command(client, %{
                 agent_runtime_arn: handle.harness_arn,
                 runtime_session_id: sid,
                 command: "exit 7"
               })
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE command-leg teardown"
      )
    end
  end

  @tag timeout: 600_000
  @tag :live_bedrock_mount
  test "AgentCore sessionStorage mount: environment pass-through + Artifacts put/fetch round-trip" do
    alias ReqManagedAgents.Providers.BedrockAgentCore
    alias ReqManagedAgents.Artifacts
    alias ReqManagedAgents.Artifacts.AgentCoreSessionStorage
    {:ok, _} = Application.ensure_all_started(:req_managed_agents)

    role =
      System.get_env("HARNESS_EXECUTION_ROLE_ARN") ||
        "arn:aws:iam::819613816573:role/rma-ci-harness-exec"

    spec = %{
      system_prompt: "You are a terse assistant.",
      tools: [],
      terminal_tool: nil,
      model_config: %{
        "bedrockModelConfig" => %{
          "modelId" => System.get_env("BEDROCK_LIVE_MODEL_ID", "nvidia.nemotron-super-3-120b")
        }
      },
      # MIM-65: the opaque environment pass-through, sessionStorage = the no-VPC mount.
      environment: %{
        "agentCoreRuntimeEnvironment" => %{
          "filesystemConfigurations" => [%{"sessionStorage" => %{"mountPath" => "/mnt/data"}}]
        }
      }
    }

    {:ok, handle} =
      ReqManagedAgents.provision(BedrockAgentCore, spec,
        execution_role_arn: role,
        name_prefix: "rma_live"
      )

    try do
      client = ReqManagedAgents.AgentCore.Client.new()
      sid = "live-mnt-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      store =
        {AgentCoreSessionStorage,
         AgentCoreSessionStorage.store(client, handle.harness_arn, sid, "/mnt/data")}

      contents = "mount-canary " <> Base.encode64(:crypto.strong_rand_bytes(64))
      assert :ok = Artifacts.put(store, "canary.txt", contents)

      {:ok, listed} = Artifacts.list(store)
      IO.inspect(listed, label: "LIVE mount artifacts")
      assert Enum.any?(listed, &(&1.name == "canary.txt"))

      assert {:ok, ^contents} = Artifacts.fetch(store, "canary.txt")
      assert :ok = Artifacts.delete(store, "canary.txt")
    after
      IO.inspect(ReqManagedAgents.teardown(BedrockAgentCore, handle),
        label: "LIVE mount-leg teardown"
      )
    end
  end
```

- [ ] **Step 2: Compile-check (live excluded) + full suite + commit**

Run: `mix test test/live/live_smoke_test.exs && mix test`
Expected: `0 tests, N excluded` for the live file; full suite green.

```bash
jj describe -m 'test(live): 0.3.0 canary legs — CMA artifacts, AgentCore command, sessionStorage mount' && jj new
```

**Note for the controller:** the CMA leg relies on `run_to_completion`'s result carrying `session_id` (Task 2) and on the built-in `write` tool putting the file where the scoped Files listing sees it — this is the assumption the live run validates (the unit suite cannot). If the live listing comes back empty, the diagnosis order is: (1) does the scoped list need a different param name than `scope_id`; (2) does the sandbox write surface as a session file at all. `Artifact.raw` and the leg's `IO.inspect` output carry everything needed to adjust.

---

### Task 12: QA sweep + version 0.3.0

**Files:**
- Modify: `mix.exs` (`@version "0.3.0"`), `CHANGELOG.md` (`## v0.3.0 (unreleased)` → `## v0.3.0 (<today's date>)`)

- [ ] **Step 1:** bump `@version` to `"0.3.0"`; date-stamp the CHANGELOG heading.
- [ ] **Step 2: Full offline gate**, each must pass:

```bash
mix format --check-formatted
mix test
mix credo --strict
MIX_ENV=dev mix docs --warnings-as-errors
mix dialyzer
mix hex.build          # expect req_managed_agents-0.3.0.tar
```

- [ ] **Step 3: Commit**

```bash
jj describe -m 'release: v0.3.0 — session artifacts' && jj new
```

---

## Execution notes for the coordinator

- Workspace: `.claude/worktrees/rma-030-artifacts/` (jj), spec + plan committed on main.
- Task order is the dependency order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → [10 controller] → 11 → 12.
- Task 10 is controller-executed (AWS CLI, account creds) — do not dispatch a subagent for it.
- After Task 12: push bookmark `ryan/rma-030-session-artifacts`, PR titled
  `MIM-65: feat: RMA 0.3.0 — session artifacts (Artifacts vocabulary, SessionInfo, files + environment + command APIs)`,
  body ends with `Closes #29`, `Closes #30` (GitHub, own lines) and the plain-text last line
  `Closes MIM-65, MIM-66 and MIM-67` (Linear).
- After merge: dispatch the canary (validates the three live legs + the ARN-in-path signing risk from Task 5), then tag `v0.3.0` per the established release flow — coordinate with the user before canary/tag (AWS spend + publish).
