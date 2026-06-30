# test/req_managed_agents/provider_conformance_test.exs
defmodule ReqManagedAgents.ProviderConformanceTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Provider
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: AgentCore
  alias ReqManagedAgents.Providers.ClaudeManagedAgents, as: ManagedAgents

  @providers [AgentCore, ManagedAgents]

  # A requires_action turn expressed in each backend's wire vocabulary.
  defp requires_action_fixture(AgentCore) do
    [
      %{"contentBlockStart" => %{"contentBlockIndex" => 0, "start" => %{"toolUse" => %{"toolUseId" => "x1", "name" => "lookup"}}}},
      %{"contentBlockDelta" => %{"contentBlockIndex" => 0, "delta" => %{"toolUse" => %{"input" => ~s({"q":"hi"})}}}},
      %{"messageStop" => %{"stopReason" => "tool_use"}}
    ]
  end

  defp requires_action_fixture(ManagedAgents) do
    [
      %{"type" => "agent.custom_tool_use", "id" => "x1", "name" => "lookup", "input" => %{"q" => "hi"}},
      %{"type" => "session.status_idle", "stop_reason" => %{"type" => "requires_action", "event_ids" => ["x1"]}}
    ]
  end

  test "every provider implements all Provider callbacks" do
    for provider <- @providers do
      # function_exported?/3 returns false for an UNLOADED module; ensure each provider
      # is loaded first so this assertion does not depend on suite ordering/seed.
      Code.ensure_loaded!(provider)

      for {fun, arity} <- Provider.behaviour_info(:callbacks) do
        assert function_exported?(provider, fun, arity),
               "#{inspect(provider)} missing #{fun}/#{arity}"
      end
    end
  end

  test "every provider normalizes its requires_action fixture to a well-formed turn_outcome" do
    for provider <- @providers do
      outcome = provider.normalize(requires_action_fixture(provider))

      assert outcome.terminal == :requires_action
      assert [%{id: id, name: name, input: input}] = outcome.custom_tool_uses
      assert is_binary(id) and is_binary(name) and is_map(input)
      assert is_list(outcome.server_tool_uses)
      assert is_binary(outcome.text)
    end
  end

  test "custom_tool_uses is non-empty iff terminal is :requires_action" do
    for provider <- @providers do
      ra = provider.normalize(requires_action_fixture(provider))
      assert ra.custom_tool_uses != []
    end

    assert AgentCore.normalize([%{"messageStop" => %{"stopReason" => "end_turn"}}]).custom_tool_uses == []
    assert ManagedAgents.normalize([%{"type" => "session.status_idle", "stop_reason" => %{"type" => "end_turn"}}]).custom_tool_uses == []
  end

  test "cross-provider symmetry: both backends produce the same canonical shape (modulo ids/names)" do
    shapes =
      for provider <- @providers do
        provider.normalize(requires_action_fixture(provider))
        |> Map.update!(:custom_tool_uses, fn uses -> Enum.map(uses, &Map.take(&1, [:id, :name])) end)
      end

    assert [a, b] = shapes
    assert a.terminal == b.terminal
    assert length(a.custom_tool_uses) == length(b.custom_tool_uses)
  end
end
