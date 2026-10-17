defmodule ReqManagedAgents.CloudWatch.MessageAssociation do
  @moduledoc "Qualifies whole CloudWatch log messages for same-session association only."
  alias ReqManagedAgents.CloudWatch.Query

  @typedoc "Provider-verbatim outer CloudWatch JSON record, including its opaque message string."
  @type payload :: %{optional(String.t()) => term()}

  @callback matches?(payload(), Query.t()) :: boolean()
end
