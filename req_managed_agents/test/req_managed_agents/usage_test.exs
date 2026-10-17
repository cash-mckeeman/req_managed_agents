defmodule ReqManagedAgents.UsageTest do
  use ExUnit.Case, async: true

  alias ReqManagedAgents.Usage

  test "constructor preserves canonical counts, basis and raw usage" do
    raw = %{"inputTokens" => 12, "outputTokens" => 4, "cacheReadInputTokens" => 3}
    assert {:ok, usage} = Usage.new(known(raw: [raw]))
    assert usage.input_tokens == 12
    assert usage.output_tokens == 4
    assert usage.cache_read_input_tokens == 3
    assert usage.cache_creation_input_tokens == 2
    assert usage.input_token_basis == :uncached
    assert usage.complete?
    assert usage.raw == [raw]
    assert Usage.new(usage) == {:ok, usage}
  end

  test "unobserved cache counts stay nil independently of measured zero" do
    for key <- [:cache_read_input_tokens, :cache_creation_input_tokens] do
      for value <- [nil, -1, 1.5, "3", false] do
        assert {:ok, usage} = Usage.new(Map.put(known(), key, value))
        assert Map.fetch!(usage, key) == nil
        refute usage.complete?
      end

      assert {:ok, missing} = Usage.new(Map.delete(known(), key))
      assert Map.fetch!(missing, key) == nil
      refute missing.complete?
      assert {:ok, zero} = Usage.new(Map.put(known(), key, 0))
      assert Map.fetch!(zero, key) == 0
      assert zero.complete?
    end
  end

  test "missing required observations keep legacy zero but cannot be certified" do
    for key <- [:input_tokens, :output_tokens] do
      assert {:ok, usage} = Usage.new(Map.delete(known(), key) |> Map.put(:complete?, true))
      assert Map.fetch!(usage, key) == 0
      refute usage.complete?

      for value <- [-1, 1.5, "12", false] do
        assert {:error, {:invalid_usage, ^key}} = Usage.new(Map.put(known(), key, value))
      end
    end
  end

  test "false completeness and legacy structs are not upgraded" do
    assert {:ok, usage} = Usage.new(Map.put(known(), :complete?, false))
    refute usage.complete?
    assert {:ok, legacy} = Usage.new(%Usage{input_tokens: 12, output_tokens: 4})
    assert legacy.cache_read_input_tokens == nil
    assert legacy.cache_creation_input_tokens == nil
    assert legacy.input_token_basis == :unknown
    refute legacy.complete?
  end

  test "constructor rejects noncanonical keys and malformed structure" do
    assert {:error, {:invalid_usage, :keys}} = Usage.new(%{"input_tokens" => 12})
    assert {:error, {:invalid_usage, :keys}} = Usage.new(Map.put(known(), :extra, 1))

    assert {:error, {:invalid_usage, :input_token_basis}} =
             Usage.new(Map.put(known(), :input_token_basis, :invented))

    assert {:error, {:invalid_usage, :raw}} = Usage.new(Map.put(known(), :raw, [:not_a_map]))
    assert {:error, {:invalid_usage, :complete?}} = Usage.new(Map.put(known(), :complete?, nil))
    assert {:error, {:invalid_usage, :usage}} = Usage.new(:not_a_map)
  end

  test "known empty usage is a complete identity, never an absent report" do
    empty = Usage.zero()
    assert empty.input_tokens == 0
    assert empty.output_tokens == 0
    assert empty.cache_read_input_tokens == 0
    assert empty.cache_creation_input_tokens == 0
    assert empty.input_token_basis == :none
    assert empty.complete?
    assert empty.raw == []
    assert {:ok, ^empty} = Usage.new(empty)
    assert {:ok, usage} = Usage.new(known())
    assert Usage.add(empty, usage) == usage
    assert Usage.add(usage, empty) == usage
    missing = Usage.add(empty, nil)
    refute missing.complete?
    assert missing.cache_read_input_tokens == nil
    assert missing.cache_creation_input_tokens == nil
    assert missing.input_token_basis == :unknown
  end

  test "none basis is reserved for an empty accumulation" do
    assert {:error, {:invalid_usage, :input_token_basis}} =
             Usage.new(Map.put(known(), :input_token_basis, :none))

    assert {:error, {:invalid_usage, :input_token_basis}} =
             Usage.new(%{
               input_tokens: 0,
               output_tokens: 0,
               cache_read_input_tokens: 0,
               cache_creation_input_tokens: 0,
               input_token_basis: :none,
               raw: [%{}]
             })
  end

  test "known contributions add all four counts and append raw once" do
    assert {:ok, usage} = Usage.new(known(raw: [%{"request" => 1}]))
    sum = Usage.add(usage, usage)
    assert sum.input_tokens == 24
    assert sum.output_tokens == 8
    assert sum.cache_read_input_tokens == 6
    assert sum.cache_creation_input_tokens == 4
    assert sum.raw == [%{"request" => 1}, %{"request" => 1}]
    assert sum.input_token_basis == :uncached
    assert sum.complete?
  end

  test "unknown cache poisons only that count through later observations" do
    for key <- [:cache_read_input_tokens, :cache_creation_input_tokens] do
      other =
        if key == :cache_read_input_tokens,
          do: :cache_creation_input_tokens,
          else: :cache_read_input_tokens

      assert {:ok, first} = Usage.new(known())
      assert {:ok, missing} = Usage.new(Map.put(known(), key, nil) |> Map.put(other, 0))

      for contributions <- [
            [first, missing, first],
            [missing, first, first],
            [first, first, missing]
          ] do
        sum = Enum.reduce(contributions, Usage.zero(), &Usage.add(&2, &1))
        assert Map.fetch!(sum, key) == nil
        assert Map.fetch!(sum, other) == if(other == :cache_creation_input_tokens, do: 4, else: 6)
        refute sum.complete?
      end
    end
  end

  test "absent usage retains observed subtotals and raw but stays incomplete" do
    assert {:ok, usage} = Usage.new(known(raw: [%{"request" => 1}]))
    missing = Usage.add(usage, nil)
    assert missing.input_tokens == 12
    assert missing.output_tokens == 4
    assert missing.raw == [%{"request" => 1}]
    assert missing.cache_read_input_tokens == nil
    assert missing.cache_creation_input_tokens == nil
    assert missing.input_token_basis == :unknown
    refute missing.complete?
    refute Usage.add(missing, usage).complete?
  end

  test "mixed or unknown input bases cannot be a complete total" do
    for basis <- [:inclusive, :unknown] do
      assert {:ok, first} = Usage.new(known())
      assert {:ok, second} = Usage.new(known(input_token_basis: basis))

      for {left, right} <- [{first, second}, {second, first}] do
        sum = Usage.add(left, right)
        assert sum.input_tokens == 24
        assert sum.input_token_basis == :unknown
        refute sum.complete?
      end
    end
  end

  defp known(overrides \\ []) do
    Map.merge(
      %{
        input_tokens: 12,
        output_tokens: 4,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 2,
        input_token_basis: :uncached,
        raw: []
      },
      Map.new(overrides)
    )
  end
end
