defmodule ReqManagedAgents.Stream do
  @moduledoc """
  Long-lived SSE consumer for `GET /v1/sessions/{id}/events/stream`.

  Uses `Req` with `into: :self` over an **injectable Finch pool** (default
  `ReqManagedAgents.StreamFinch`) so minutes-long streams don't stall the default
  pool. Blocks for the life of the connection — run it inside a `Task` owned by
  your session process.

  Messages sent to `subscriber`, tagged with the caller-supplied `ref`:

      {:managed_agents, ref, :connected}   # sent once, when the stream attaches, before any event
      {:managed_agents, ref, {:event, decoded_map}}
      {:managed_agents, ref, :done}
      {:managed_agents, ref, {:error, reason}}
  """
  alias ReqManagedAgents.{Client, SSE}

  @doc """
  Open the stream for `session_id` and forward events to `subscriber`.

  Options: `:ref` (term tagging each message; default `make_ref()`),
  `:finch` (Finch pool name; default `ReqManagedAgents.StreamFinch`),
  `:receive_timeout` (staleness guard; default 30 minutes).
  """
  @spec stream(Client.t(), String.t(), pid(), keyword()) :: :ok
  def stream(%Client{} = client, session_id, subscriber, opts \\ []) do
    ref = opts[:ref] || make_ref()
    finch = opts[:finch] || ReqManagedAgents.StreamFinch
    receive_timeout = opts[:receive_timeout] || :timer.minutes(30)

    url = "#{client.base_url}/v1/sessions/#{session_id}/events/stream"
    headers = Client.headers(client) ++ [{"accept", "text/event-stream"}]

    req =
      Req.new(
        url: url,
        headers: headers,
        finch: finch,
        receive_timeout: receive_timeout,
        retry: false,
        into: :self
      )
      |> Req.merge(client.req_options)

    case Req.get(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        send(subscriber, {:managed_agents, ref, :connected})
        drain(resp, subscriber, ref, "", receive_timeout)

      {:ok, %Req.Response{status: status} = resp} ->
        # Drain/cancel the async body so the connection is released, then report.
        Req.cancel_async_response(resp)
        send(subscriber, {:managed_agents, ref, {:error, {:status, status}}})
        :ok

      {:error, reason} ->
        send(subscriber, {:managed_agents, ref, {:error, reason}})
        :ok
    end
  end

  # In req 0.6.2 the Finch `into: :self` adapter delivers raw messages shaped
  # `{ref, {:data, binary}}` / `{ref, :done}` / `{ref, {:trailers, _}}` /
  # `{ref, {:error, reason}}`, where `ref` is `resp.body.ref`. We receive a
  # message, feed it to `Req.parse_message/2` (which returns `{:ok, parts}` /
  # `{:error, reason}` / `:unknown`), and forward decoded SSE events.
  defp drain(
         %Req.Response{body: %Req.Response.Async{ref: async_ref}} = resp,
         subscriber,
         ref,
         buffer,
         receive_timeout
       ) do
    receive do
      {^async_ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            {buffer, done?} = handle_parts(parts, subscriber, ref, buffer)

            if done? do
              send(subscriber, {:managed_agents, ref, :done})
              :ok
            else
              drain(resp, subscriber, ref, buffer, receive_timeout)
            end

          {:error, reason} ->
            # Release the connection on a mid-stream error, mirroring the
            # non-2xx and idle-timeout paths.
            Req.cancel_async_response(resp)
            send(subscriber, {:managed_agents, ref, {:error, reason}})
            :ok

          :unknown ->
            drain(resp, subscriber, ref, buffer, receive_timeout)
        end
    after
      receive_timeout ->
        Req.cancel_async_response(resp)
        send(subscriber, {:managed_agents, ref, {:error, :stream_idle_timeout}})
        :ok
    end
  end

  defp handle_parts(parts, subscriber, ref, buffer) do
    Enum.reduce(parts, {buffer, false}, fn
      {:data, chunk}, {buf, done?} ->
        {events, rest} = SSE.decode(buf <> chunk)
        Enum.each(events, &send(subscriber, {:managed_agents, ref, {:event, &1}}))
        {rest, done?}

      :done, {buf, _done?} ->
        {buf, true}

      _other, acc ->
        acc
    end)
  end
end
