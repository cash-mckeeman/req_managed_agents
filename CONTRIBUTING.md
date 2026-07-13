# Contributing

Thanks for contributing to `req_managed_agents`.

## Development

```sh
mix deps.get
mix test              # full suite
mix credo --strict    # linting
mix dialyzer          # type analysis
mix format            # formatting (CI enforces --check-formatted)
```

All four are enforced in CI. Run them before opening a PR.

## Struct vocabulary (binding convention)

Domain values crossing a module boundary are structs, not bare maps.

**A domain struct carries:** `@enforce_keys` for identity fields; a precise
`@type t :: %__MODULE__{...}` with real field types (never bare `map()`/`term()`
when a tighter type is known, and never a bare `%__MODULE__{}` with no fields);
`@derive Jason.Encoder` when it is serialized; and a `new/1` constructor whenever
construction is non-trivial or accepts a map / JSON round-trip — coercion and
validation live in `new/1`, in ONE place, not scattered `atomize_*`/`normalize_*`
clauses at every call site (see `Outcome.new/1`, `Agent.Spec.new/1`).

**Public functions accept and return structs.** A value the library *interprets*,
or whose shape it *documents in an `@spec`*, is a fixed record — model it as a
struct. In particular: a provisioner handle, a provider spec, and anything with a
documented `%{key: type, ...}` return shape.

**GenServer state is a typed struct** (`%Module.State{}` with `@type t`), never an
ad-hoc map — a mistyped key must fail at compile/dialyzer time, not as a silent
runtime `nil`. If a struct feels like overkill for a private per-turn value, look
at `Providers.Local`'s conn: *"the conn is a struct, not a bag of keys."*

**Behaviours are fully typespec'd:** `@callback`s use the real struct types (e.g.
`Agent.Spec.t()`, not `map()`); implementers carry `@impl true`. A provider that
receives an `Agent.Spec` coerces via `Spec.new/1` at its boundary rather than
struct-dotting a loose input.

**Store / result vocabulary is uniform:** a store-style lookup returns
`{:ok, value} | :miss` (`Provisioner.Store`); equivalent operations across
providers return the same tuple shapes.

**Legitimately a map — do NOT structify (YAGNI):** a decoded external JSON response
(thin HTTP-client results); a provider-verbatim payload the library never
interprets (`environment` / `environment_variables`, environment `config`, provider
tool wire maps); the raw `events` / `raw` fields preserved unaltered; opaque
telemetry / `metadata`; and a genuinely provider-private, per-provider-shaped
`conn` / `input` / `handle` typed `term()` — provided the caller treats it opaquely
(via accessors), not by reaching into known keys.
