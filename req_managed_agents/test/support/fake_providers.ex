defmodule ReqManagedAgents.FakeProviders do
  @moduledoc false
  # Fake providers for the Session loop tests. A "turn" is a list of fake events:
  #   %{"type" => "tool", "id" => , "name" => , "input" => }  — a custom (client-side) tool use
  #   %{"type" => "stop", "terminal" => :requires_action | :end_turn | :terminated}

  defmodule Shared do
    @moduledoc false
    alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

    def normalize(events) do
      customs =
        for %{"type" => "tool"} = e <- events,
            do: %ToolUse{id: e["id"], name: e["name"], input: e["input"]}

      terminal =
        Enum.find_value(events, :terminated, fn
          %{"type" => "stop", "terminal" => t} -> t
          _ -> nil
        end)

      %TurnResult{
        terminal: terminal,
        stop_reason: to_string(terminal),
        custom_tool_uses: customs,
        server_tool_uses: [],
        text: "",
        usage: %Usage{input_tokens: 1, output_tokens: 1, raw: [%{}]},
        events: events
      }
    end
  end

  defmodule RequestResponse do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{turns: opts[:turns] || []}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: [t | rest]} = c, _input), do: {:ok, t, %{c | turns: rest}}

    def poll_turn(%{turns: []} = c, _input),
      do: {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}

    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  defmodule Streaming do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok, agent} = Agent.start_link(fn -> opts[:turns] || [] end)
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def push_input(conn, _input) do
      turn =
        Agent.get_and_update(conn.agent, fn
          [t | rest] -> {t, rest}
          [] -> {[%{"type" => "stop", "terminal" => :end_turn}], []}
        end)

      Enum.each(turn, fn ev ->
        send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
      end)

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # Streaming fake that drops the very first push (simulating a mid-turn stream loss), then
  # serves `opts[:turns]` normally; its `reconnect/3` returns `opts[:pending]` to re-drive.
  defmodule ReconnectingStreaming do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{turns: opts[:turns] || [], pending: opts[:pending] || [], dropped: false}
        end)

      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def push_input(conn, _input) do
      drop? =
        Agent.get_and_update(conn.agent, fn st -> {not st.dropped, %{st | dropped: true}} end)

      if drop? do
        send(conn.subscriber, {:managed_agents, conn.ref, {:error, :stream_dropped}})
      else
        turn =
          Agent.get_and_update(conn.agent, fn
            %{turns: [t | rest]} = st -> {t, %{st | turns: rest}}
            %{turns: []} = st -> {[%{"type" => "stop", "terminal" => :end_turn}], st}
          end)

        Enum.each(turn, fn ev ->
          send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
        end)
      end

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    def reconnect(conn, subscriber, seen) do
      pending = Agent.get(conn.agent, & &1.pending)
      {:ok, %{conn | ref: make_ref(), subscriber: subscriber}, pending, seen}
    end

    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # A resumed session (session_id: set → open/2 answers `resume: true`, no :connected —
  # matching the real providers' resume shape). `reconnect/3` answers `opts[:pending]`
  # unconditionally (both [] and a non-empty list, so one fake covers the reattach-seam's
  # idle-no-pending case AND its mid-requires_action case — issue #66). `push_input/2` records
  # any `user.message`-shaped input it sees (`{:user, text}`) to `opts[:test]`, then always
  # answers with a single end_turn so the driven turn (message delivery OR pending redrive)
  # reaches a terminal.
  defmodule ResumeReattach do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok,
       %{
         resume: true,
         subscriber: subscriber,
         ref: nil,
         test: opts[:test],
         pending: opts[:pending] || []
       }}
    end

    @impl true
    def kickoff_input(opts), do: {:user, opts[:prompt] || "Begin."}
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}

    @impl true
    def reconnect(conn, subscriber, seen) do
      {:ok, %{conn | subscriber: subscriber, ref: make_ref()}, conn.pending, seen}
    end

    @impl true
    def push_input(conn, input) do
      case input do
        {:user, text} -> send(conn.test, {:delivered, text})
        _ -> :ok
      end

      ev = %{"type" => "stop", "terminal" => :end_turn}
      send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(conn), do: !!conn.resume
  end

  # A FRESH (no session_id) live session — open/2 answers no `:resume` key at all,
  # matching the real providers' fresh-open shape, and emits :connected so kickoff fires
  # normally. The kickoff turn ends immediately (:end_turn, idle); that same push also
  # triggers exactly ONE simulated stream drop (an Agent-tracked flag guards against a
  # second one), forcing the live session's reconnect path to run while genuinely idle —
  # exercising the reattach seam (#66) on a session that was NEVER a resume. `reconnect/3`
  # always answers idle/no-pending. `push_input/2` records any `user.message`-shaped input
  # (`{:user, text}`) to `opts[:test]` — used to prove a fresh session's kickoff prompt is
  # NOT redelivered once the post-drop reconnect consolidates to idle (defect 1).
  defmodule FreshLiveThenDrop do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}

    @impl true
    def open(opts, subscriber) do
      {:ok, dropped?} = Agent.start_link(fn -> false end)
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{subscriber: subscriber, ref: ref, test: opts[:test], dropped?: dropped?}}
    end

    @impl true
    def kickoff_input(opts), do: {:user, opts[:prompt] || "Begin."}
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}

    @impl true
    def reconnect(conn, subscriber, seen) do
      {:ok, %{conn | subscriber: subscriber, ref: make_ref()}, [], seen}
    end

    @impl true
    def push_input(conn, input) do
      case input do
        {:user, text} -> send(conn.test, {:delivered, text})
        _ -> :ok
      end

      send(
        conn.subscriber,
        {:managed_agents, conn.ref, {:event, %{"type" => "stop", "terminal" => :end_turn}}}
      )

      already_dropped? = Agent.get_and_update(conn.dropped?, fn d -> {d, true} end)

      unless already_dropped?,
        do: send(conn.subscriber, {:managed_agents, conn.ref, {:error, :dropped}})

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # A resume (session_id: set) carrying BOTH pending tool uses and a new prompt. The
  # first reconnect redrives the pending tool use (turns: 0 -> 1, terminal :end_turn); that
  # redrive's push ALSO triggers a second simulated stream drop (an Agent tracks whether the
  # pending batch was already redriven, so the SECOND reconnect answers idle/no-pending). That
  # second reconnect then runs the reattach seam's idle branch (#66) with a non-zero turn
  # count already accumulated — exercising defect 2: the resume-deliver branch must reset
  # turns/accumulators the same way a live follow-up (`handle_cast({:message, …})`) does, or
  # the delivered turn inherits the redrive's turn count and `max_turns` trips early.
  defmodule ResumeRedriveThenReattach do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}

    @impl true
    def open(opts, subscriber) do
      {:ok, agent} = Agent.start_link(fn -> %{pending: opts[:pending] || [], redriven: false} end)
      {:ok, %{resume: true, subscriber: subscriber, ref: nil, test: opts[:test], agent: agent}}
    end

    @impl true
    def kickoff_input(opts), do: {:user, opts[:prompt] || "Begin."}
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}

    @impl true
    def reconnect(conn, subscriber, seen) do
      pending =
        Agent.get_and_update(conn.agent, fn st ->
          if st.redriven, do: {[], st}, else: {st.pending, %{st | redriven: true}}
        end)

      {:ok, %{conn | subscriber: subscriber, ref: make_ref()}, pending, seen}
    end

    @impl true
    def push_input(conn, input) do
      case input do
        {:user, text} -> send(conn.test, {:delivered, text})
        _ -> :ok
      end

      send(
        conn.subscriber,
        {:managed_agents, conn.ref, {:event, %{"type" => "stop", "terminal" => :end_turn}}}
      )

      # Only the pending-redrive push triggers the second drop — never the message
      # deliver, or this would loop forever.
      if match?({:resume, _}, input) do
        send(conn.subscriber, {:managed_agents, conn.ref, {:error, :dropped}})
      end

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(conn), do: !!conn.resume
  end

  # open/2 fails — to assert the Session surfaces the provider error verbatim.
  defmodule FailingOpen do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:error, {:create_session_failed, :boom}}
    @impl true
    def kickoff_input(_), do: :k
    @impl true
    def user_input(_), do: :u
    @impl true
    def resume_input(_, results), do: {:resume, results}
    @impl true
    def push_input(_, _), do: :ok
    @impl true
    def turn_boundary?(_), do: true
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # poll_turn/2 RAISES — to assert the Session surfaces it as {:error, _} without killing the caller.
  defmodule CrashingPoll do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(_opts, _sub), do: {:ok, %{}}
    @impl true
    def kickoff_input(_), do: :k
    @impl true
    def user_input(_), do: :u
    @impl true
    def resume_input(_, results), do: {:resume, results}
    @impl true
    def poll_turn(_conn, _input), do: raise("boom in poll_turn")
    @impl true
    defdelegate normalize(events), to: Shared
    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  # Streaming fake exercising the `pending_tool_uses/1` recovery seam (issue #61): a
  # `requires_action` batch can resolve to zero `custom_tool_uses` when the tool uses it
  # references live in an EARLIER already-processed batch. `resume_input/2`'s echoes
  # (`"tool_result"`) ride the wire so `pending_tool_uses/1` can compute "unanswered" purely
  # from the session's own accumulated history — no extra round trip, mirroring
  # `Consolidate.unanswered_tool_uses/1` in the real `ClaudeManagedAgents` provider.
  defmodule PendingRecoveryStreaming do
    @moduledoc false
    @behaviour ReqManagedAgents.Provider
    alias ReqManagedAgents.ToolUse

    @impl true
    def mode, do: :streaming
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, subscriber) do
      {:ok, agent} = Agent.start_link(fn -> %{turns: opts[:turns] || [], stash: []} end)
      ref = make_ref()
      send(subscriber, {:managed_agents, ref, :connected})
      {:ok, %{agent: agent, subscriber: subscriber, ref: ref}}
    end

    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results),
      do: for(r <- results, do: %{"type" => "tool_result", "id" => r.tool_use_id})

    @impl true
    def push_input(conn, input) do
      # Only the FIRST echo of a multi-result resume is delivered on this push; the rest are
      # held back and flushed on the NEXT push — reproducing the real defect's shape, where a
      # multi-result resume's answers don't all land before the server re-notifies on the
      # still-outstanding ones (a `requires_action` batch resolving to zero `custom_tool_uses`).
      echoed = if is_list(input), do: input, else: []

      {send_now, held_back} =
        case echoed do
          [first | rest] when rest != [] -> {[first], rest}
          other -> {other, []}
        end

      {to_send, turn} =
        Agent.get_and_update(conn.agent, fn %{turns: turns, stash: stash} ->
          {t, turns2} =
            case turns do
              [t | r] -> {t, r}
              [] -> {[%{"type" => "stop", "terminal" => :end_turn}], []}
            end

          {{stash ++ send_now, t}, %{turns: turns2, stash: held_back}}
        end)

      Enum.each(to_send ++ turn, fn ev ->
        send(conn.subscriber, {:managed_agents, conn.ref, {:event, ev}})
      end)

      :ok
    end

    @impl true
    def turn_boundary?(%{"type" => "stop"}), do: true
    def turn_boundary?(_), do: false
    @impl true
    defdelegate normalize(events), to: Shared

    @impl true
    def pending_tool_uses(events) do
      answered = for %{"type" => "tool_result", "id" => id} <- events, into: MapSet.new(), do: id

      for %{"type" => "tool", "id" => id, "name" => name, "input" => input} <- events,
          not MapSet.member?(answered, id),
          do: %ToolUse{id: id, name: name, input: input}
    end

    @impl true
    def session_id(_conn), do: nil
    @impl true
    def ref(conn), do: conn.ref
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
  end

  defmodule ResumeNoReconnect do
    @moduledoc false
    # A request_response provider that reports an existing session (resumed? true)
    # but deliberately omits reconnect/3 — the #79 trap. Session must complete the
    # resume via the safe-default instead of raising :undef.
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{turns: opts[:turns] || [], test: opts[:test]}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: [t | rest]} = c, input) do
      if is_pid(c.test), do: send(c.test, {:polled, input})
      {:ok, t, %{c | turns: rest}}
    end

    def poll_turn(%{turns: []} = c, input) do
      if is_pid(c.test), do: send(c.test, {:polled, input})
      {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}
    end

    @impl true
    defdelegate normalize(events), to: ReqManagedAgents.FakeProviders.Shared
    @impl true
    def session_id(_conn), do: "sess-nr"
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: true
  end

  defmodule WithTranscript do
    @moduledoc false
    # RequestResponse plus a transcript/1 — proves Session embeds the provider's
    # client-held history into SessionResult at terminal.
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_spec, _opts), do: {:error, :not_implemented}
    @impl true
    def open(opts, _subscriber), do: {:ok, %{turns: opts[:turns] || []}}
    @impl true
    def kickoff_input(_opts), do: :kickoff
    @impl true
    def user_input(text), do: {:user, text}
    @impl true
    def resume_input(_uses, results), do: {:resume, results}
    @impl true
    def poll_turn(%{turns: [t | rest]} = c, _input), do: {:ok, t, %{c | turns: rest}}

    def poll_turn(%{turns: []} = c, _input),
      do: {:ok, [%{"type" => "stop", "terminal" => :end_turn}], c}

    @impl true
    defdelegate normalize(events), to: ReqManagedAgents.FakeProviders.Shared
    @impl true
    def session_id(_conn), do: "sess-wt"
    @impl true
    def ref(_conn), do: nil
    @impl true
    def consumer(_conn), do: nil
    @impl true
    def resumed?(_conn), do: false
    @impl true
    def transcript(_conn), do: [%{"role" => "user", "content" => "canned"}]
  end

  defmodule TeardownProbe do
    @moduledoc false
    # Deliberately NOT a full Provider — exists only to prove the facade's
    # teardown/3 finds teardown/2 on a not-yet-loaded module (it lives in
    # test/support so it has a real .beam the code server can reload after a
    # delete/purge in the test).
    def teardown(_handle, _opts), do: {:error, :probe}
  end
end
