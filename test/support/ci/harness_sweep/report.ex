defmodule ReqManagedAgents.CI.HarnessSweep.Report do
  @moduledoc """
  What one sweep saw and what it did about it.

  `skipped` and `unreclaimed` are the two halves of the distinction the sweep
  exists to draw. A harness whose teardown is already in flight is not a leak;
  counting it as one raises the alarm on every green run, and an alarm that
  always fires carries no information.
  """

  @enforce_keys [:matched, :skipped, :reclaimed, :unreclaimed]
  defstruct [:matched, :skipped, :reclaimed, :unreclaimed]

  @typedoc "A harness exactly as `ListHarnesses` returned it."
  @type harness :: %{optional(String.t()) => term()}

  @typedoc """
  A harness the sweep could not account for, with why. The harness is `nil`
  when the failure was the listing itself rather than one resource.
  """
  @type unreclaimed :: {harness() | nil, term()}

  @type t :: %__MODULE__{
          matched: [harness()],
          skipped: [harness()],
          reclaimed: [harness()],
          unreclaimed: [unreclaimed()]
        }
end
