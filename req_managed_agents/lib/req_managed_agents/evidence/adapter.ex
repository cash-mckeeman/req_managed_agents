defmodule ReqManagedAgents.Evidence.Adapter do
  @moduledoc "Native evidence interpretation; shared capture code owns retention and bounds."
  alias ReqManagedAgents.CloudWatch.Evidence, as: CloudWatch
  alias ReqManagedAgents.Evidence.NativeObservation
  alias ReqManagedAgents.Providers.BedrockAgentCore.Evidence, as: Bedrock
  alias ReqManagedAgents.Providers.ClaudeManagedAgents.Evidence, as: Claude

  @callback interpret(map()) :: NativeObservation.t()

  @doc false
  @spec interpret(map(), atom()) :: NativeObservation.t()
  def interpret(payload, selector \\ :standalone)

  def interpret(payload, selector) when selector in [:managed, :claude_session, :claude_thread],
    do: Claude.interpret(payload)

  def interpret(payload, selector) when selector in [:agentcore, :agentcore_stream],
    do: Bedrock.interpret(payload)

  def interpret(payload, :cloudwatch), do: CloudWatch.interpret(payload)

  def interpret(%{"type" => _} = payload, :standalone) do
    case Claude.interpret(payload) do
      %NativeObservation{supported?: true} = observation -> observation
      _ -> interpret_standalone(payload)
    end
  end

  def interpret(payload, :standalone), do: interpret_standalone(payload)

  def interpret(_, _),
    do: %NativeObservation{supported?: false, malformed_metadata?: false, safe_payload: %{}}

  defp interpret_standalone(payload) do
    case Bedrock.interpret(payload) do
      %NativeObservation{supported?: true} = observation -> observation
      _ -> CloudWatch.interpret(payload)
    end
  end
end
