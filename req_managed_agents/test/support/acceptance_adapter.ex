defmodule ReqManagedAgents.Test.AcceptanceAdapter do
  @moduledoc false
  def run(request), do: request.options.finch_private.acceptance_adapter.(request)
end
