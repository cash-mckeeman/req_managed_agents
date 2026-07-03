defmodule ReqManagedAgents.AgentCore.Deps do
  @moduledoc false

  # The AWS deps are `optional: true` in mix.exs so Anthropic-only consumers
  # don't pull them. Every AgentCore code path funnels through SigV4 signing
  # and/or EventStream decoding, so those two modules call `ensure!/0` and
  # raise this actionable error instead of an UndefinedFunctionError.

  @required [{AWSAuth, :ex_aws_auth, "~> 1.4"}, {AWSEventStream, :aws_event_stream, "~> 0.1"}]

  @spec ensure!() :: :ok
  def ensure! do
    case Enum.reject(@required, fn {mod, _, _} -> Code.ensure_loaded?(mod) end) do
      [] ->
        :ok

      missing ->
        deps =
          Enum.map_join(missing, "\n", fn {_, app, req} ->
            "      {:#{app}, \"#{req}\"},"
          end)

        raise """
        the Bedrock AgentCore provider requires optional dependencies that \
        are not present in this project.

        Add them to your mix.exs deps:

        #{deps}

        (They are optional so that Anthropic-only users of req_managed_agents \
        don't pull AWS machinery.)
        """
    end
  end
end
