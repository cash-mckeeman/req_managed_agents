# OpenTelemetry is a soft dependency: OpenTelemetry.emit_span/2 only calls
# :otel_tracer / :opentelemetry after Code.ensure_loaded?(:otel_tracer), so the
# functions are absent from the PLT by design. If opentelemetry_api ever
# becomes an optional dep (MIM-47 follow-up), delete this file.
[
  {"lib/req_managed_agents/open_telemetry.ex", :unknown_function}
]
