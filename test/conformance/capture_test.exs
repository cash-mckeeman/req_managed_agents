defmodule ReqManagedAgents.Conformance.CaptureTest do
  use ExUnit.Case, async: false
  alias ReqManagedAgents.Conformance.{Capture, Redaction}

  test "write_pair/5 redacts and writes a provenance-stamped request+response entry" do
    dir = Path.join(System.tmp_dir!(), "rma_cap")
    System.put_env("RMA_CORPUS_DIR", dir)
    req = %{"executionRoleArn" => "arn:aws:iam::123456789012:role/R", "model" => "claude"}
    resp = %{"harness" => %{"status" => "READY"}}
    :ok = Capture.write_pair(:agentcore, "create_harness", req, resp, ~U[2026-07-14 00:00:00Z])
    written = File.read!(Path.join([dir, "agentcore", "requests", "create_harness.json"]))
    refute written =~ "123456789012"
    assert File.exists?(Path.join([dir, "agentcore", "responses", "create_harness.json"]))
    manifest = Jason.decode!(File.read!(Path.join([dir, "agentcore", "manifest.json"])))
    assert manifest["redaction_version"] == Redaction.version()
  after
    System.delete_env("RMA_CORPUS_DIR")
    File.rm_rf!(Path.join(System.tmp_dir!(), "rma_cap"))
  end

  test "write_pair/5 merges into an existing manifest.json rather than clobbering it" do
    dir = Path.join(System.tmp_dir!(), "rma_cap_merge")
    System.put_env("RMA_CORPUS_DIR", dir)
    req = %{"model" => "claude"}
    resp = %{"status" => "READY"}

    :ok = Capture.write_pair(:agentcore, "get_harness", req, resp, ~U[2026-07-14 00:00:00Z])
    :ok = Capture.write_pair(:agentcore, "delete_harness", req, resp, ~U[2026-07-14 01:00:00Z])

    manifest = Jason.decode!(File.read!(Path.join([dir, "agentcore", "manifest.json"])))
    assert manifest["captured_at"] == "2026-07-14T01:00:00Z"
    assert Map.has_key?(manifest["files"], Path.join("requests", "get_harness.json"))
    assert Map.has_key?(manifest["files"], Path.join("requests", "delete_harness.json"))
  after
    System.delete_env("RMA_CORPUS_DIR")
    File.rm_rf!(Path.join(System.tmp_dir!(), "rma_cap_merge"))
  end

  test "attach/2 wraps the real adapter, capturing the outbound + inbound body for fetch/1" do
    real_adapter = fn req ->
      {req, Req.Response.new(status: 200, body: Jason.encode!(%{"ok" => true}))}
    end

    req_options = Capture.attach("agentcore_smoke", adapter: real_adapter)

    {_req, resp} =
      [url: "http://example.test"]
      |> Req.new()
      |> Req.merge(req_options)
      |> Req.Request.run_request()

    assert resp.status == 200

    assert {:ok, req_json, resp_json} = Capture.fetch("agentcore_smoke")
    assert req_json == %{}
    assert resp_json == %{"ok" => true}
    assert Capture.fetch("agentcore_smoke") == :error
  end

  test "attach/2 decodes an iolist request body rather than silently dropping it to %{}" do
    real_adapter = fn req -> {req, Req.Response.new(status: 200, body: "{}")} end
    req_options = Capture.attach("iolist_req", adapter: real_adapter)

    # `encode_body` can leave a JSON request body as an iolist, not a binary.
    {_req, _resp} =
      [url: "http://example.test", body: ["{", ~s("k":"v"), "}"]]
      |> Req.new()
      |> Req.merge(req_options)
      |> Req.Request.run_request()

    assert {:ok, req_json, _resp} = Capture.fetch("iolist_req")
    assert req_json == %{"k" => "v"}
  end
end
