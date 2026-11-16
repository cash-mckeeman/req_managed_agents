# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - Unreleased

### Changed

- Source now lives in the `aws_event_stream/` package of the
  [req_managed_agents monorepo](https://github.com/cash-mckeeman/req_managed_agents).
  The Hex package, public API, MIT license and Elixir requirement are unchanged.

## [0.2.0] - 2026-10-02

### Changed

- **Elixir 1.18 or later is now required** (previously 1.15). CI tests Elixir
  1.18 / OTP 27 and Elixir 1.20 / OTP 29. The codec's behaviour and API are
  unchanged.

## [0.1.1] - 2026-07-05

### Fixed

- **Decoder now validates the prelude CRC as soon as the 12-byte prelude
  arrives**, before waiting for the declared frame length. A corrupt
  `total_length` that inflates the frame size previously made `decode/2` report
  an incomplete frame forever; it now surfaces `{:error, {:invalid_prelude_crc,
  _}}` immediately. Matches `aws-sdk-go-v2`, whose `corrupted_length` test
  vector this change is required for. Decoding of well-formed frames — including
  incremental/chunk-boundary streaming — is unchanged.

### Added

- **Upstream golden-vector corpus** under `test/fixtures/aws_sdk_go_v2/`,
  mirroring `aws/aws-sdk-go-v2`'s event-stream test vectors byte-for-byte with a
  `manifest.json` pinning the upstream commit. The suite decodes each positive
  vector to the upstream-described message, re-encodes it byte-identically,
  and asserts the documented error for each corrupted vector.
- **`mix aws_event_stream.sync_fixtures`** — maintainer task that refreshes the
  corpus over verified TLS (exit `0` = up to date, `2` = fixtures updated). Not
  shipped in the published package.
- **Scheduled `fixtures-watch` workflow** that runs the sync task weekly and
  opens an issue when the upstream corpus drifts, noting whether the codec still
  passes against the new vectors.

## [0.1.0] - 2026-07-02

### Added

- Initial release: pure-Elixir codec for the AWS `vnd.amazon.eventstream` binary
  protocol. Symmetric encode/decode of all header types, prelude and
  whole-message CRC32 validation, incremental (chunk-boundary-safe) decoding
  with explicit tagged errors, and an optional JSON layer that classifies frames
  by `:message-type` and unwraps Bedrock `{"bytes": …}` envelopes.

[0.2.0]: https://github.com/cash-mckeeman/aws_event_stream/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/cash-mckeeman/aws_event_stream/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/cash-mckeeman/aws_event_stream/releases/tag/v0.1.0

[0.2.1]: https://github.com/cash-mckeeman/req_managed_agents/tree/aws_event_stream-v0.2.1/aws_event_stream
