defmodule ReqManagedAgents.Conformance.CorpusTest do
  use ExUnit.Case, async: true
  alias ReqManagedAgents.Conformance.Corpus

  test "dir/1 falls back to bundled examples when RMA_CORPUS_DIR is unset" do
    System.delete_env("RMA_CORPUS_DIR")
    dir = Corpus.dir(:agentcore)
    assert String.ends_with?(dir, "test/conformance/examples/agentcore")
    assert File.dir?(dir)
  end

  test "dir/1 uses RMA_CORPUS_DIR/<surface> when set and present" do
    tmp = System.tmp_dir!() |> Path.join("rma_corpus_test/cma")
    File.mkdir_p!(tmp)
    System.put_env("RMA_CORPUS_DIR", Path.dirname(tmp))
    assert Corpus.dir(:cma) == tmp
  after
    System.delete_env("RMA_CORPUS_DIR")
  end

  test "entries/2 lists request fixtures as %Corpus.Entry{} with parsed json" do
    [entry | _] = Corpus.entries(:agentcore, :requests)
    assert %Corpus.Entry{name: name, kind: :requests, json: %{} = json} = entry
    assert is_binary(name)
    assert map_size(json) > 0
  end

  test "external?/1 is false for examples fallback" do
    System.delete_env("RMA_CORPUS_DIR")
    refute Corpus.external?(:agentcore)
  end
end
