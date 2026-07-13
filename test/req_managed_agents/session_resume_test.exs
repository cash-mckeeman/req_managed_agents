defmodule ReqManagedAgents.SessionResumeTest do
  @moduledoc """
  The reattach seam (issue #66): `Session.run/2` resuming an existing session
  (`session_id:` set) also delivers `opts[:prompt]` as a fresh `user.message` once
  reconnect consolidates to idle with nothing pending — without disturbing the
  existing pending-tool-use redrive.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.FakeProviders.{
    FreshLiveThenDrop,
    ResumeReattach,
    ResumeRedriveThenReattach
  }

  alias ReqManagedAgents.{Session, ToolUse}

  test "resume with a prompt, idle and no pending, delivers it as a user message and drives to terminal" do
    test = self()
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn}} =
             Session.run(ResumeReattach,
               session_id: "sess-1",
               prompt: "second turn",
               handler: handler,
               test: test
             )

    assert_receive {:delivered, "second turn"}
  end

  test "resume without a prompt sends no user message" do
    test = self()
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    {:ok, pid} =
      Session.start_link(ResumeReattach, session_id: "sess-1", handler: handler, test: test)

    refute_receive {:delivered, _}, 200
    assert Process.alive?(pid)
  end

  test "resume mid-requires_action ignores the prompt and redispatches pending first" do
    test = self()

    handler = fn name, input, _ctx ->
      send(test, {:tool, name, input})
      {:ok, "r"}
    end

    assert {:ok, %ReqManagedAgents.SessionResult{terminal: :end_turn}} =
             Session.run(ResumeReattach,
               session_id: "sess-1",
               prompt: "ignored",
               handler: handler,
               test: test,
               pending: [%ToolUse{id: "t1", name: "echo", input: %{"x" => 1}}]
             )

    assert_receive {:tool, "echo", %{"x" => 1}}
    refute_receive {:delivered, "ignored"}, 200
  end

  # Defect 1 regression (review-found, not covered by the original #66 suite): a FRESH
  # (no session_id) long-lived session armed `pending_user_message` from `opts[:prompt]`
  # unconditionally at init — harmless for a synchronous run/2 (it never reconnects), but
  # a live session that kicks off, goes idle, then reconnects after a stream drop would
  # reach the SAME idle-reconnect branch a resume uses and redeliver the kickoff prompt as
  # a brand-new user.message. Must NOT double-send.
  test "a fresh live session does not re-deliver its kickoff prompt after a stream drop and reconnect" do
    test = self()
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    {:ok, pid} =
      Session.start_link(FreshLiveThenDrop, prompt: "hello", handler: handler, test: test)

    # The legitimate kickoff delivery.
    assert_receive {:delivered, "hello"}, 2000
    # The stream drop + reconnect (~500ms backoff) must NOT deliver it again.
    refute_receive {:delivered, "hello"}, 1500
    assert Process.alive?(pid)
  end

  # Defect 2 regression: the resume-deliver branch in handle_info(:reconnect, …) must reset
  # turns/accumulators the same way a live follow-up (handle_cast({:message, …})) does — a
  # follow-up (or reattach-delivered) message starts a fresh request. Drive a resume that
  # first redrives a pending tool use (turns 0 -> 1), then — via a second simulated stream
  # drop — reconnects again to idle with the prompt still pending. With `max_turns: 1`,
  # skipping the reset means the delivered turn's turns counter (2) exceeds max_turns and the
  # session terminates with `{:max_turns_exceeded, 1}` instead of a clean :end_turn.
  test "a resume-delivered message resets turns like a live follow-up, so it starts a fresh request" do
    test = self()

    handler = fn name, input, _ctx ->
      send(test, {:tool, name, input})
      {:ok, "r"}
    end

    {:ok, pid} =
      Session.start_link(ResumeRedriveThenReattach,
        session_id: "sess-1",
        prompt: "second",
        max_turns: 1,
        handler: handler,
        notify: test,
        test: test,
        pending: [%ToolUse{id: "t1", name: "echo", input: %{"x" => 1}}]
      )

    assert_receive {:tool, "echo", %{"x" => 1}}, 2000

    # First reconnect: pending tool redrive completes turn 1.
    assert_receive {:managed_agents_session,
                    %ReqManagedAgents.SessionResult{terminal: :end_turn, turns: 1}},
                   2000

    # Second reconnect: idle, delivers the pending prompt.
    assert_receive {:delivered, "second"}, 2000

    # The delivered turn must be a FRESH request (turns reset to 0 then incremented to 1),
    # not turns: 2 tripping max_turns: 1.
    assert_receive {:managed_agents_session,
                    %ReqManagedAgents.SessionResult{terminal: :end_turn, turns: 1}},
                   2000

    assert Process.alive?(pid)
  end
end
