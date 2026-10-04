defmodule ReqManagedAgents.Providers.BedrockAgentCorePaginationTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.AgentCore.Client
  alias ReqManagedAgents.Providers.BedrockAgentCore, as: P

  @spec_bedrock %{
    name: "harness",
    system_prompt: "be helpful",
    tools: [],
    model_config: %{"bedrockModelConfig" => %{"modelId" => "model"}}
  }
  @creds %{
    access_key_id: "AKID",
    secret_access_key: "secret",
    region: "us-east-1",
    security_token: nil
  }

  defp harness(status) do
    %{
      "harnessName" => P.harness_name(@spec_bedrock, nil),
      "harnessId" => "h-existing",
      "arn" => "arn:existing",
      "status" => status
    }
  end

  defp json(body), do: %Req.Response{status: 200, body: body}
  defp page(harnesses, token \\ nil), do: json(%{"harnesses" => harnesses, "nextToken" => token})

  defp provision(list_page, extra \\ []) do
    caller = self()

    adapter = fn req ->
      response =
        case {req.method, req.url.path} do
          {:post, "/harnesses"} ->
            send(caller, :create)
            %Req.Response{status: 409, body: "exists"}

          {:get, "/harnesses"} ->
            token = URI.decode_query(req.url.query || "")["nextToken"]
            send(caller, {:page, token, req.options[:receive_timeout]})
            list_page.(token)

          {:get, "/harnesses/h-existing"} ->
            json(%{"harness" => %{"status" => "READY"}})

          {:get, "/harnesses/h-existing/endpoints/DEFAULT"} ->
            json(%{"endpoint" => %{"status" => "READY"}})
        end

      {req, response}
    end

    client = Client.new(credentials: @creds, req_options: [adapter: adapter, retry: false])

    P.provision(
      @spec_bedrock,
      Keyword.merge([execution_role_arn: "role", client: client, timeout: 5_000], extra)
    )
  end

  for status <- ["READY", "CREATING"] do
    test "default recovery adopts a later-page #{status} harness through an empty page" do
      status = unquote(status)

      assert {:ok, %{harness_id: "h-existing", harness_arn: "arn:existing"}} =
               provision(fn
                 nil -> page([%{"harnessName" => "other", "status" => "READY"}], "a")
                 "a" -> page([], "opaque +/=&? token")
                 "opaque +/=&? token" -> page([harness(status)])
               end)

      assert_received {:page, nil, _}
      assert_received {:page, "a", _}
      assert_received {:page, "opaque +/=&? token", _}
      assert_received :create
      refute_received :create
    end
  end

  test "deletion polling waits for later-page presence and recreates only after complete absence" do
    traversal = make_ref()

    assert {:error, {:http_error, 409, "exists"}} =
             provision(
               fn
                 nil ->
                   Process.put(traversal, Process.get(traversal, 0) + 1)
                   page([], "later")

                 "later" ->
                   page(if Process.get(traversal) < 3, do: [harness("DELETING")], else: [])
               end,
               ready_poll_ms: 0
             )

    assert Process.get(traversal) == 3
    assert_received :create
    assert_received :create
    refute_received :create
  end

  for {label, bad_page} <- [
        {"missing harness list", %{}},
        {"non-list harnesses", %{"harnesses" => nil}},
        {"non-map harness entry", %{"harnesses" => [nil]}},
        {"unnamed harness entry", %{"harnesses" => [%{"status" => "READY"}]}},
        {"non-string harness name", %{"harnesses" => [%{"harnessName" => 7}]}},
        {"non-string token", %{"harnesses" => [], "nextToken" => 7}},
        {"empty token", %{"harnesses" => [], "nextToken" => ""}}
      ] do
    test "recovery rejects a later page with #{label} even after finding a reusable harness" do
      bad_page = unquote(Macro.escape(bad_page))

      assert {:error, {:unexpected_list_response, {:ok, ^bad_page}}} =
               provision(fn
                 nil -> page([harness("READY")], "later")
                 "later" -> json(bad_page)
               end)
    end
  end

  for tokens <- [["a", "a"], ["a", "b", "a"]] do
    test "recovery rejects repeated cursor sequence #{inspect(tokens)}" do
      tokens = unquote(tokens)
      responses = Enum.zip([nil | Enum.drop(tokens, -1)], tokens) |> Map.new()

      assert {:error, {:repeated_list_token, "a"}} =
               provision(fn token -> page([harness("READY")], Map.fetch!(responses, token)) end,
                 timeout: 200
               )

      assert_received {:page, nil, _}
      assert_received {:page, "a", _}
      refute_received {:page, "a", _}
    end
  end

  test "recovery propagates a later-page transport failure without adopting partial results" do
    assert {:error, %Req.TransportError{reason: :closed}} =
             provision(fn
               nil -> page([harness("READY")], "later")
               "later" -> %Req.TransportError{reason: :closed}
             end)
  end

  for failure <- [
        %Req.TransportError{reason: :closed},
        %Req.Response{status: 200, body: %{}},
        %Req.Response{status: 200, body: %{"harnesses" => [], "nextToken" => "later"}}
      ] do
    test "incomplete deletion traversal #{inspect(failure)} never recreates" do
      traversal = make_ref()
      failure = unquote(Macro.escape(failure))

      assert {:error, _reason} =
               provision(fn
                 nil ->
                   Process.put(traversal, Process.get(traversal, 0) + 1)
                   page([harness("DELETING")], "later")

                 "later" ->
                   if Process.get(traversal) == 1, do: page([]), else: failure
               end)

      assert Process.get(traversal) == 2
      assert_received :create
      refute_received :create
    end
  end

  test "the deadline stops traversal before requesting another page" do
    assert {:error, :harness_list_timeout} =
             provision(
               fn nil ->
                 Process.sleep(120)
                 page([harness("READY")], "later")
               end,
               timeout: 100
             )

    assert_received {:page, nil, _}
    refute_received {:page, "later", _}
  end

  test "each page recomputes its receive timeout from remaining budget" do
    assert {:ok, %{harness_id: "h-existing"}} =
             provision(
               fn
                 nil ->
                   Process.sleep(60)
                   page([], "later")

                 "later" ->
                   page([harness("READY")])
               end,
               timeout: 600
             )

    assert_received {:page, nil, first_timeout}
    assert_received {:page, "later", later_timeout}
    assert first_timeout <= 200
    assert later_timeout < first_timeout - 10
  end

  test "a failed injected delete-wait listing returns its error without recreating" do
    traversal = make_ref()

    list = fn ->
      case Process.get(traversal, 0) do
        0 ->
          Process.put(traversal, 1)
          {:ok, %{"harnesses" => [harness("DELETING")]}}

        _ ->
          {:error, :list_unavailable}
      end
    end

    assert {:error, :list_unavailable} =
             provision(fn _ -> flunk("default list seam used") end, list_fun: list)

    assert_received :create
    refute_received :create
  end
end
