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

  The chat_fun's response must be OpenAI-chat-completions shaped, string-keyed:
  `%{"choices" => [%{"message" => message, "finish_reason" => reason} | _], "usage" => usage}`
  where `message` is `%{"role" => "assistant", "content" => text_or_nil}` plus an optional
  `"tool_calls" => [%{"id" => id, "type" => "function", "function" => %{"name" => n, "arguments" => json}}]`,
  and `usage` is `%{"prompt_tokens" => n, "completion_tokens" => n}` (or absent).

  Errors: return `{:error, reason}`. Transient reasons are retried with exponential
  backoff: `%{status: 408}` / `%{status: 500..}` (HTTP) and `%{reason: atom}` /
  `%{cause: atom}` where the atom is one of `:timeout | :closed | :econnrefused |
  :econnreset | :connect_timeout`. Wrap transport exceptions down to their atom —
  `%{reason: %Req.TransportError{...}}` will NOT match; return `%{reason: err.reason}`.

  Open opts: `:spec` (the `t:ReqManagedAgents.Provider.spec/0`, also the `provision/2`
  identity handle), `:model_config` (canonical keys `:model`, `:api_key`, `:base_url`,
  `:metadata`; defaults from `spec.model_config`), `:chat_fun`, `:max_turns`,
  `:session_id`, retry tuning (`:max_chat_retries`, `:retry_backoff_ms`, `:sleep_fun`).

  Events are synthesized under the `local.*` namespace (`local.model_response`, and the
  guard events added by the loop guards) so `SessionResult.events` stays raw-preserving.
  """
  @behaviour ReqManagedAgents.Provider

  alias ReqManagedAgents.Local.{Deps, Directives, ReqLLMChat, Retry}
  alias ReqManagedAgents.{ToolResult, ToolUse, TurnResult, Usage}

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
            error_counts: %{},
            resume: false

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
          error_counts: %{optional(String.t()) => non_neg_integer()},
          resume: boolean()
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

    history =
      case opts[:history] do
        [_ | _] = h -> h
        _ -> system_history(spec[:system_prompt])
      end

    %__MODULE__{
      # Reattach seam: injected history (a prior run's transcript) is seeded verbatim —
      # it already carries the original system message. Fresh opens build from the spec.
      # An empty list is treated as absent — fresh semantics, system prompt preserved.
      history: history,
      resume: match?([_ | _], opts[:history]),
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

  # The conn is a struct, not a bag of keys — the concepts a live stream needs (ref/consumer)
  # don't apply to this in-process, request_response provider.
  @impl true
  def session_id(conn), do: conn.session_id

  @impl true
  def ref(_conn), do: nil

  @impl true
  def consumer(_conn), do: nil

  @impl true
  def resumed?(conn), do: conn.resume

  @impl true
  def transcript(conn), do: conn.history

  @impl true
  def kickoff_input(opts),
    do: {:messages, [%{"role" => "user", "content" => opts[:prompt] || "Begin."}]}

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

  defp accept_response(
         conn,
         injected_events,
         %{
           "choices" => [%{"message" => message, "finish_reason" => finish_reason} | _]
         } = response
       ) do
    conn = %{conn | history: conn.history ++ [message]}
    {conn, dup_events, message} = dedup_tool_calls(conn, message)

    event = %{
      "type" => "local.model_response",
      "message" => message,
      "finish_reason" => finish_reason,
      "usage" => response["usage"]
    }

    {:ok, injected_events ++ dup_events ++ [event], conn}
  end

  defp accept_response(_conn, _injected_events, malformed),
    do: {:error, {:malformed_chat_response, malformed}}

  # Duplicate-call dedup (relocated from an internal agent runner's Core.Runner.Dispatch): a repeated
  # {name, decoded-input} call is never surfaced — the provider self-answers it in
  # history with the duplicate directive, and the surviving message carries only the
  # fresh calls. If ALL calls were duplicates the turn normalizes to :requires_action
  # with zero tool uses; the Session's empty resume drives the next model call.
  defp dedup_tool_calls(conn, %{"tool_calls" => [_ | _] = calls} = message) do
    {dups, fresh} = Enum.split_with(calls, &MapSet.member?(conn.seen, call_key(&1)))
    seen = MapSet.union(conn.seen, MapSet.new(fresh, &call_key/1))

    dup_messages =
      Enum.map(dups, fn %{"id" => id} ->
        %{
          "role" => "tool",
          "tool_call_id" => id,
          "content" =>
            Jason.encode!(%{"duplicate" => true, "message" => Directives.duplicate_tool()})
        }
      end)

    dup_events =
      Enum.map(dups, fn %{"id" => id, "function" => f} ->
        %{
          "type" => "local.duplicate_tool_call",
          "id" => id,
          "name" => f["name"],
          "input" => decode_args(f["arguments"])
        }
      end)

    message = %{message | "tool_calls" => fresh}
    conn = %{conn | seen: seen, history: conn.history ++ dup_messages}
    {conn, dup_events, message}
  end

  defp dedup_tool_calls(conn, message), do: {conn, [], message}

  defp call_key(%{"function" => %{"name" => name, "arguments" => args}}),
    do: {name, decode_args(args)}

  # ── input application ─────────────────────────────────────────────────────────
  # A user message (kickoff or follow-up) starts a fresh request: polls, the
  # duplicate-call guard, and the consecutive-error counters all reset here so a
  # long-lived start_link session gets a fresh max_turns budget and a fresh
  # reasoning episode per turn, instead of accumulating across the conn's whole
  # lifetime. On kickoff these are already at their zero values (no-op).
  defp apply_input(conn, {:messages, messages}) do
    inject_final_turn(
      %{
        conn
        | history: conn.history ++ messages,
          polls: 0,
          seen: MapSet.new(),
          error_counts: %{}
      },
      []
    )
  end

  defp apply_input(conn, {:resume, tool_uses, results}) do
    results_by_id = Map.new(results, &{&1.tool_use_id, &1})

    tool_messages =
      Enum.map(tool_uses, fn use ->
        result = Map.fetch!(results_by_id, use.id)
        %{"role" => "tool", "tool_call_id" => use.id, "content" => result_content(result)}
      end)

    conn = %{conn | history: conn.history ++ tool_messages}
    {conn, corrective_events} = apply_correctives(conn, tool_uses, results_by_id)
    inject_final_turn(conn, corrective_events)
  end

  # (b) consecutive-error correctives (relocated from an internal agent runner's Core.Runner): a tool that
  # errors on two consecutive dispatches gets a corrective user directive. Two passes:
  # fold the counts, then collect directives for the tools past the threshold.
  defp apply_correctives(conn, tool_uses, results_by_id) do
    error_counts =
      Enum.reduce(tool_uses, conn.error_counts, &count_error(&1, results_by_id, &2))

    correctives =
      for use <- tool_uses,
          %ToolResult{is_error: true, text: err} <- [results_by_id[use.id]],
          error_counts[use.name] >= 2,
          do: Directives.corrective(use.name, err)

    conn = %{
      conn
      | error_counts: error_counts,
        history: conn.history ++ user_messages(correctives)
    }

    {conn, Enum.map(correctives, &directive_event("corrective", &1))}
  end

  defp count_error(use, results_by_id, counts) do
    case results_by_id[use.id] do
      %ToolResult{is_error: true} -> Map.update(counts, use.name, 1, &(&1 + 1))
      _success -> Map.put(counts, use.name, 0)
    end
  end

  # (c) final-turn directive: the poll about to hit max_turns tells the model to finish.
  defp inject_final_turn(%{polls: polls, max_turns: max} = conn, events)
       when polls + 1 >= max do
    text = Directives.final_turn(conn.terminal_tool)

    {%{conn | history: conn.history ++ user_messages([text])},
     events ++ [directive_event("final_turn", text)]}
  end

  defp inject_final_turn(conn, events), do: {conn, events}

  defp user_messages(texts), do: Enum.map(texts, &%{"role" => "user", "content" => &1})

  defp directive_event(role, text),
    do: %{"type" => "local.directive", "role" => role, "text" => text}

  defp result_content(%ToolResult{is_error: true, text: text}),
    do: Jason.encode!(%{"error" => text, "isError" => true})

  defp result_content(%ToolResult{text: text}), do: text

  # ── normalization ─────────────────────────────────────────────────────────────
  @impl true
  def normalize(events) do
    case Enum.find(events, &(&1["type"] == "local.model_response")) do
      nil ->
        %TurnResult{terminal: :terminated, stop_reason: nil, events: events}

      %{"message" => message, "finish_reason" => fr, "usage" => usage} ->
        had_dups? = Enum.any?(events, &(&1["type"] == "local.duplicate_tool_call"))
        tool_calls = message["tool_calls"] || []

        %TurnResult{
          terminal: terminal(fr, tool_calls, had_dups?),
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
  def terminal(_fr, [_ | _], _dups), do: :requires_action
  def terminal(_fr, [], true), do: :requires_action
  def terminal("stop", _, _), do: :end_turn
  def terminal("tool_calls", _, _), do: :requires_action
  def terminal(_other, _, _), do: :terminated

  # The neutral contract names them prompt_tokens/completion_tokens — one shape,
  # no fallback key-chains. A response without usage (or with JSON-null tokens)
  # yields nil (Session skips it).
  defp to_usage(%{"prompt_tokens" => input} = usage) when is_integer(input) do
    completion = usage["completion_tokens"]

    %Usage{
      input_tokens: input,
      output_tokens: if(is_integer(completion), do: completion, else: 0),
      raw: [usage]
    }
  end

  defp to_usage(_), do: nil

  @impl true
  def text_delta(%{"type" => "local.model_response", "message" => %{"content" => c}})
      when is_binary(c) and c != "",
      do: c

  def text_delta(_), do: nil
end
