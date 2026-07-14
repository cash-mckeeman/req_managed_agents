# OpenTelemetry is a soft dependency: OpenTelemetry.emit_span/2 only calls
# :otel_tracer / :opentelemetry after Code.ensure_loaded?(:otel_tracer), so the
# functions are absent from the PLT by design. If opentelemetry_api ever
# becomes an optional dep, delete this file.
[
  {"lib/req_managed_agents/open_telemetry.ex", :unknown_function},
  # The agentcore model sync task's :httpc/:ssl/:public_key calls resolve at
  # runtime (Mix.ensure_application!); these apps can't go in the PLT the
  # library ships (maintainer-only task, mirrors the aws_event_stream
  # sync_fixtures precedent).
  {"lib/mix/tasks/rma.sync_agentcore_model.ex", :unknown_function}
]
