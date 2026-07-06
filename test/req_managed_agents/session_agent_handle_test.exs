defmodule ReqManagedAgents.SessionAgentHandleTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Session

  defmodule EchoOpts do
    @behaviour ReqManagedAgents.Provider
    @impl true
    def mode, do: :request_response
    @impl true
    def provision(_s, _o), do: {:error, :ni}
    @impl true
    def open(opts, _sub) do
      send(opts[:test_pid], {:opened, opts[:agent_id], opts[:environment_id]})
      {:ok, %{session_id: "s", turns: []}}
    end

    @impl true
    def kickoff_input(_o), do: :k
    @impl true
    def user_input(_t), do: :u
    @impl true
    def resume_input(_u, _r), do: :r
    @impl true
    def poll_turn(c, _i), do: {:ok, [%{"type" => "stop"}], c}
    @impl true
    def normalize(_e),
      do: %ReqManagedAgents.TurnResult{terminal: :end_turn, stop_reason: "stop", events: []}
  end

  test "an :agent / :environment handle is unpacked to ids before open/2" do
    Session.run(EchoOpts,
      handler: fn _, _, _ -> {:ok, ""} end,
      test_pid: self(),
      agent: %{agent_id: "a1", name: "x_deadbeef", digest: "deadbeef"},
      environment: %{environment_id: "e1", name: "y", digest: "abcd1234"}
    )

    assert_received {:opened, "a1", "e1"}
  end

  test "an explicit :agent_id / :environment_id takes precedence over a handle" do
    Session.run(EchoOpts,
      handler: fn _, _, _ -> {:ok, ""} end,
      test_pid: self(),
      agent: %{agent_id: "from_handle_a", name: "x_deadbeef", digest: "deadbeef"},
      agent_id: "explicit_a",
      environment: %{environment_id: "from_handle_e", name: "y", digest: "abcd1234"},
      environment_id: "explicit_e"
    )

    assert_received {:opened, "explicit_a", "explicit_e"}
  end
end
