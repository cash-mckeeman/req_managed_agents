defmodule ReqManagedAgents.Conformance.Redaction do
  @moduledoc false
  # Sanitizes captured provider traffic to a public-safe, deterministic shape.
  #
  # Lives in lib/ (not test/support) because it is shared by two callers that
  # compile under different envs: the test-support conformance harness (:test)
  # and the `mix rma.capture` maintainer task (:dev). test/support is not
  # compiled in :dev, so a single shared implementation has to sit in lib/.
  # `@moduledoc false` keeps it out of the public docs — it is internal tooling.
  #
  # Bump @redaction_version whenever the redaction/scan rules change so goldens
  # carry accurate provenance.
  @redaction_version 2

  # Key matching is CASE-INSENSITIVE (keys are downcased before lookup), so the
  # PascalCase AWS/STS shapes (SecretAccessKey, SessionToken, AccessKeyId) are
  # covered alongside camelCase. Entries below are already lowercased.
  @bearer_keys ~w(authorization)
  @stripped_keys ~w(
    accesskeyid secretaccesskey sessiontoken x-amz-security-token signature
    apikey api_key api-key x-api-key token secret clientsecret client_secret password
  )
  @id_keys ~w(id sessionid runtimesessionid agentid harnessid environmentid)

  @acct_re ~r/(arn:aws:[^:]*:[^:]*:)[0-9]{6,}(:)/
  @leak_res [
    ~r/Bearer\s+(?!\*\*\*)\S+/,
    # AKIA = long-lived access-key id; ASIA = STS temporary access-key id.
    ~r/A[KS]IA[0-9A-Z]{12,}/,
    # Anthropic/OpenAI-style bearer secrets (sk-…, sk-ant-…).
    ~r/sk-[A-Za-z0-9_-]{16,}/,
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

  defp redact_kv(k, v) do
    case classify(k) do
      :bearer -> "Bearer ***"
      :stripped -> "REDACTED"
      :id -> placeholder_id(k)
      :none -> redact(v)
    end
  end

  defp classify(k) when is_binary(k) do
    downcased = String.downcase(k)

    cond do
      downcased in @bearer_keys -> :bearer
      downcased in @stripped_keys -> :stripped
      downcased in @id_keys -> :id
      true -> :none
    end
  end

  defp classify(_k), do: :none

  defp placeholder_id(k) do
    if String.downcase(k) == "sessionid", do: "sess-REDACTED", else: "REDACTED"
  end

  @doc "Scans every regular file under `dir` for secret-shaped content that redaction should have removed."
  @spec scan(String.t()) :: :ok | {:leak, [String.t()]}
  def scan(dir) do
    leaks =
      Path.join(dir, "**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case scan_string(File.read!(path)) do
          :ok -> []
          {:leak, _} -> [path]
        end
      end)

    if leaks == [], do: :ok, else: {:leak, leaks}
  end

  @doc "Leak-scans one already-encoded body; the last-line guard `mix rma.capture` runs before writing a fixture."
  @spec scan_string(binary()) :: :ok | {:leak, [Regex.t()]}
  def scan_string(body) when is_binary(body) do
    case Enum.filter(@leak_res, &Regex.match?(&1, body)) do
      [] -> :ok
      hits -> {:leak, hits}
    end
  end
end
