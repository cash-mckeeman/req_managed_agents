defmodule ReqManagedAgents.Local.Deps do
  @moduledoc false

  # req_llm is `optional: true` in mix.exs so consumers that inject their own
  # chat_fun (tests, Ollama, mimir lanes) don't pull it. Only the default
  # ReqLLM-backed chat_fun needs it, so ReqLLMChat calls `ensure!/0` and raises
  # this actionable error instead of an UndefinedFunctionError.

  @spec ensure!() :: :ok
  def ensure! do
    if Code.ensure_loaded?(ReqLLM) do
      :ok
    else
      raise """
      the Local provider's default chat_fun requires the optional req_llm \
      dependency, which is not present in this project.

      Either add it to your mix.exs deps:

            {:req_llm, "~> 1.10"},

      or inject your own chat_fun (see ReqManagedAgents.Providers.Local — a \
      chat_fun over any OpenAI-compatible endpoint is a plain Req.post).
      """
    end
  end
end
