# req_managed_agents

This repository holds two Elixir packages, released together.

| Package | Directory | Depends on |
|---|---|---|
| [`req_managed_agents`](https://hex.pm/packages/req_managed_agents) | [`req_managed_agents/`](req_managed_agents/) | req, finch, jason, telemetry; optional: ex_aws_auth, aws_event_stream, req_llm |
| [`req_managed_agents_host`](https://hex.pm/packages/req_managed_agents_host) | [`req_managed_agents_host/`](req_managed_agents_host/) | req_managed_agents, jason |

`req_managed_agents` is a provider-agnostic client for agent runtimes: one `Session` loop over
Claude Managed Agents, Bedrock AgentCore, or a local in-process loop, with your tools running
locally. `req_managed_agents_host` is a durable single-node session host built on it.

## Versions

The two packages share each minor version, released from the same commit. `req_managed_agents_host`
X.Y requires `req_managed_agents` `~> X.Y.0`. A patch release covers one package.
`req_managed_agents_host` releases up to 0.3.0 were published from a separate repository.
That repository is archived after both 0.12.0 packages are verified on Hex.

## Development

Each package is its own Mix project. Run Mix from its directory:

    cd req_managed_agents_host && mix deps.get && mix test

In development, `req_managed_agents_host` builds against the `req_managed_agents` directory beside
it. See [CONTRIBUTING.md](CONTRIBUTING.md).
