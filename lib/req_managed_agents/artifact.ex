defmodule ReqManagedAgents.Artifact do
  @moduledoc """
  A named file in a session's storage, provider-agnostic. `name` is the only
  identity the model ever sees; `ref` is the provider-native identity (a CMA
  file id, a sandbox path); `raw` is the unparsed provider record when one exists.
  """
  @derive Jason.Encoder
  defstruct name: nil, size: nil, ref: nil, raw: nil

  @type t :: %__MODULE__{
          name: String.t() | nil,
          size: non_neg_integer() | nil,
          ref: term(),
          raw: term()
        }
end
