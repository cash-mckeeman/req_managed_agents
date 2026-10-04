defmodule ReqManagedAgents.SessionLoopTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.FakeProviders.{RequestResponse, Streaming}
  alias ReqManagedAgents.Session
  alias ReqManagedAgents.{SessionResult, ToolUse, Usage}

  @turn1 [
    %{"type" => "tool", "id" => "t1", "name" => "echo", "input" => %{"x" => 1}},
    %{"type" => "stop", "terminal" => :requires_action}
  ]
  @turn2 [%{"type" => "stop", "terminal" => :end_turn}]

  for provider <- [RequestResponse, Streaming] do
    @provider provider
    test "#{inspect(provider)}: drives requires_action → tools → resume → end_turn" do
      test = self()

      handler = fn name, input, _ctx ->
        send(test, {:tool_ran, name, input})
        {:ok, "result-#{name}"}
      end

      assert {:ok, result} = Session.run(@provider, handler: handler, turns: [@turn1, @turn2])

      assert %SessionResult{
               terminal: :end_turn,
               turns: 2,
               custom_tool_uses: [%ToolUse{}],
               usage: %Usage{input_tokens: 2, output_tokens: 2, raw: [_, _]}
             } = result

      # raw events from BOTH turns are accumulated verbatim
      assert result.events == @turn1 ++ @turn2
      # the local tool ran with the right args
      assert_received {:tool_ran, "echo", %{"x" => 1}}
    end

    test "#{inspect(provider)}: a turn that ends immediately returns :end_turn with no tools" do
      assert {:ok, %{terminal: :end_turn}} =
               Session.run(@provider, handler: fn _, _, _ -> {:ok, "x"} end, turns: [@turn2])

      refute_received {:tool_ran, _, _}
    end
  end
end
