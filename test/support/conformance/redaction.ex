defmodule ReqManagedAgents.Conformance.Redaction do
  @moduledoc "Sanitizes captured traffic to a public-safe, deterministic shape. Bump @redaction_version when rules change."
  @redaction_version 1

  @bearer_keys ~w(authorization Authorization)
  @stripped_keys ~w(accessKeyId secretAccessKey sessionToken x-amz-security-token signature)
  @id_keys ~w(sessionId runtimeSessionId agentId harnessId environmentId)

  @acct_re ~r/(arn:aws:[^:]*:[^:]*:)[0-9]{6,}(:)/
  @leak_res [
    ~r/Bearer\s+(?!\*\*\*)\S+/,
    ~r/AKIA[0-9A-Z]{12,}/,
    ~r/arn:aws:[^:]*:[^:]*:(?!000000000000:)[0-9]{6,}:/
  ]

  @spec version() :: pos_integer()
  def version, do: @redaction_version

  @spec redact(term()) :: term()
  def redact(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, redact_kv(k, v)} end)
  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  def redact(bin) when is_binary(bin),
    do: Regex.replace(@acct_re, bin, "\\g{1}000000000000\\g{2}")

  def redact(other), do: other

  defp redact_kv(k, _v) when k in @bearer_keys, do: "Bearer ***"
  defp redact_kv(k, _v) when k in @stripped_keys, do: "REDACTED"
  defp redact_kv(k, _v) when k in @id_keys, do: placeholder_id(k)
  defp redact_kv(_k, v), do: redact(v)

  defp placeholder_id("sessionId"), do: "sess-REDACTED"
  defp placeholder_id(_), do: "REDACTED"

  @spec scan(String.t()) :: :ok | {:leak, [String.t()]}
  def scan(dir) do
    leaks =
      Path.wildcard(Path.join(dir, "**/*.{json,bin,sse}"))
      |> Enum.flat_map(fn path ->
        body = File.read!(path)
        if Enum.any?(@leak_res, &Regex.match?(&1, body)), do: [path], else: []
      end)

    if leaks == [], do: :ok, else: {:leak, leaks}
  end
end
