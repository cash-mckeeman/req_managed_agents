defmodule ReqManagedAgents.Conformance.Corpus do
  @moduledoc "Locates and loads the conformance corpus: RMA_CORPUS_DIR when set, else bundled synthetic examples."

  defmodule Entry do
    @moduledoc "One decoded corpus fixture."
    @enforce_keys [:name, :kind, :path, :json]
    defstruct [:name, :kind, :path, :json]
    @type kind :: :requests | :responses | :model
    @type t :: %__MODULE__{name: String.t(), kind: kind(), path: String.t(), json: map()}
  end

  defmodule Manifest do
    @moduledoc "The corpus's `manifest.json`: provenance plus a name -> relative-path file index."
    @enforce_keys [:source, :files]
    defstruct [:source, :files]
    @type t :: %__MODULE__{source: map(), files: %{optional(String.t()) => String.t()}}
  end

  @surfaces [:agentcore, :cma]
  @examples_root Path.join([__DIR__, "..", "..", "conformance", "examples"]) |> Path.expand()

  @spec dir(atom()) :: String.t()
  def dir(surface) when surface in @surfaces do
    case System.get_env("RMA_CORPUS_DIR") do
      dir when is_binary(dir) and dir != "" ->
        candidate = Path.join(dir, to_string(surface))

        # Silently falling back to bundled examples when RMA_CORPUS_DIR is set but
        # the surface subdir is missing would let a mistyped path or a
        # half-populated corpus pass as a green "private corpus" run (false
        # confidence). Fail loud instead — you opted into the external corpus.
        if File.dir?(candidate) do
          candidate
        else
          raise ArgumentError,
                "RMA_CORPUS_DIR is set (#{dir}) but #{candidate} does not exist. " <>
                  "Populate the #{surface} surface, or unset RMA_CORPUS_DIR to use " <>
                  "the bundled synthetic examples."
        end

      _ ->
        examples_dir(surface)
    end
  end

  @spec external?(atom()) :: boolean()
  def external?(surface), do: dir(surface) != examples_dir(surface)

  @spec entries(atom(), Entry.kind()) :: [Entry.t()]
  def entries(surface, kind) do
    kind_dir = Path.join(dir(surface), to_string(kind))

    case File.ls(kind_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(fn f ->
          path = Path.join(kind_dir, f)

          %Entry{
            name: Path.rootname(f),
            kind: kind,
            path: path,
            json: Jason.decode!(File.read!(path))
          }
        end)

      {:error, _} ->
        []
    end
  end

  @spec load(atom(), Entry.kind(), String.t()) :: Entry.t() | nil
  def load(surface, kind, name), do: entries(surface, kind) |> Enum.find(&(&1.name == name))

  @spec manifest(atom()) :: Manifest.t() | nil
  def manifest(surface) do
    path = Path.join(dir(surface), "manifest.json")

    with {:ok, raw} <- File.read(path), {:ok, %{"files" => files} = m} <- Jason.decode(raw) do
      %Manifest{source: Map.get(m, "source", %{}), files: files}
    else
      _ -> nil
    end
  end

  defp examples_dir(surface), do: Path.join(@examples_root, to_string(surface))
end
