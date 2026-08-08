defmodule ReqManagedAgents.Provisioner.Name do
  @moduledoc """
  Composes a provider resource name as `<base>_<digest>` under a `Policy`.

  The digest is the content address and is never truncated — it is what makes two
  identical specs resolve to one resource. When the composed name would exceed
  the policy limit, the *base* is shortened and a short hash of the **full** base
  is appended, so two bases sharing a long common prefix cannot collapse onto the
  same name. Plain truncation would: two AgentCore harness bases can share a
  17-character prefix and still name distinct agents.
  """

  alias ReqManagedAgents.Provisioner
  alias ReqManagedAgents.Provisioner.Name.Policy

  @base_hash_len 6

  @doc """
  Builds `<base>_<digest>`, sanitised and fitted to `policy`.

  A base that is empty (or sanitises to empty) still yields a legal name — the
  leading-character rule supplies one — so callers with neither a prefix nor a
  spec name keep working.
  """
  @spec compose(String.t(), String.t(), Policy.t()) :: String.t()
  def compose(base, digest, %Policy{} = policy)
      when is_binary(base) and is_binary(digest) do
    base
    |> sanitize(policy)
    |> ensure_leading(policy)
    |> fit(digest, policy)
    |> Kernel.<>("_" <> digest)
  end

  defp sanitize(base, %Policy{charset: :permissive}), do: base

  defp sanitize(base, %Policy{charset: :alnum_underscore}),
    do: String.replace(base, ~r/[^a-zA-Z0-9_]/, "_")

  defp ensure_leading(base, %Policy{leading: :any}), do: base

  defp ensure_leading(base, %Policy{leading: :alpha}) do
    case base do
      <<c, _::binary>> when c in ?a..?z or c in ?A..?Z -> base
      _ -> "a" <> base
    end
  end

  defp fit(base, digest, %Policy{max_length: max}) do
    budget = max - byte_size(digest) - 1

    if byte_size(base) <= budget do
      base
    else
      hash =
        base
        |> Provisioner.hash()
        |> binary_part(0, @base_hash_len)
        |> String.downcase()

      keep = budget - @base_hash_len - 1
      truncate_bytes(base, keep) <> "_" <> hash
    end
  end

  # The budget is counted in BYTES — the conservative reading of a character cap,
  # since a byte count is never below a character count. Truncation must still not
  # end mid-character, or the name is invalid UTF-8. Slicing by grapheme instead
  # would stay valid but overrun the budget, because one grapheme can be four
  # bytes; so cut on the byte boundary and give back any partial trailing
  # character.
  defp truncate_bytes(base, keep) do
    base
    |> binary_part(0, keep)
    |> drop_partial_codepoint()
  end

  defp drop_partial_codepoint(""), do: ""

  defp drop_partial_codepoint(bin) do
    if String.valid?(bin) do
      bin
    else
      dropped = binary_part(bin, 0, byte_size(bin) - 1)
      drop_partial_codepoint(dropped)
    end
  end
end
