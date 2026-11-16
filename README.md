# req_managed_agents

This repository holds the managed-agent client, its session host, and an independent AWS Event Stream codec.

| Package | Directory | Depends on |
|---|---|---|
| [`aws_event_stream`](https://hex.pm/packages/aws_event_stream) | [`aws_event_stream/`](aws_event_stream/) | optional: jason |
| [`req_managed_agents`](https://hex.pm/packages/req_managed_agents) | [`req_managed_agents/`](req_managed_agents/) | req, finch, jason, telemetry; optional: ex_aws_auth, aws_event_stream, req_llm |
| [`req_managed_agents_host`](https://hex.pm/packages/req_managed_agents_host) | [`req_managed_agents_host/`](req_managed_agents_host/) | req_managed_agents, jason |

`req_managed_agents` is a provider-agnostic client for agent runtimes: one `Session` loop over
Claude Managed Agents, Bedrock AgentCore, or a local in-process loop, with your tools running
locally. `req_managed_agents_host` is a durable single-node session host built on it.

## Versions

`req_managed_agents` and `req_managed_agents_host` share each minor version, released from the same commit. `req_managed_agents_host`
X.Y requires `req_managed_agents` `~> X.Y.0`. A patch release covers one package.
`req_managed_agents_host` releases up to 0.3.0 were published from a separate repository.
That repository is archived after both 0.12.0 packages are verified on Hex.

`aws_event_stream` keeps its own version and Elixir 1.18 floor. Its releases use
`aws_event_stream-vX.Y.Z` tags; `vX.Y.0` tags release only the client and host.

## Development

Each package is its own Mix project. Run Mix from its directory:

    cd req_managed_agents_host && mix deps.get && mix test

In development, `req_managed_agents_host` builds against the `req_managed_agents` directory beside
it, and the client builds against the `aws_event_stream` sibling. Publication uses
Hex requirements instead (`RMA_PUBLISH=1`). See [CONTRIBUTING.md](CONTRIBUTING.md).
