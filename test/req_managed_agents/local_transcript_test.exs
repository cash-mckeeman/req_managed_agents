defmodule ReqManagedAgents.LocalTranscriptTest do
  @moduledoc """
  Local's transcript seam: `open/2` seeds `history:` verbatim (resume), `resumed?/1`
  reflects it, `transcript/1` exposes the grown history, and the resumed prompt is
  delivered through the #66 seam onto the seeded history.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Providers.Local
  alias ReqManagedAgents.{Session, SessionResult}

  # OpenAI-chat-completions-shaped stop turn; echoes how many messages it was called with.
  defp echo_chat_fun(test) do
    fn %{messages: msgs} = req ->
      send(test, {:chat_called, length(msgs), req})

      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{"role" => "assistant", "content" => "seen #{length(msgs)}"},
             "finish_reason" => "stop"
           }
         ]
       }}
    end
  end

  test "fresh open: no history opt, resumed? false, transcript returned at terminal" do
    {:ok, conn} = Local.open([chat_fun: echo_chat_fun(self()), spec: %{}], self())
    refute Local.resumed?(conn)

    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    assert {:ok, %SessionResult{transcript: transcript}} =
             Session.run(Local,
               prompt: "first",
               handler: handler,
               chat_fun: echo_chat_fun(self()),
               spec: %{}
             )

    assert is_list(transcript)
    assert Enum.any?(transcript, &(&1["content"] == "first"))
  end

  test "open with history: seeds it verbatim and resumed? is true" do
    prior = [
      %{"role" => "user", "content" => "first"},
      %{"role" => "assistant", "content" => "seen 1"}
    ]

    {:ok, conn} = Local.open([history: prior, chat_fun: echo_chat_fun(self()), spec: %{}], self())
    assert Local.resumed?(conn)
    assert Local.transcript(conn) == prior
  end

  test "reattach round-trip: second run over injected history continues the conversation" do
    chat = echo_chat_fun(self())
    handler = fn _name, _input, _ctx -> {:ok, "unused"} end

    {:ok, %SessionResult{transcript: t1}} =
      Session.run(Local, prompt: "first", handler: handler, chat_fun: chat, spec: %{})

    n1 = length(t1)

    # Drain the first run's {:chat_called, _, _} messages so the next assertion
    # can only match the second run's calls.
    drain = fn drain ->
      receive do
        {:chat_called, _, _} -> drain.(drain)
      after
        0 -> :ok
      end
    end

    drain.(drain)

    {:ok, %SessionResult{transcript: t2}} =
      Session.run(Local,
        history: t1,
        session_id: "local-42",
        prompt: "second",
        handler: handler,
        chat_fun: chat,
        spec: %{}
      )

    # The second run's first model call saw the full prior transcript + the new user message.
    expected = n1 + 1
    assert_received {:chat_called, ^expected, _}

    assert length(t2) > n1
    assert Enum.any?(t2, &(&1["content"] == "second"))
    assert Enum.take(t2, n1) == t1
  end
end
