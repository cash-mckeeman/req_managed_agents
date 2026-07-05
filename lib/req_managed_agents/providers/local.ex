defmodule ReqManagedAgents.Providers.Local do
  @moduledoc """
  `ReqManagedAgents.Provider` that runs the agent loop **in-process** — `:request_response`
  mode, one model call per `poll_turn/2` through a pluggable `chat_fun`.

  The chat wire contract is neutral, OpenAI-chat-completions-shaped, plain string-keyed
  maps: `chat_fun.(%{model:, messages:, tools:}) :: {:ok, response} | {:error, reason}`.
  The default chat_fun adapts it to `ReqLLM.generate_text/3` (optional `req_llm` dep);
  pointing a chat_fun at any OpenAI-compatible endpoint is a bare `Req.post` — e.g. a
  mimir lane (`/v1/chat/completions` + granted key via `model_config`) for hard
  data-plane budget enforcement.

  Open opts: `:spec` (the `t:ReqManagedAgents.Provider.spec/0`, also the `provision/2`
  identity handle), `:model_config` (canonical keys `:model`, `:api_key`, `:base_url`,
  `:metadata`; defaults from `spec.model_config`), `:chat_fun`, `:max_turns`,
  `:session_id`, retry tuning (`:max_chat_retries`, `:retry_backoff_ms`, `:sleep_fun`).

  Events are synthesized under the `local.*` namespace (`local.model_response`, and the
  guard events added by the loop guards) so `SessionResult.events` stays raw-preserving.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Local.{Deps, Directives, ReqLLMChat, Retry}
  alias ReqManagedAgents.{ToolUse, TurnResult, Usage}

  # The conn is a struct, not a bag of keys: one place to see everything a turn needs.
  defstruct history: [],
            tools: [],
            terminal_tool: nil,
            chat_fun: nil,
            model: nil,
            session_id: nil,
            max_turns: 50,
            polls: 0,
            seen: MapSet.new(),
            error_counts: %{}

  @type t :: %__MODULE__{
          history: [map()],
          tools: [map()],
          terminal_tool: String.t() | nil,
          chat_fun: (map() -> {:ok, map()} | {:error, term()}),
          model: term(),
          session_id: String.t(),
          max_turns: pos_integer(),
          polls: non_neg_integer(),
          seen: MapSet.t(),
          error_counts: %{optional(String.t()) => non_neg_integer()}
        }

  @impl true
  def mode, do: :request_response

  @impl true
  def provision(spec, _opts), do: {:ok, spec}

  @impl true
  def teardown(_handle, _opts), do: :ok

  @impl true
  def open(opts, _subscriber) do
    spec = opts[:spec] || %{}
    model_config = normalize_model_config(opts[:model_config] || spec[:model_config])
    {:ok, build_conn(opts, spec, model_config)}
  end

  defp build_conn(opts, spec, model_config) do
    retry = build_retry(opts)

    %__MODULE__{
      history: system_history(spec[:system_prompt]),
      tools: Enum.map(spec[:tools] || [], &to_function_tool/1),
      terminal_tool: spec[:terminal_tool],
      chat_fun: Retry.wrap(opts[:chat_fun] || default_chat_fun(model_config), retry),
      model: model_config[:model],
      session_id: opts[:session_id] || mint_session_id(),
      max_turns: opts[:max_turns] || 50
    }
  end

  defp build_retry(opts) do
    %Retry{
      max_retries: opts[:max_chat_retries] || 3,
      backoff_ms: opts[:retry_backoff_ms] || 1000,
      sleep_fun: opts[:sleep_fun] || (&Process.sleep/1)
    }
  end

  defp normalize_model_config(nil), do: %{}
  defp normalize_model_config(%{} = config), do: config
  # A CMA-style spec carries a bare model term in model_config — lift it.
  defp normalize_model_config(model), do: %{model: model}

  defp mint_session_id,
    do: "local_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp default_chat_fun(model_config) do
    Deps.ensure!()
    ReqLLMChat.chat_fun(model_config)
  end

  defp system_history(nil), do: []
  defp system_history(prompt), do: [%{"role" => "system", "content" => prompt}]

  # Spec tools arrive Anthropic-shaped (name/description/input_schema) — the same
  # string-keyed wire maps the CMA provider provisions. One shape, no dual-keying;
  # they go to the model OpenAI-function-shaped.
  defp to_function_tool(%{"name" => name} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => tool["description"] || "",
        "parameters" => tool["input_schema"] || %{"type" => "object"}
      }
    }
  end

  @impl true
  def kickoff_input(opts), do: {:messages, [%{"role" => "user", "content" => opts[:prompt] || "Begin."}]}

  @impl true
  def user_input(text), do: {:messages, [%{"role" => "user", "content" => text}]}

  @impl true
  def resume_input(tool_uses, results), do: {:resume, tool_uses, results}

  @impl true
  def poll_turn(conn, input) do
    {conn, injected_events} = apply_input(conn, input)
    conn = %{conn | polls: conn.polls + 1}

    case conn.chat_fun.(chat_request(conn)) do
      {:ok, response} -> accept_response(conn, injected_events, response)
      {:error, _reason} = error -> error
    end
  end

  defp chat_request(conn),
    do: %{model: conn.model, messages: conn.history, tools: conn.tools}

  defp accept_response(conn, injected_events, %{
         "choices" => [%{"message" => message, "finish_reason" => finish_reason} | _]
       } = response) do
    conn = %{conn | history: conn.history ++ [message]}

    event = %{
      "type" => "local.model_response",
      "message" => message,
      "finish_reason" => finish_reason,
      "usage" => response["usage"]
    }

    {:ok, injected_events ++ [event], conn}
  end

  defp accept_response(_conn, _injected_events, malformed),
    do: {:error, {:malformed_chat_response, malformed}}

  # ── input application (guards extend this in the loop-guards change) ─────────
  defp apply_input(conn, {:messages, messages}) do
    {%{conn | history: conn.history ++ messages}, []}
  end

  defp apply_input(conn, {:resume, tool_uses, results}) do
    by_id = Map.new(results, &{&1.tool_use_id, &1})

    tool_messages =
      Enum.map(tool_uses, fn use ->
        r = Map.fetch!(by_id, use.id)
        %{"role" => "tool", "tool_call_id" => use.id, "content" => result_content(r)}
      end)

    {%{conn | history: conn.history ++ tool_messages}, []}
  end

  defp result_content(%{is_error: true, text: text}),
    do: Jason.encode!(%{"error" => text, "isError" => true})

  defp result_content(%{text: text}), do: text

  # ── normalization ─────────────────────────────────────────────────────────────
  @impl true
  def normalize(events) do
    case Enum.find(events, &(&1["type"] == "local.model_response")) do
      nil ->
        %TurnResult{terminal: :terminated, stop_reason: nil, events: events}

      %{"message" => message, "finish_reason" => fr, "usage" => usage} ->
        tool_calls = message["tool_calls"] || []

        %TurnResult{
          terminal: terminal(fr, tool_calls),
          stop_reason: fr,
          text: message["content"] || "",
          custom_tool_uses: Enum.map(tool_calls, &to_tool_use/1),
          server_tool_uses: [],
          usage: to_usage(usage),
          events: events
        }
    end
  end

  defp to_tool_use(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %ToolUse{id: id, name: name, input: decode_args(args)}
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  @doc false
  def terminal(_fr, [_ | _]), do: :requires_action
  def terminal("stop", _), do: :end_turn
  def terminal("tool_calls", _), do: :requires_action
  def terminal(_other, _), do: :terminated

  # The neutral contract names them prompt_tokens/completion_tokens — one shape,
  # no fallback key-chains. A response without usage yields nil (Session skips it).
  defp to_usage(%{"prompt_tokens" => input} = usage),
    do: %Usage{
      input_tokens: input,
      output_tokens: usage["completion_tokens"] || 0,
      raw: [usage]
    }

  defp to_usage(_), do: nil

  @impl true
  def text_delta(%{"type" => "local.model_response", "message" => %{"content" => c}})
      when is_binary(c) and c != "",
      do: c

  def text_delta(_), do: nil
end
