defmodule ReqManagedAgents.Usage do
  @moduledoc "Token usage — canonical summed counts + the provider's raw usage object(s) verbatim."
  @derive Jason.Encoder
  defstruct input_tokens: 0, output_tokens: 0, raw: []

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          raw: [map()]
        }
end
