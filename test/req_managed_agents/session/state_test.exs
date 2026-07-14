defmodule ReqManagedAgents.Session.StateTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Session.State
  alias ReqManagedAgents.Usage

  describe "struct defaults" do
    test "builds with the expected boolean/counter/collection defaults" do
      assert %State{
               delta?: false,
               kicked_off: false,
               seen: nil,
               reconnect_attempts: 0,
               events: [],
               turn_events: [],
               live_forwarded: 0,
               turns: 0,
               max_turns: 50,
               custom_tool_uses: [],
               server_tool_uses: [],
               max_reprompts: 2,
               reprompts_left: 2,
               usage: nil
             } = %State{}
    end

    test "all other fields default to nil" do
      assert %State{
               provider: nil,
               mode: nil,
               conn: nil,
               info: nil,
               opts: nil,
               handler: nil,
               context: nil,
               caller: nil,
               notify: nil,
               meta: nil,
               ref: nil,
               consumer: nil,
               poll_task: nil,
               turn_guard: nil,
               enforced_terminal_tool: nil,
               pending_user_message: nil
             } = %State{}
    end

    test "accepts init-shaped values (seen: MapSet, usage: %Usage{})" do
      state = %State{seen: MapSet.new(["a"]), usage: %Usage{input_tokens: 1, output_tokens: 2}}

      assert MapSet.member?(state.seen, "a")
      assert %Usage{input_tokens: 1, output_tokens: 2} = state.usage
    end
  end
end
