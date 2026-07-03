# QA-CHECKPOINT C — AgentCore Artifacts (PR MIM-65)

**Date:** 2026-07-03
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:** 4f27d754, 2b89f029, 0b3b4e94, 25b13631, 67e7cbc7, 188e9230
**Worktree:** `.claude/worktrees/rma-030-artifacts`
**Scope:** `environment`/`environment_variables` opaque spec fields (spec-hash covered);
`Client.invoke_agent_runtime_command/2` (`%CommandResult{}`, `on_output`,
chunk-wrapped/bare events, idle stall, exception frames); `Artifacts.AgentCoreSessionStorage`
(python/argv/base64, chunked put, exit-3 sentinel, name + base_path validation); docs;
release gate.

---

## Preflight

```
$ jj log -r '@-' --no-pager -T 'commit_id.short()'
○  188e92306ec7
```

✅ Preflight passes — on expected commit.

---

## Setup

All commands run from the worktree root. One scratch file (`test/qa_c_scratch.exs`)
was authored, executed, and deleted before committing. No `lib/` files were modified.

**Baseline:** `mix test` before scratch creation:

```
$ mix test 2>&1 | tail -4
.......................
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 235 passed, 9 excluded
```

## Execution method

All scenarios ran as real ExUnit tests (`async: false`) in `test/qa_c_scratch.exs`,
executed with:

```
$ mix test test/qa_c_scratch.exs --seed 0
Running ExUnit with seed: 0, max_cases: 40
Excluding tags: [:live]
.................
Finished in 0.4 seconds (0.00s async, 0.4s sync)
Result: 17 passed
```

Command API scenarios (S1a–S1f) stubbed HTTP with `Bypass` (the existing pattern
from `command_test.exs`). SessionStorage scenarios (S2a–S2g) injected a
`command_fun` lambda as the `:command_fun` option to `Storage.store/5`, avoiding
any network. Environment scenarios (S3a–S3d) used `Bypass` for wire assertions
and exercised `P.harness_name/2` directly for hash distinguishability.

---

## Scenario 1a — chunk-wrapped events: stdout/stderr interleave order

**Motivation:** Unit suite verifies stdout and stderr are collected across frames.
This scenario verifies that `on_output` fires in wire order across alternating
stdout/stderr deltas, and that the accumulated `%CommandResult{}` concatenates
correctly.

**Setup:** Bypass stub sends: `contentStart`, `stdout "line1\n"`, `stderr "err1"`,
`stdout "line2\n"`, `contentStop exitCode:0` — all chunk-wrapped.

**Execution:**

```elixir
assert {:ok, %CommandResult{stdout: "line1\nline2\n", stderr: "err1", exit_code: 0}} =
         Client.invoke_agent_runtime_command(client, inv(on_output: ...))

assert_received {:out, :stdout, "line1\n"}
assert_received {:out, :stderr, "err1"}
assert_received {:out, :stdout, "line2\n"}
```

**Result:** ✅ Passed. stdout and stderr concatenate independently; `on_output` fires
in wire order before `invoke_agent_runtime_command/2` returns.

---

## Scenario 1b — bare (unwrapped) events; non-zero exit is a result

**Motivation:** `unwrap_chunk/1` in the client has two clauses: `%{"chunk" => inner}`
and the identity fallback for bare events. Unit suite covers both. This scenario
confirms non-zero exit (127) is returned as `{:ok, %CommandResult{exit_code: 127}}`
not `{:error, ...}`.

**Execution:**

```elixir
# Bypass sends bare frames (no "chunk" wrapper):
frame(~s({"contentDelta":{"stderr":"fatal"}}))
frame(~s({"contentStop":{"exitCode":127,"status":"completed"}}))

assert {:ok, %CommandResult{stderr: "fatal", exit_code: 127}} =
         Client.invoke_agent_runtime_command(client, inv())
```

**Result:** ✅ Passed. Bare events decoded; non-zero exit returned as `{:ok, _}`.

---

## Scenario 1c — single delta carrying BOTH stdout AND stderr keys

**Motivation:** `fire_delta_output/2` guards each key independently:
```elixir
if is_binary(d["stdout"]) and d["stdout"] != "", do: on_output.(:stdout, d["stdout"])
if is_binary(d["stderr"]) and d["stderr"] != "", do: on_output.(:stderr, d["stderr"])
```
The unit suite only sends stdout and stderr in *separate* frames. This probe
verifies a single `contentDelta` map with both keys fires two `on_output` callbacks
and accumulates both into the `%CommandResult{}`.

**Execution:**

```elixir
# One frame, both keys:
frame(~s({"chunk":{"contentDelta":{"stdout":"out","stderr":"err"}}}))

assert {:ok, %CommandResult{stdout: "out", stderr: "err", exit_code: 0}} = ...
assert_received {:out, :stdout, "out"}
assert_received {:out, :stderr, "err"}
```

**Result:** ✅ Passed. Both callbacks fire from one delta. Not covered by the unit
suite — **test_gap** noted but low risk (implementation is straightforward).

---

## Scenario 1d — qualifier query param; timeout_seconds in body

**Motivation:** `invoke_agent_runtime_command/2` serializes `:qualifier` as a query
parameter and `:timeout_seconds` as `"timeout"` in the JSON body. The unit suite's
`command_test.exs` tests `timeout_seconds` but **does not test `qualifier`**.
This scenario confirms both paths.

**Execution (Bypass checks wire shape):**

```elixir
# Bypass asserts:
assert conn.query_string =~ "qualifier=blue"
assert decoded["timeout"] == 60
refute Map.has_key?(decoded, "qualifier")

Client.invoke_agent_runtime_command(client, inv(qualifier: "blue", timeout_seconds: 60))
```

**Result:** ✅ Passed. Qualifier appears in query string (URL-encoded via
`URI.encode_query/1`); `"timeout"` key in body; qualifier absent from body.
**test_gap**: unit suite has no qualifier test for `invoke_agent_runtime_command`.

---

## Scenario 1e — idle stall → transport timeout

**Motivation:** `idle_timeout` replaces `receive_timeout` for the streaming invoke
path. Bypass sleeps 800ms between chunks; test sets `idle_timeout: 200`.

**Execution:**

```elixir
assert {:error, %Req.TransportError{reason: :timeout}} =
         Client.invoke_agent_runtime_command(client, inv(idle_timeout: 200))
Bypass.pass(bypass)
```

**Result:** ✅ Passed. Transport error returned; idle_timeout governs inter-chunk
silence correctly.

---

## Scenario 1f — exception frame surfaces as command_stream_error

**Motivation:** `command_result_from_events/1` calls `command_stream_error/1` which
scans for `%{"__stream_error__" => ...}` before building the `%CommandResult{}`.

**Execution:**

```elixir
frame(~s({"__stream_error__":{"type":"validationException","message":"bad input"}}))

assert {:error, {:command_stream_error, "validationException", _}} =
         Client.invoke_agent_runtime_command(client, inv())
```

**Result:** ✅ Passed. Exception frame surfaces as `{:error, {:command_stream_error, ...}}`.

---

## Scenario 2a — SessionStorage list → fetch → delete round-trip

**Motivation:** Compose all three verbs in sequence with injected `command_fun`.
Verifies the Python command strings are routed to the right operations and that
`%Artifact{}` structs are built correctly from the JSON list output.

**Execution:**

```elixir
# list: command contains "scandir", returns JSON → [{name, size}]
assert {:ok, [%Artifact{name: "report.md", size: 42}]} = Artifacts.list(store)

# fetch: command contains "b64encode", returns Base64 → decoded bytes
assert {:ok, "HELLO_BINARY"} = Artifacts.fetch(store, "report.md")

# delete: command contains "os.remove", exit_code: 0 → :ok
assert :ok = Artifacts.delete(store, "report.md")
```

**Result:** ✅ Passed. Full round-trip verified end-to-end.

---

## Scenario 2b — exit-3 sentinel maps to :not_found for every verb

**Execution:**

```elixir
nf = fn _ -> {:ok, %CommandResult{exit_code: 3}} end

assert {:error, :not_found} = Artifacts.fetch(store(nf), "missing.txt")
assert {:error, :not_found} = Artifacts.delete(store(nf), "missing.txt")
```

**Result:** ✅ Passed. `@not_found_exit 3` used consistently by both `fetch` and
`delete`. `list` does not use the sentinel (scandir returns `[]` for empty dirs).

---

## Scenario 2c — command_failed carries stderr; transport errors pass through

**Execution:**

```elixir
boom = fn _ -> {:ok, %CommandResult{stderr: "permission denied", exit_code: 1}} end

assert {:error, {:command_failed, %CommandResult{stderr: "permission denied", exit_code: 1}}} =
         Artifacts.fetch(store(boom), "secret.txt")

assert {:error, {:command_failed, %CommandResult{stderr: "permission denied", exit_code: 1}}} =
         Artifacts.delete(store(boom), "secret.txt")

assert {:error, :timeout} = Artifacts.list(store(fn _ -> {:error, :timeout} end))
```

**Result:** ✅ Passed. `stderr` never swallowed; transport errors pass through.

---

## Scenario 2d — invalid names rejected before any command runs

**Execution:**

```elixir
fun = fn _ -> flunk("no command should run") end

assert {:error, {:invalid_name, "../etc/passwd"}} = Artifacts.fetch(store(fun), "../etc/passwd")
assert {:error, {:invalid_name, "a b"}} = Artifacts.delete(store(fun), "a b")
assert {:error, {:invalid_name, "foo/bar"}} = Artifacts.put(store(fun), "foo/bar", "x")
assert {:error, {:invalid_name, "a'b"}} = Artifacts.fetch(store(fun), "a'b")
```

**Result:** ✅ Passed. Slash, space, single-quote all rejected. No command function
is invoked.

---

## Scenario 2e — base_path with single quote raises at store/5

**Execution:**

```elixir
assert_raise ArgumentError, ~r/base_path must not contain single quotes/, fn ->
  Storage.store(:c, arn, sid, "/mnt/user's-data")
end
```

**Result:** ✅ Passed. Guard fires at construction time (programmer error) before
any command can be built.

---

## Scenario 2f — put >64KB: ALL generated commands ≤65_536 chars

**Motivation:** Unit suite (`agent_core_session_storage_test.exs` line 56–73) asserts
`length(c1) <= 65_536` for the FIRST append command and the final decode command.
This probe generates ~120KB content (base64 → ~163KB → 4 append chunks) and
**asserts every command** is within the wire cap.

**Execution:**

```elixir
contents = :crypto.strong_rand_bytes(120_000)
# command_fun captures every call to an ETS table:
assert :ok = Artifacts.put(store(fun), "big.bin", contents)

total_commands = :counters.get(counter, 1)
assert total_commands >= 3

violations =
  :ets.tab2list(all_commands)
  |> Enum.filter(fn {_n, len} -> len > 65_536 end)

assert violations == []
```

**Result:** ✅ Passed. For 120KB content: 5 commands total (4 append + 1 decode). All
commands ≤ 65_536 chars. **test_gap** in unit suite: only first command is
length-checked; the QA probe verifies every command.

---

## Scenario 2g — adversarial name probes: single-char, three-dots, double-dot traversal

**Motivation:** `@name_re ~r/^[A-Za-z0-9._-]+$/` defines the charset. Three
boundary cases are probed:

1. `"a"` — single character — valid per spec.
2. `"..."` — three dots — charset-valid (`.` is allowed). Resolves to
   `/mnt/data/...` which is a valid POSIX filename with no traversal risk.
3. `".."` — two dots — **charset-valid** (`/^[A-Za-z0-9._-]+$/` does not anchor
   on path components). `path/2` yields `base_path <> "/.."`.

### Probe: `"a"` (single char)

```elixir
assert :ok = Artifacts.delete(store(fun), "a")
# command contains "/mnt/data/a"
```

**Result:** ✅ Passed. Single-char name accepted, path correct.

### Probe: `"..."` (three dots)

```elixir
assert :ok = Artifacts.delete(store(fun), "...")
# command contains "/mnt/data/..."
```

**Result:** ✅ Passed. Three-dot name accepted. `/mnt/data/...` is a valid filename
(not a traversal). This is correct behavior.

### Probe: `".."` (two dots) — TRAVERSAL FINDING

```elixir
result = Artifacts.delete(store(fun), "..")
# Observed: :ok
# Generated command: "python3 -c '...' '/mnt/data/..'"
```

**Result:** ❌ **FINDING — code_bug.**

`validate/1` accepts the name `".."` because the character-class regex
`~r/^[A-Za-z0-9._-]+$/` matches it (`.` is in the charset). The generated shell
command then receives `'/mnt/data/..'` as the file path argument.

In the fetch verb, `os.path.isfile("/mnt/data/..")` returns `False` (it's a
directory), so `sys.exit(3)` fires and the call returns `{:error, :not_found}` —
safe but misleading. In the delete verb, `os.path.isfile("/mnt/data/..")` similarly
returns `False`, so exit 3 fires — again safe by accident.

**However, `put` would attempt to write to `/mnt/data/..` on a writable filesystem
(via the `open(..., "wb")` decode step), which could corrupt files one level above
`base_path`.**

**Classification:** `code_bug` — severity low in practice (AgentCore sessionStorage
root is operator-controlled and access is session-scoped), but `validate/1` should
explicitly reject `"."` and `".."`. The fix is a pre-check:

```elixir
defp validate(name) do
  if name in [".", ".."] do
    {:error, {:invalid_name, name}}
  else
    if Regex.match?(@name_re, name), do: :ok, else: {:error, {:invalid_name, name}}
  end
end
```

---

## Scenario 3a — environment + environment_variables both present in body

**Motivation:** `create_harness/2` uses `maybe_put/3` which passes values through
only when non-nil. Probe verifies the wire shape when both fields are set.

**Execution (Bypass asserts wire):**

```elixir
spec = %{..., environment: env, environment_variables: %{"DB_URL" => "postgres://localhost"}}
Client.create_harness(client, spec)

# Bypass assertions:
assert decoded["environment"] == env
assert decoded["environmentVariables"] == %{"DB_URL" => "postgres://localhost"}
```

**Result:** ✅ Passed. Both fields serialized under their camelCase wire keys.

---

## Scenario 3b — absent environment/environment_variables omitted from body

**Execution (Bypass asserts wire):**

```elixir
spec = %{name: ..., execution_role_arn: ..., system_prompt: ..., tools: [], model: ...}
# No environment or environment_variables keys

# Bypass assertions:
refute Map.has_key?(decoded, "environment")
refute Map.has_key?(decoded, "environmentVariables")
```

**Result:** ✅ Passed. `maybe_put/3` suppresses nil values; fields absent from wire.

---

## Scenario 3c — mixed: environment set, environment_variables absent

**Motivation:** Unit suite tests only both-set and both-absent. The mixed case
(`environment` present, `environment_variables` nil via `Map.get/2`) is exercised
here for the first time.

**Execution (Bypass asserts wire):**

```elixir
spec = %{..., environment: env}  # No environment_variables key

# Bypass assertions:
assert Map.has_key?(decoded, "environment")
refute Map.has_key?(decoded, "environmentVariables")
assert decoded["environment"] == env
```

**Result:** ✅ Passed. Mixed case correct. `Map.get(spec, :environment_variables)`
returns `nil` when the key is absent; `maybe_put/3` skips it.

**test_gap**: mixed case not covered by unit suite.

---

## Scenario 3d — spec-hash covers environment fields

**Motivation:** `P.harness_name/2` hashes `spec` via `:erlang.term_to_binary/2`
with `:deterministic`. Specs with different `environment` or `environment_variables`
must hash to different names to prevent Provisioner cache collisions.

**Execution:**

```elixir
base = %{system_prompt: "x", tools: [], model_config: %{"m" => 1}}

with_env = Map.merge(base, %{environment: %{...filesystemConfig...},
                             environment_variables: %{"K" => "v"}})

with_env_only = Map.drop(with_env, [:environment_variables])

refute P.harness_name(base, "qa") == P.harness_name(with_env, "qa")
refute P.harness_name(with_env_only, "qa") == P.harness_name(with_env, "qa")
```

**Result:** ✅ Passed. All three specs produce distinct harness names.

---

## Release Gate

```
$ mix format --check-formatted
(no output — clean)
EXIT: 0
```
✅ Format clean.

```
$ mix test 2>&1 | tail -4
.......................
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 235 passed, 9 excluded
```
✅ Test suite green (scratch file deleted before this run).

```
$ mix credo --strict 2>&1 | tail -5
Analysis took 0.1 seconds (0.03s to load, 0.1s running 69 checks on 85 files)
618 mods/funs, found no issues.
```
✅ Credo strict clean.

```
$ MIX_ENV=dev mix docs --warnings-as-errors 2>&1 | tail -3
Generating docs...
View html docs at "doc/index.html"
```
✅ Docs build clean, no warnings.

```
$ mix dialyzer 2>&1 | tail -2
done in 0m1.71s
done (passed successfully)
```
✅ Dialyzer passes.

```
$ mix hex.build 2>&1 | head -5
Building req_managed_agents 0.2.1
...
```

**Tarball:** `req_managed_agents-0.2.1.tar` — version 0.2.1 as expected (Task 12 will bump to 0.3.0).

**Tarball includes `lib/req_managed_agents/artifacts/`:**

```
lib/req_managed_agents/artifacts
lib/req_managed_agents/artifacts/claude_files.ex
lib/req_managed_agents/artifacts/agent_core_session_storage.ex
```

✅ New artifacts directory ships in the tarball.

---

## Canary Legs (compile-only verification)

The smoke task at `lib/mix/tasks/req_managed_agents.agent_core.smoke.ex` imports
`AgentCore.Client`; `lib/req_managed_agents/agent_core.ex` re-exports it. Both
compile clean under `mix test` and `mix hex.build`. Full live canary legs require
AWS credentials and are excluded from offline QA (`:live` tag).

---

## Summary

| Step | Result |
|---|---|
| Preflight (commit `188e9230`) | ✅ |
| S1a chunk-wrapped events, stdout/stderr order | ✅ |
| S1b bare events, non-zero exit as result | ✅ |
| S1c single delta with both stdout+stderr | ✅ |
| S1d qualifier query param + timeout_seconds body | ✅ |
| S1e idle stall → transport timeout | ✅ |
| S1f exception frame → command_stream_error | ✅ |
| S2a list → fetch → delete round-trip | ✅ |
| S2b exit-3 sentinel :not_found for fetch + delete | ✅ |
| S2c command_failed carries stderr; transport passthrough | ✅ |
| S2d invalid names rejected pre-command | ✅ |
| S2e base_path single-quote raises at store/5 | ✅ |
| S2f put >64KB: ALL commands ≤65_536 chars | ✅ |
| S2g name probe `"a"` (single char) | ✅ |
| S2g name probe `"..."` (three dots, valid filename) | ✅ |
| S2g name probe `".."` (traversal — code_bug filed) | ❌ FINDING |
| S3a environment + environment_variables in wire body | ✅ |
| S3b absent fields omitted from wire body | ✅ |
| S3c mixed: environment set, environment_variables absent | ✅ |
| S3d spec-hash covers environment fields | ✅ |
| Release: mix format | ✅ |
| Release: mix test | ✅ 235/235 |
| Release: mix credo --strict | ✅ |
| Release: mix docs --warnings-as-errors | ✅ |
| Release: mix dialyzer | ✅ |
| Release: mix hex.build (v0.2.1, artifacts/ included) | ✅ |

**Total: 25 passed, 1 finding.**

---

## Findings

### F1 — code_bug: `validate/1` accepts `".."` → directory traversal via `put`

**Location:** `lib/req_managed_agents/artifacts/agent_core_session_storage.ex` `validate/1`
(line 183–185).

**Description:** `@name_re ~r/^[A-Za-z0-9._-]+$/` matches `".."` because `.` is in
the character class. This allows `path/2` to produce `base_path <> "/.."`. For
`fetch` and `delete`, the microVM's Python `os.path.isfile` returns `False` for a
directory path, so `sys.exit(3)` fires and the caller sees `{:error, :not_found}` —
accidentally safe. For `put`, the decode step writes `open(p, "wb")` where `p` is
the traversal path, which writes outside `base_path` on a writable filesystem.

**Reproduction:**
```elixir
store = Storage.store(client, arn, sid, "/mnt/data", command_fun: fun)
Artifacts.put({Storage, store}, "..", <<1, 2, 3>>)
# Runs: python3 ... '/mnt/data/data.bin.rma_b64_part' ... then
#        open('/mnt/data/..', 'wb').write(...)
```

**Fix:** Add explicit rejection of `"."` and `".."` in `validate/1` before the
regex match.

**Severity:** Low in production (sessionStorage root is session-scoped; callers are
not end-users), but the behaviour contradicts the stated no-traversal contract in
`@moduledoc`.

---

### F2 — test_gap: unit suite does not cover `qualifier` for `invoke_agent_runtime_command`

**Location:** `test/req_managed_agents/agent_core/command_test.exs`.

**Description:** `timeout_seconds` is tested (line 87) but `qualifier` serialization
to the query string is not. Probe S1d confirmed the implementation is correct.

### F3 — test_gap: unit suite only checks first command length in chunked `put`

**Location:** `test/req_managed_agents/artifacts/agent_core_session_storage_test.exs` (line 71).

**Description:** `assert_received {:cmd, 1, c1}` checks only the first append
command. Probe S2f verified all commands are within bounds, but the test coverage
gap means a regression (e.g. a larger chunk size) would only fail on the first
command.

### F4 — test_gap: mixed environment/environment_variables case not in unit suite

**Location:** `test/req_managed_agents/agent_core/client_test.exs`.

**Description:** Only both-set and both-absent are tested; the mixed case (one field
set) is untested. Implementation is correct (`maybe_put` handles nil). Low risk.
