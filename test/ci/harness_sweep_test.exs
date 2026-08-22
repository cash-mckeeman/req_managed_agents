defmodule ReqManagedAgents.CI.HarnessSweepTest do
  # The canary's post-suite sweep deletes real AWS resources, so its decisions
  # are pinned here rather than left to a shell string in the workflow.
  #
  # The decision that matters most is the one it used to get wrong: matching on
  # name alone made a successful run's own teardown — asynchronous, so still
  # `DELETING` seconds later — look exactly like a leak.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ReqManagedAgents.CI.HarnessSweep

  defp harness(name, status, id \\ "h-abc"),
    do: %{"harnessName" => name, "harnessId" => id, "status" => status}

  defp listing(harnesses), do: fn -> {:ok, %{"harnesses" => harnesses}} end

  defp recording_delete(pid) do
    fn id ->
      send(pid, {:deleted, id})
      {:ok, %{}}
    end
  end

  defp refusing_delete(pid) do
    fn id ->
      send(pid, {:deleted, id})
      flunk("the sweep deleted #{id}, which it was supposed to leave alone")
    end
  end

  describe "status classification" do
    test "a harness already DELETING is a teardown in flight, not a leak" do
      assert HarnessSweep.action(harness("rma_live_x", "DELETING")) == :skip
    end

    test "a DELETE_FAILED harness is a leak" do
      assert HarnessSweep.action(harness("rma_live_x", "DELETE_FAILED")) == :reclaim
    end

    test "a harness still standing after the suite is a leak whatever its phase" do
      for status <- ~w(READY CREATING UPDATING CREATE_FAILED UPDATE_FAILED) do
        assert HarnessSweep.action(harness("rma_live_x", status)) == :reclaim,
               "#{status} is a harness still billing after the suite finished"
      end
    end

    test "a status this library does not recognise is reclaimed rather than left billing" do
      assert HarnessSweep.action(harness("rma_live_x", "SOME_NEW_AWS_STATUS")) == :reclaim
      assert HarnessSweep.action(%{"harnessName" => "rma_live_x"}) == :reclaim
    end
  end

  describe "reclaiming" do
    test "does not delete this run's own harnesses while they are DELETING" do
      deleting = harness("rma_live_bedrock_harness_1234abcd", "DELETING")

      report =
        HarnessSweep.run(
          list_fun: listing([deleting]),
          delete_fun: refusing_delete(self()),
          prefix: "rma_live"
        )

      assert report.matched == [deleting]
      assert report.skipped == [deleting]
      assert report.reclaimed == []
      assert report.unreclaimed == []
      refute_received {:deleted, _}
    end

    test "deletes a harness stranded in DELETE_FAILED" do
      stranded = harness("rma_live_bedrock_harness_1234abcd", "DELETE_FAILED", "h-stranded")

      report =
        HarnessSweep.run(
          list_fun: listing([stranded]),
          delete_fun: recording_delete(self()),
          prefix: "rma_live"
        )

      assert report.reclaimed == [stranded]
      assert report.skipped == []
      assert_received {:deleted, "h-stranded"}
    end

    test "leaves harnesses outside the canary's prefix alone" do
      report =
        HarnessSweep.run(
          list_fun: listing([harness("data_analyst_harness_1234abcd", "READY", "h-other")]),
          delete_fun: refusing_delete(self()),
          prefix: "rma_live"
        )

      assert report.matched == []
      refute_received {:deleted, _}
    end

    test "a delete the provider rejects is reported, not counted as reclaimed" do
      stuck = harness("rma_live_bedrock_harness_1234abcd", "READY", "h-stuck")

      report =
        HarnessSweep.run(
          list_fun: listing([stuck]),
          delete_fun: fn _id -> {:error, {:http_error, 409}} end,
          prefix: "rma_live"
        )

      assert report.reclaimed == []
      assert report.unreclaimed == [{stuck, {:http_error, 409}}]
    end

    test "a listing the provider refuses is reported rather than silently swept clean" do
      report =
        HarnessSweep.run(
          list_fun: fn -> {:error, :timeout} end,
          delete_fun: refusing_delete(self()),
          prefix: "rma_live"
        )

      assert report.unreclaimed == [{nil, {:list_harnesses_failed, :timeout}}]
    end
  end

  describe "the printed report" do
    test "a run that leaked nothing raises no leak warning" do
      output =
        capture_io(fn ->
          HarnessSweep.main(
            list_fun: listing([harness("rma_live_bedrock_harness_1234abcd", "DELETING")]),
            delete_fun: refusing_delete(self()),
            prefix: "rma_live"
          )
        end)

      refute output =~ "::warning::"
      refute output =~ "SWEEP_UNRECLAIMED"
      assert output =~ "teardown already in flight"
    end

    test "an unreclaimed harness prints the marker the workflow step fails on" do
      output =
        capture_io(fn ->
          HarnessSweep.main(
            list_fun: listing([harness("rma_live_x_1234abcd", "READY", "h-stuck")]),
            delete_fun: fn _id -> {:error, :denied} end,
            prefix: "rma_live"
          )
        end)

      assert output =~ ~r/^SWEEP_UNRECLAIMED rma_live_x_1234abcd h-stuck/m
    end
  end
end
