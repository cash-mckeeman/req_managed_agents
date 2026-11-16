[
  # The sync task's :public_key calls resolve at runtime (Mix.ensure_application!);
  # :public_key can't go in the PLT — dialyzer crashes core-compiling its beams on
  # some OTP builds (seen on 29.0.2).
  {"lib/mix/tasks/aws_event_stream.sync_fixtures.ex", :unknown_function}
]
