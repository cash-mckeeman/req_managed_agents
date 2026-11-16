defmodule ReqManagedAgents.CodecDependencyTest do
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("RMA_PUBLISH")
    on_exit(fn -> put_mode(previous) end)
  end

  test "workspace development uses the optional sibling codec" do
    put_mode(nil)
    assert {:aws_event_stream, opts} = codec_dependency()
    assert opts[:path] == "../aws_event_stream"
    assert opts[:optional] == true
  end

  test "publication retains the existing optional Hex range" do
    put_mode("1")
    assert {:aws_event_stream, "~> 0.1", opts} = codec_dependency()
    assert opts[:optional] == true
    refute Keyword.has_key?(opts, :path)
  end

  test "floor verification selects the minimum admitted codec" do
    put_mode("floor")
    assert {:aws_event_stream, "== 0.1.0", opts} = codec_dependency()
    assert opts[:optional] == true
  end

  defp codec_dependency,
    do: List.keyfind(Mix.Project.get!().project()[:deps], :aws_event_stream, 0)

  defp put_mode(nil), do: System.delete_env("RMA_PUBLISH")
  defp put_mode(mode), do: System.put_env("RMA_PUBLISH", mode)
end
