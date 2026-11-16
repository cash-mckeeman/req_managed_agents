#!/usr/bin/env bash
# Compile real package artifacts outside the monorepo against the relocated
# codec and previously released versions, without publishing anything.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
export MIX_ENV=prod RMA_PUBLISH=1
for package in req_managed_agents aws_event_stream; do
  (cd "$root/$package" && mix hex.build --output "$d/$package.tar")
  elixir "$root/.github/scripts/check_package.exs" "$d/$package.tar"
  mkdir "$d/$package-unpacked"
  tar -xf "$d/$package.tar" -C "$d/$package-unpacked" contents.tar.gz
  tar -xzf "$d/$package-unpacked/contents.tar.gz" -C "$d/$package-unpacked"
done
export CODEC_CONSUMER_CLIENT="$d/req_managed_agents-unpacked"
export CODEC_CONSUMER_CODEC="$d/aws_event_stream-unpacked"
for version in source 0.1.1 0.1.0; do
  mkdir "$d/consumer-$version"
  cat > "$d/consumer-$version/mix.exs" <<'EX'
defmodule CodecConsumer.MixProject do
  use Mix.Project
  def project do
    codec = case System.fetch_env!("CODEC_CONSUMER_VERSION") do
      "source" -> {:aws_event_stream, path: System.fetch_env!("CODEC_CONSUMER_CODEC"), override: true}
      version -> {:aws_event_stream, "== " <> version, override: true}
    end
    [app: :codec_consumer, version: "0.0.0", deps: [
      {:req_managed_agents, path: System.fetch_env!("CODEC_CONSUMER_CLIENT")},
      {:ex_aws_auth, "~> 1.4"}, codec
    ]]
  end
end
EX
  cp "$root/req_managed_agents/mix.lock" "$d/consumer-$version/mix.lock"
  cat > "$d/consumer-$version/probe.exs" <<'EX'
message = %AWSEventStream.Message{
  headers: [
    %AWSEventStream.Header{name: ":message-type", type: :string, value: "event"},
    %AWSEventStream.Header{name: ":event-type", type: :string, value: "messageStop"}
  ], payload: ~s({"stopReason":"end_turn"})
}
frame = message |> AWSEventStream.encode() |> IO.iodata_to_binary()
{[{:ok, ^message}], <<>>} = AWSEventStream.decode(frame)
{[%{"messageStop" => %{"stopReason" => "end_turn"}}], <<>>} =
  ReqManagedAgents.Providers.BedrockAgentCore.EventStream.decode(frame)
[<<_::binary-size(5)>> = first, rest] = [binary_part(frame, 0, 5), binary_part(frame, 5, byte_size(frame) - 5)]
{[], ^first} = ReqManagedAgents.Providers.BedrockAgentCore.EventStream.decode(first)
{[_], <<>>} = ReqManagedAgents.Providers.BedrockAgentCore.EventStream.decode(first <> rest)
IO.puts("external codec consumer passed: #{Application.spec(:aws_event_stream, :vsn)}")
EX
  export CODEC_CONSUMER_VERSION="$version"
  (cd "$d/consumer-$version" && mix deps.get && mix run probe.exs)
done
