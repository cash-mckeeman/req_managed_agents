defmodule ReqManagedAgents.CI.HarnessSweep.Report do
  @moduledoc """
  What one sweep saw and what it did about it.

  `skipped` and `unreclaimed` are the two halves of the distinction the sweep
  exists to draw. A harness whose teardown is already in flight is not a leak;
  counting it as one raises the alarm on every green run, and an alarm that
  always fires carries no information.

  `reclaimed` and `unconfirmed` draw the second distinction. A 2xx from
  `DeleteHarness` is an acceptance, not a deletion — only `reclaimed` has been
  observed gone from a later listing.
  """

  @enforce_keys [:matched, :skipped, :reclaimed, :unconfirmed, :unreclaimed, :complete?]
  defstruct [:matched, :skipped, :reclaimed, :unconfirmed, :unreclaimed, :complete?]

  @typedoc "A harness exactly as `ListHarnesses` returned it."
  @type harness :: %{optional(String.t()) => term()}

  @typedoc """
  A harness the sweep could not account for, with why. The harness is `nil`
  when the failure was the listing itself rather than one resource.
  """
  @type unreclaimed :: {harness() | nil, term()}

  @typedoc """
  Whether the sweep saw the whole account, across every listing it made.

  `ListHarnesses` is paginated and the sweep reads one page, so an empty
  `unreclaimed` is only evidence that nothing leaked when this is true. A
  caller that reports "swept clean" without consulting it is asserting
  something it never checked.
  """
  @type complete? :: boolean()

  @type t :: %__MODULE__{
          matched: [harness()],
          skipped: [harness()],
          reclaimed: [harness()],
          unconfirmed: [harness()],
          unreclaimed: [unreclaimed()],
          complete?: complete?()
        }
end
