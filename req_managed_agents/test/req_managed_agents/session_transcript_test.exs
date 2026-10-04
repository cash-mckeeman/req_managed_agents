defmodule ReqManagedAgents.SessionTranscriptTest do
  @moduledoc """
  The transcript seam: at terminal, Session embeds `provider.transcript(conn)` into
  `SessionResult.transcript` when the optional callback is exported, else nil.
  """
  use ExUnit.Case, async: true

  alias ReqManagedAgents.FakeProviders.{RequestResponse, WithTranscript}
  alias ReqManagedAgents.{Session, SessionResult}

  test "a provider exporting transcript/1 gets its history embedded at terminal" do
    assert {:ok, %SessionResult{transcript: [%{"role" => "user", "content" => "canned"}]}} =
             Session.run(WithTranscript, prompt: "hi", handler: fn _, _, _ -> {:ok, "unused"} end)
  end

  test "a provider without transcript/1 yields transcript: nil" do
    assert {:ok, %SessionResult{transcript: nil}} =
             Session.run(RequestResponse,
               prompt: "hi",
               handler: fn _, _, _ -> {:ok, "unused"} end
             )
  end
end
