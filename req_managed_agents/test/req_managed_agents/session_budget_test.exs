defmodule ReqManagedAgents.SessionBudgetTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.{FakeProviders, Session}
  alias ReqManagedAgents.Providers.{BedrockAgentCore, ClaudeManagedAgents, Local}

  @budget %{max_list_cost_cents: 125}

  # Every provider module in lib/, and the fakes a host test might substitute: only
  # Claude Managed Agents can enforce a spend cap, so the rest must refuse one at start
  # rather than run uncapped.
  for provider <- [
        BedrockAgentCore,
        Local,
        FakeProviders.RequestResponse,
        FakeProviders.Streaming
      ] do
    test "#{inspect(provider)} rejects :budget at start" do
      test = self()

      assert {:error, :budget_unsupported} =
               Session.run(unquote(provider),
                 handler: fn _, _, _ -> {:ok, ""} end,
                 spec: %{
                   name: "a",
                   system_prompt: "s",
                   tools: [],
                   terminal_tool: nil,
                   model_config: "m"
                 },
                 chat_fun: fn _ ->
                   send(test, :model_called)
                   {:ok, %{}}
                 end,
                 turns: [],
                 budget: @budget,
                 timeout: 1_000
               )

      refute_received :model_called
    end
  end

  test "an invalid budget is also refused on an unsupporting provider" do
    assert {:error, :budget_unsupported} =
             Session.run(Local,
               handler: fn _, _, _ -> {:ok, ""} end,
               chat_fun: fn _ -> {:ok, %{}} end,
               budget: :garbage
             )
  end

  test "Claude Managed Agents declares support" do
    assert ClaudeManagedAgents.supports_budget?()
  end
end
