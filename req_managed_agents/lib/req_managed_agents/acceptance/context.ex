defmodule ReqManagedAgents.Acceptance.Context do
  @moduledoc "Owned execution state passed to a provider's acceptance scenario."
  alias ReqManagedAgents.Acceptance.{Config, Proposal, Source}
  @enforce_keys [:config, :proposal, :source, :recorder, :run_id, :root, :transport, :deadline]
  defstruct @enforce_keys

  @typedoc "Transport is an optional native client or existing invoke_fun seam, supplied in-process only."
  @type transport :: keyword()
  @type t :: %__MODULE__{
          config: Config.t(),
          proposal: Proposal.t(),
          source: Source.t(),
          recorder: pid(),
          run_id: String.t(),
          root: String.t(),
          transport: transport(),
          deadline: integer()
        }

  @doc "Construct context only after proposal, checkout and private-root validation."
  @spec new(Config.t(), Proposal.t(), Source.t(), pid(), String.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_context}
  def new(
        %Config{} = config,
        %Proposal{} = proposal,
        %Source{} = source,
        recorder,
        root,
        transport
      )
      when is_pid(recorder) and is_binary(root) and is_list(transport) do
    if source.revision == config.source_revision and proposal.config == config and
         Keyword.keyword?(transport) do
      {:ok,
       %__MODULE__{
         config: config,
         proposal: proposal,
         source: source,
         recorder: recorder,
         run_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
         root: root,
         transport: transport,
         deadline: System.monotonic_time(:millisecond) + config.bounds.timeout_ms
       }}
    else
      {:error, :invalid_context}
    end
  end

  def new(_, _, _, _, _, _), do: {:error, :invalid_context}
end
