defmodule ReqManagedAgents.Evidence.Artifact.Ref do
  @moduledoc "The relative evidence filename and SHA256 digest of its exact stored bytes."
  alias ReqManagedAgents.Evidence.{Error, Validation}
  @enforce_keys [:relative_path, :sha256]
  defstruct [:relative_path, :sha256]
  @type t :: %__MODULE__{relative_path: String.t(), sha256: String.t()}

  @doc "Validates the artifact's fixed relative filename and lowercase SHA256."
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    path = Validation.get(attrs, :relative_path)
    sha = Validation.get(attrs, :sha256)

    if path == "evidence.json" and is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
      do: {:ok, %__MODULE__{relative_path: path, sha256: sha}},
      else: Error.error(:invalid_reference)
  end

  def new(_), do: Error.error(:invalid_reference)
end

defmodule ReqManagedAgents.Evidence.Artifact do
  @moduledoc """
  Publishes private evidence into an existing caller-owned directory, without
  replacing an existing artifact. The caller must prevent concurrent directory
  renames or permission changes while publishing.
  """
  alias ReqManagedAgents.Evidence
  alias ReqManagedAgents.Evidence.Artifact.Ref
  alias ReqManagedAgents.Evidence.{Capture, Error}

  @doc "Writes a mode-0600 artifact, rejecting symlinks and hashing the exact published bytes."
  @spec write(Capture.t(), String.t()) :: {:ok, Ref.t()} | {:error, Error.t()}
  def write(%Capture{} = capture, directory) when is_binary(directory) do
    with {:ok, validated} <- Capture.restore(capture),
         :ok <- directory_safe(directory),
         {:ok, bytes} <- Jason.encode(Evidence.to_wire(validated)),
         :ok <- publish(directory, bytes) do
      Ref.new(%{
        relative_path: "evidence.json",
        sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      })
    else
      _ -> Error.error(:artifact_write_failed)
    end
  end

  def write(_, _), do: Error.error(:artifact_write_failed)

  defp directory_safe(directory) do
    if Enum.any?(Path.split(directory), &(&1 == "..")) do
      :error
    else
      directory
      |> Path.expand()
      |> Path.split()
      |> Enum.reduce_while("/", &directory_component/2)
      |> case do
        :error -> :error
        _ -> :ok
      end
    end
  end

  defp directory_component(component, parent) do
    path = Path.join(parent, component)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> {:cont, path}
      _ -> {:halt, :error}
    end
  end

  defp publish(directory, bytes) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp = Path.join(directory, ".evidence-#{suffix}.tmp")
    target = Path.join(directory, "evidence.json")

    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(temp, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file),
               :ok <- File.close(file),
               :ok <- directory_safe(directory) do
            File.ln(temp, target)
          end
        after
          File.close(file)
          File.rm(temp)
        end

      error ->
        error
    end
  end
end
