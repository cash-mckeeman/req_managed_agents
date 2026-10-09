defmodule ReqManagedAgents.ToolSchemaTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Providers.BedrockAgentCore.Converse
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.ToolSchema

  test "neutral schema is shared by both wire wrappers" do
    schema = [count: [type: :integer, required: true], flag: [type: :boolean]]

    expected = %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer"}, "flag" => %{"type" => "boolean"}},
      "required" => ["count"]
    }

    assert ReqManagedAgents.ToolSchema.input_schema(schema) == expected
    assert ToolSchema.to_custom_tool("x", "desc", schema)["input_schema"] == expected

    assert ReqManagedAgents.ToolSchema.to_custom_tool("x", "desc", schema)["input_schema"] ==
             expected

    assert Converse.inline_function(
             "x",
             "desc",
             schema
           )["config"]["inlineFunction"]["inputSchema"] == expected
  end

  test "converts a {name, jido_schema} pair to an Anthropic custom-tool def" do
    jido_schema = [
      topic: [type: :string, required: true, doc: "the subject"],
      top_k: [type: :integer, default: 5, doc: "how many"]
    ]

    assert ToolSchema.to_custom_tool("query_external_context", "Query KB", jido_schema) == %{
             "type" => "custom",
             "name" => "query_external_context",
             "description" => "Query KB",
             "input_schema" => %{
               "type" => "object",
               "properties" => %{
                 "topic" => %{"type" => "string", "description" => "the subject"},
                 "top_k" => %{"type" => "integer", "description" => "how many"}
               },
               "required" => ["topic"]
             }
           }
  end
end
