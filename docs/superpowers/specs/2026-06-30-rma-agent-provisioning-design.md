# RMA Agent Provisioning & Teardown — Design

**Date:** 2026-06-30
**Status:** Design (approved in brainstorming; ready for implementation plan)
**Repo:** `req_managed_agents`

**Goal:** Make provider-side agent provisioning and teardown a first-class part of the
`ReqManagedAgents.Provider` abstraction — the symmetric *setup* half of invocation — so it lives
with the provider-specific knowledge it embodies, instead of in consumer adapters.

**Context:** See the ecosystem position doc (`mimir-gateway`,
`docs/planning/2026-06-30-agent-provisioning-ownership.md`). The short version: creating a Claude
agent+environment vs. a Bedrock Harness is provider-specific knowledge — exactly what `Provider`
exists to encapsulate. RMA already owns half of it (`Provisioner` for the hash-cache; `Client` /
`AgentCore.Client` for the create primitives), but the actual create/READY-poll/teardown logic
currently lives in `biai-managed-agents`' adapter, and the `Provisioner` `ref` type is
Claude-shaped. This design unifies and completes it.

## Scope

**In scope:** a canonical agent `spec`, `provision/2` + `teardown/1` `Provider` callbacks, a public
`ReqManagedAgents.provision/3` + `teardown/2`, a generalized provider-keyed `Provisioner`, and the
two providers' implementations (moving the create/poll/teardown logic in from biai).

**Out of scope (separate spec):** exposing the canonical last-turn outcome (`text` /
`custom_tool_uses` / `server_tool_uses`) and token `usage` on the `Session` result. Tracked
separately; together with this work they reduce biai's adapter to near-pure glue.

## Design decisions (settled in brainstorming)

- **model_config is an opaque pass-through.** The app builds a provider-shaped `model_config`
  value (where mimir `apiBase` / token-vault wiring lives); RMA stores it in the spec and hands it
  to `provision` verbatim, never interpreting it. RMA stays mimir-agnostic and provider-generic.
- **Provisioning is a separate, explicit step.** `Session.run/2` is unchanged — you pass it the
  provisioned handle exactly as today. No `spec:`-absorbing magic in `Session`.
- **Provision-once → durable handle → reuse → teardown.** Both providers create *persistent,
  reusable* resources; the returned handle (Claude `%{agent_id, environment_id}`, Bedrock
  `%{harness_arn}`) is the durable artifact. `Provisioner` caches it in-process by spec-hash; the
  caller may also persist the handle externally and skip provisioning entirely next time.

## The canonical agent spec

Generalizes the existing `ReqManagedAgents.Provisioner.spec` (the current `model: String.t()`
becomes the opaque `model_config`):

```elixir
@type spec :: %{
        system_prompt: String.t(),
        tools: [map()],                  # custom-tool defs (ReqManagedAgents.ToolSchema output)
        terminal_tool: String.t() | nil,
        model_config: term()             # OPAQUE, provider-shaped, app-built
      }
```

The spec is the provider-agnostic *definition* of an agent. It is the cache key (hashed) and the
input to `provision`.

## Provider behaviour additions

```elixir
@typedoc "Provider-private handle to a provisioned, reusable server-side resource."
@type handle :: term()

@doc "Create (or look up) the provider-side agent resource for `spec`; return a durable handle."
@callback provision(spec(), opts :: keyword()) :: {:ok, handle()} | {:error, term()}

@doc "Delete the provider-side resource named by `handle`."
@callback teardown(handle()) :: :ok | {:error, term()}

@optional_callbacks teardown: 1
```

- `provision/2` is **required** — every managed-agent provider knows how to create its resource.
  (This is a behaviour change; the only implementers are RMA's own providers.)
- `teardown/1` is **optional** — some resources may auto-expire; a provider without teardown
  simply doesn't define it, and `ReqManagedAgents.teardown/2` returns `{:error, :not_supported}`.
- The returned `handle` is exactly what `open/2` already consumes (Claude reads
  `agent_id`/`environment_id`; Bedrock reads `harness_arn`). So **`Session.run/2` needs no
  change** — the caller splats the handle into the run opts as today.
- `opts` carries provider-specific infrastructure not part of the portable spec (e.g. Bedrock's
  `execution_role_arn`) and the injectable create/delete seams used in tests
  (`:create_fun` / `:delete_fun`, mirroring the existing `:invoke_fun` pattern).

## Public API + generalized `Provisioner`

```elixir
@spec ReqManagedAgents.provision(module(), Provider.spec(), keyword()) ::
        {:ok, Provider.handle()} | {:error, term()}
def provision(provider, spec, opts \\ []), do: Provisioner.ensure(provider, spec, opts)

@spec ReqManagedAgents.teardown(module(), Provider.handle()) :: :ok | {:error, term()}
def teardown(provider, handle)   # delegates to provider.teardown/1 + evicts from the cache
```

`Provisioner` changes:

- `ref` type → opaque `handle :: term()` (was Claude-shaped `%{agent_id, environment_id}`).
- Cache key → `hash({provider, spec})` so the same spec on two providers yields distinct handles.
- `ensure(provider, spec, opts)` looks up the cache; on a miss it calls `provider.provision(spec,
  opts)`, stores the handle, and returns it. (The current `ensure(spec, create_fun)` shape is
  replaced; the `create_fun` moves into the provider.)
- Errors from `provision` surface as `{:error, {:provision_failed, reason}}` (preserving today's
  wrapping).

The ETS cache remains an in-process optimization; durability is provided by the handle itself
(persistable by the caller).

## Provider implementations (logic moved in from biai)

### `ClaudeManagedAgents`

```
provision(spec, opts):
  {:ok, %{"id" => agent_id}} = Client.create_agent(client, %{model: spec.model_config,
                                  system: spec.system_prompt, tools: spec.tools})
  {:ok, %{"id" => env_id}}   = Client.create_environment(client, opts[:environment] || default_env)
  {:ok, %{agent_id: agent_id, environment_id: env_id}}

teardown(%{agent_id: a, environment_id: e}):
  Client.archive_agent(client, a); Client.archive_environment(client, e); :ok
```

`client` comes from `opts[:client] || Client.new()` (same pattern as `open/2`). The Claude default
environment config is a sensible default, overridable via `opts[:environment]`.

### `BedrockAgentCore`

Absorbs biai's `default_create` (currently in the adapter): deterministic naming, `create_harness`,
and the **READY-poll** (`get_harness` until READY), plus `list_harnesses` reuse on a cold miss.

```
provision(spec, opts):
  name = harness_name(spec, opts[:name_prefix])   # deterministic, spec-hash-derived (anti-409)
  case find_ready_harness(client, name) do        # list_harnesses — cross-process reuse
    {:ok, arn} -> {:ok, %{harness_arn: arn}}
    :none ->
      {:ok, arn} = create_harness(client, %{name: name, system_prompt: spec.system_prompt,
                      tools: spec.tools, model_config: spec.model_config,
                      execution_role_arn: opts[:execution_role_arn]})
      :ok = poll_until_ready(client, arn)          # GetHarness READY-poll
      {:ok, %{harness_arn: arn}}
  end

teardown(%{harness_arn: arn}):
  AgentCore.Client.delete_harness(client, arn); :ok
```

The deterministic-name reuse (`list_harnesses`) is a per-provider optimization: it lets a cold
process re-find a persisted harness without a stored ARN. Claude's `provision` does not require an
equivalent — the handle is the durable artifact, and the in-process cache covers a single run.

## What stays in biai-managed-agents

- Building the `spec` from a Jido agent: Actions → `ToolSchema.to_custom_tool/3`, system prompt,
  model selection, `terminal_tool`.
- The mimir model-routing → `model_config` blob (`"mimir:<logical>"` → `base_url` + virtual key →
  the opaque value).
- `execution_role_arn` / harness infra passed as `provision` opts; any cosmetic `name_prefix`.
- Orchestration (`finalize` / self-repair), the `:self_managed` local runtime, the runtime
  registry, and `%ManagedAgents.Result{}`.

"Teardown" disambiguation: biai's `agent.teardown(tool_ctx)` (local tool-context cleanup) is
unchanged and unrelated; the new `Provider.teardown(handle)` deletes the *provider* resource.

## Error handling

- `provision` failures → `{:error, {:provision_failed, reason}}` (Provisioner wrapping). Provider
  internals surface specific reasons: `{:create_failed, _}`, `{:ready_timeout, arn}`, client errors.
- `teardown` → `:ok` | `{:error, reason}`; `ReqManagedAgents.teardown/2` on a provider without the
  callback → `{:error, :not_supported}`.

## Testing

- **Per-provider `provision`/`teardown`** via injected `:create_fun` / `:delete_fun` seams (no live
  AWS/Anthropic), asserting the right control-plane calls and the returned handle shape; Bedrock:
  the READY-poll retries and the `list_harnesses` reuse branch.
- **`Provisioner`**: provider-keyed cache (same spec, two providers → two handles; cache hit skips
  `provision`; miss calls it once); error wrapping.
- **Conformance**: both providers implement `provision/2` (and `teardown/1`); `provision` returns a
  handle that `open/2` accepts unchanged.

## Migration / compatibility

- Adding a required `provision/2` callback touches only RMA's two providers.
- `Session.run/2` and the facade are unchanged. Existing callers that already hold a handle
  (`agent_id`/`harness_arn`) keep working with no change.
- The old `Provisioner.ensure(spec, create_fun)` arity is replaced by `ensure(provider, spec,
  opts)`. biai's adapter migrates from supplying a `create_fun` to calling
  `ReqManagedAgents.provision(provider, spec, opts)` — a net deletion of its `default_create`,
  naming, and READY-poll code.

## Open implementation questions (resolve during planning)

- Confirm the Claude control-plane teardown verbs (`archive_agent`/`archive_environment` vs
  delete) and whether a default environment config belongs in the provider or must always be
  supplied via opts.
- Confirm `AgentCore.Client` exposes `delete_harness` (teardown) or whether it must be added.
- Decide the exact `harness_name/2` derivation (spec-hash + optional prefix) and the
  `list_harnesses` match contract.
