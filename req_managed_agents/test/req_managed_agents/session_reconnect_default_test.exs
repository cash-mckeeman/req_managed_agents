defmodule ReqManagedAgents.SessionReconnectDefaultTest do
  @moduledoc """
  Issue #79: `resumed?/1 == true` routes Session through :resume → :reconnect, which
  called `provider.reconnect/3` unconditionally. A reattach-capable request_response
  provider that omits the optional callback died with :undef. Session now defaults an
  unimplemented reconnect/3 to `{:ok, conn, [], seen}`.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.FakeProviders.ResumeNoReconnect
  alias ReqManagedAgents.{Session, SessionResult}

  test "resume with a provider that omits reconnect/3 completes instead of raising :undef" do
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    assert {:ok, %SessionResult{terminal: :end_turn}} =
             Session.run(ResumeNoReconnect,
               session_id: "sess-nr",
               prompt: "second turn",
               handler: handler,
               test: self()
             )
  end

  test "the resumed prompt is still delivered through user_input on the default path" do
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    {:ok, _} =
      Session.run(ResumeNoReconnect,
        session_id: "sess-nr",
        prompt: "hello again",
        handler: handler,
        test: self()
      )

    assert_receive {:polled, {:user, "hello again"}}
  end
end
