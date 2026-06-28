defmodule ReqManagedAgents.ToolSchemaTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.ToolSchema

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
