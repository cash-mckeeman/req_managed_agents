defmodule ReqManagedAgents.Provisioner.Runtime do
  @moduledoc """
  A language runtime to install in a provisioned environment. `new/1` is the
  single shape+charset validation gate (the version charset closes shell
  injection through the rendered bootstrap script).
  """

  @derive Jason.Encoder
  @enforce_keys [:lang, :version]
  defstruct [:lang, :version, via: :mise]

  @type t :: %__MODULE__{lang: atom(), version: String.t(), via: :mise}

  # \A...\z + this charset is the shell-injection guard — kept byte-identical
  # to the former `valid_entry?/1` (no whitespace/`;`/quotes; rejects empty).
  @version_re ~r/\A[0-9A-Za-z.\-+]+\z/

  @doc """
  Builds and validates a `#{inspect(__MODULE__)}`.

  Accepts a map with `:lang` (atom) and `:version` (binary) keys, plus an
  optional `:via` (defaults to `:mise`; only `:mise` is currently supported).
  Also accepts an existing `#{inspect(__MODULE__)}` struct, which is
  re-validated (so a struct built by other means still passes through the
  charset gate before it can reach rendering).

  Returns `{:ok, t()}` or `{:error, {:invalid_runtime, term()}}`.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, {:invalid_runtime, term()}}
  def new(%__MODULE__{lang: lang, version: version, via: via} = r)
      when is_atom(lang) and is_binary(version) do
    if via == :mise and version =~ @version_re,
      do: {:ok, r},
      else: {:error, {:invalid_runtime, r}}
  end

  def new(%{lang: lang, version: version} = m) when is_atom(lang) and is_binary(version) do
    via = Map.get(m, :via, :mise)

    if via == :mise and version =~ @version_re,
      do: {:ok, %__MODULE__{lang: lang, version: version, via: via}},
      else: {:error, {:invalid_runtime, m}}
  end

  def new(other), do: {:error, {:invalid_runtime, other}}
end
