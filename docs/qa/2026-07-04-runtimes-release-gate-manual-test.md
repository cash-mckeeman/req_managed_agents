# RMA 0.4 QA-CHECKPOINT C — Runtimes + Release Gate Manual Test

**Date:** 2026-07-04
**Tester:** QA subagent (automated execution, adversarial posture)
**Stack tip commit:** e025c147 (docs) → 08ab443d (canary) → 8336cb6d (realization) → 2b667164 (runtimes surface)
**Scope:** `Provisioner.Runtimes` (validate/bootstrap_script/system_prompt_block/required_hosts + allowlist merge), spike-pinned template, bootstrap-on-handle (derived, never stored), canary legs, docs, FULL RELEASE GATE.

## Preflight

```
$ jj log -r '@-' --no-pager -T 'commit_id.short()'
e025c1475441
```

PASS — parent commit is e025c147.

---

## Scenario 1 — Rendered-Script Shell Audit (Local Execution)

**Purpose:** Render `bootstrap_script` for erlang 29.0.2 + elixir 1.20.2, verify bash syntax, execute in sandboxed HOME, prove idempotency (marker guard fires exactly once), prove PATH line uses literal `$HOME`.

### Step 1.1 — Render via `mix run`

```bash
$ mix run --no-start -e '
runtimes = [
  %{lang: :erlang, version: "29.0.2", via: :mise},
  %{lang: :elixir, version: "1.20.2", via: :mise}
]
script = ReqManagedAgents.Provisioner.Runtimes.bootstrap_script(runtimes)
File.write!("$SCRATCH/bootstrap_rendered.sh", script)
'
```

**Script output (525 bytes):**
```bash
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8
command -v mise >/dev/null 2>&1 || curl -fsSL https://mise.jdx.dev/install.sh | sh
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mise use --global erlang@29.0.2
mise use --global elixir@1.20.2-otp-29
mise install
grep -q 'mise activate-rma' ~/.bashrc 2>/dev/null || cat >> ~/.bashrc <<'RMA_BASHRC'
# mise activate-rma
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export LC_ALL=C.UTF-8 LANG=C.UTF-8
RMA_BASHRC
```

Ordering correct: erlang before elixir; elixir version is `1.20.2-otp-29` (major OTP suffix applied).

### Step 1.2 — `bash -n` syntax check

```
$ bash -n bootstrap_rendered.sh
(no output)
```

**PASS: syntax OK.**

### Step 1.3 — PATH literal `$HOME` audit

```
$ grep -cF 'export PATH="$HOME' bootstrap_rendered.sh
2
```

**PASS: both PATH export lines use literal `$HOME` (quoted, source-time expansion).**

Marker guard string `'mise activate-rma'` appears in guard and as block comment; bashrc block comes after `mise install` (ordering correct per spec).

### Step 1.4 — Sandboxed execution (`HOME=$SCRATCH/fakehome bash script.sh`)

```
$ HOME=$SCRATCH/fakehome bash bootstrap_rendered.sh
mise: installing mise...   → installed to $SCRATCH/fakehome/.local/bin/mise
mise erlang@29.0.2 ✓ installed
mise elixir@1.20.2-otp-29 ✓ installed
mise node@21.7.3     [1/3] install   ← extra tool from cwd .tool-versions
mise python@3.11.9   [1/3] install   ← extra tool from cwd .tool-versions
gpg: can't connect to the keyboxd: File name too long  ← scratch path too long for gpg socket
mise ERROR gpg failed
Exit code: 1
```

**Script stopped at `mise install`.** Root cause: mise reads `.tool-versions` from ancestor directories regardless of `HOME` override; `/Users/ryanmckeeman/.tool-versions` (in the cwd ancestor chain) adds `node` and `python` to the install set. The `gpg` keybox failure on python is a secondary failure caused by the scratch path length exceeding the socket path limit. Neither failure is in the audited runtimes (erlang + elixir both installed successfully before the abort).

**Boundary:** per brief, failures at or after `mise install` are acceptable when `HOME`-level redirection is in scope. Targets script structure.

**Structure audit summary:** shebang ✓, pipefail ✓, LC_ALL/LANG ✓, mise installer check ✓, PATH export with literal `$HOME` ✓ (×2), erlang before elixir ✓, elixir OTP suffix ✓, marker guard ✓, bashrc block after `mise install` ✓.

### Step 1.5 — Idempotency: marker guard exercised in isolation

Because the script aborted at `mise install`, the `.bashrc` write was never reached. The guard logic was exercised independently to confirm idempotency:

```bash
# Replicate exact guard + heredoc twice:
run_guard() {
  grep -q 'mise activate-rma' "$BASHRC" 2>/dev/null || cat >> "$BASHRC" <<'RMA_BASHRC'
# mise activate-rma
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export LC_ALL=C.UTF-8 LANG=C.UTF-8
RMA_BASHRC
}
run_guard; run_guard
grep -c 'mise activate-rma' "$BASHRC"
→ 1
```

**PASS: marker written exactly once after two runs. Block guard is idempotent.**

Fakehome cleaned up completely.

**Scenario 1 result: PASS (structure + idempotency). Execution stopped at `mise install` due to environmental issue (cwd `.tool-versions` + gpg socket path too long); noted, not a script bug.**

---

## Scenario 2 — Injection Attempts

**Purpose:** Verify that shell-injection strings are rejected by `validate/1` and that `ensure_environment/3` fires validation before any store/create call.

```elixir
$ mix run --no-start -e '...'

# version: "29; curl evil"
{:error, {:invalid_runtime, %{version: "29; curl evil", via: :mise, lang: :erlang}}}
PASS: semicolon injection rejected

# version: "29\nrm -rf /"
{:error, {:invalid_runtime, %{version: "29\nrm -rf /", via: :mise, lang: :erlang}}}
PASS: newline injection rejected

# version: "$(whoami)"
{:error, {:invalid_runtime, %{version: "$(whoami)", via: :mise, lang: :erlang}}}
PASS: command substitution rejected

# version: ""
{:error, {:invalid_runtime, %{version: "", via: :mise, lang: :erlang}}}
PASS: empty version rejected

# ensure_environment with semicolon entry — create_fun raises if called
{:error, {:invalid_runtime, %{...}}}
PASS: validation fires before any create — create_fun not called
```

Validation regex `~r/\A[0-9A-Za-z.\-+]+\z/` correctly closes the shell injection surface; the guard also blocks empty string. No store/create call is made on invalid input.

**Scenario 2 result: PASS (all 5 injection / edge-case checks).**

---

## Scenario 3 — `system_prompt_block/1` Adversarial (Unknown Language)

**Purpose:** Three runtimes including unknown-but-valid `:zig` lang; verify `zig@0.15.1` in embedded script, prose lists all three, output is deterministic.

```elixir
runtimes = [
  %{lang: :erlang, version: "29.0.2", via: :mise},
  %{lang: :elixir, version: "1.20.2", via: :mise},
  %{lang: :zig, version: "0.15.1", via: :mise}
]
block = Runtimes.system_prompt_block(runtimes)
```

**Block excerpt:**
```
## Runtime bootstrap

This session's environment declares the following runtimes: erlang 29.0.2, elixir 1.20.2, zig 0.15.1.
They are NOT preinstalled. Before the first command that needs them, run
the bootstrap script below EXACTLY ONCE via bash ...

```bash
...
mise use --global erlang@29.0.2
mise use --global elixir@1.20.2-otp-29
mise use --global zig@0.15.1
...
```
```

Assertions:
- `zig@0.15.1` appears in embedded script ✓
- prose lists `erlang 29.0.2`, `elixir 1.20.2`, `zig 0.15.1` ✓
- deterministic: two calls produce identical binary ✓

**Scenario 3 result: PASS.**

---

## Scenario 4 — Allowlist Merge Matrix

**Purpose:** Five matrix cases covering atom-keyed limited, string-keyed limited, unrestricted, absent networking, and consumer-pre-listed host dedup.

Runtime hosts read from `priv/runtime_bootstrap/allowed_hosts.json`:
```
["builds.hex.pm", "github.com", "mise.jdx.dev", "objects.githubusercontent.com", "repo.hex.pm"]
```

| Case | Input networking | Expected outcome | Result |
|------|-----------------|-----------------|--------|
| 1 — limited atom-keys | `%{type: :limited, allowed_hosts: ["example.com"]}` | `example.com` + all 5 runtime hosts merged | PASS |
| 2 — limited string-keys | `%{"type" => "limited", "allowed_hosts" => ["example.com"]}` | merged under `"allowed_hosts"` key; no atom-key leakage | PASS |
| 3 — unrestricted | `%{type: :unrestricted}` | no `allowed_hosts` key added | PASS |
| 4 — absent networking | (no `:networking` key) | no `:networking` key added to config | PASS |
| 5 — consumer pre-lists `builds.hex.pm` | `%{type: :limited, allowed_hosts: ["builds.hex.pm", "example.com"]}` | `builds.hex.pm` appears exactly once | PASS |

**Scenario 4 result: PASS (all 5 cases).**

---

## Scenario 5 — Bootstrap-on-Handle (Derived, Never Stored)

**Purpose:** Verify bootstrap is attached on the returned handle for all paths (create, 409 recovery, store hit) and that stored values are always exactly 3 fields; `resolve/2` never carries bootstrap.

### Part A — 409 recovery path carries bootstrap

```elixir
Provisioner.ensure_environment(:c, rt_spec, store: fresh_store(), create_fun: fn _ ->
  {:error, {:http_error, 409, %{}}} end, list_fun: fn -> {:ok, %{"data" => [recovered_env]}} end)
→ {:ok, %{name: _, bootstrap: %{script: _, instructions: _}, digest: _, environment_id: _}}
PASS: 409 recovery path carries bootstrap
```

### Part B — Spy store shows 3-field stored value (no bootstrap)

```
Store put count: 2
  put key=provision:env:9291F94... value keys=[:digest, :environment_id, :name]
  put key=digest:env:b429a1b0 value keys=[:digest, :environment_id, :name]
PASS: stored values have no :bootstrap key
PASS: exactly 2 store writes (provision + digest index)
```

### Part C — ETS store hit still derives bootstrap (no re-create)

```
Second call (ETS hit) bootstrap present: true
bootstrap scripts identical: true
PASS: ETS hit still derives bootstrap identically
```

### Part D — `resolve/2` never carries bootstrap

```
Resolved handle keys: [:name, :digest, :environment_id]
PASS: resolve never carries :bootstrap
```

**Scenario 5 result: PASS (all 4 parts).**

---

## Scenario 6 — Full Release Gate

### Step 6.1 — Check `mix.exs` `files:` (pre-authorized fix)

**Finding confirmed:** `files:` lacked `"priv"`, so `priv/runtime_bootstrap/` would not ship.

**FIX APPLIED (pre-authorized):** Added `"priv"` to the `files:` list in `mix.exs`:

```diff
-      files: ~w(lib/req_managed_agents lib/req_managed_agents.ex examples mix.exs
+      files: ~w(lib/req_managed_agents lib/req_managed_agents.ex examples priv mix.exs
                README.md LICENSE CHANGELOG.md)
```

**Side effect FINDING (release_config_bug):** Adding `"priv"` (not `"priv/runtime_bootstrap"`) also ships the dialyxir PLT/hash files in `priv/plts/`, ballooning the package from ~500KB to 12.7MB. Correct scoped fix is `"priv/runtime_bootstrap"`. This is not pre-authorized to fix; recorded as a finding.

### Step 6.2 — `mix format --check-formatted`

```
$ mix format --check-formatted
(no output)
PASS
```

### Step 6.3 — `mix test`

```
$ mix test
Finished in 16.0 seconds (14.2s async, 1.8s sync)
Result: 308 passed, 11 excluded
PASS
```

### Step 6.4 — `mix credo --strict`

```
$ mix credo --strict
Analysis took 0.1 seconds (0.03s to load, 0.1s running 69 checks on 95 files)
707 mods/funs, found no issues.
PASS
```

### Step 6.5 — `MIX_ENV=dev mix docs --warnings-as-errors`

```
$ MIX_ENV=dev mix docs --warnings-as-errors
Generating docs...
View html docs at "doc/index.html"
PASS (no warnings)
```

### Step 6.6 — `mix dialyzer`

```
$ mix dialyzer
Total errors: 3, Skipped: 2, Unnecessary Skips: 0

lib/req_managed_agents/provisioner/runtimes.ex:48:9:unknown_function
Function EEx.eval_file/2 does not exist.

Exit code: 2
FAIL
```

**FINDING (code_bug — release blocker):** `EEx.eval_file/2` is flagged as `unknown_function` because `:eex` is absent from `plt_add_apps` in `mix.exs`. The function exists at runtime (`:eex` is standard Elixir), but dialyzer's PLT does not include the `:eex` OTP application. The PLT contains: `[:asn1, :aws_event_stream, :compiler, :crypto, :elixir, :ex_aws_auth, :ex_unit, :finch, ...]` — no `:eex`. Fix: add `:eex` to `plt_add_apps`. Not pre-authorized to fix; recorded as a finding.

### Step 6.7 — `mix hex.build` + tarball verification

```
$ mix hex.build
Building req_managed_agents 0.3.0
...
Saved to req_managed_agents-0.3.0.tar
```

**Tarball contents verification:**

Required files present (provisioner):
- `lib/req_managed_agents/provisioner/runtimes.ex` ✓
- `lib/req_managed_agents/provisioner/store.ex` ✓
- `lib/req_managed_agents/provisioner/store/ets.ex` ✓
- `lib/req_managed_agents/provisioner/store/file.ex` ✓
- `lib/req_managed_agents/provisioner/environments.ex` ✓

Required files present (priv/runtime_bootstrap — post-fix):
- `priv/runtime_bootstrap/allowed_hosts.json` ✓
- `priv/runtime_bootstrap/mise_install.sh.eex` ✓

**PASS: both runtime_bootstrap files ship.**

Tarball deleted per procedure.

### Release Gate Summary

| Check | Result |
|-------|--------|
| `mix format --check-formatted` | PASS |
| `mix test` (308/308 passed, 11 excluded) | PASS |
| `mix credo --strict` (no issues) | PASS |
| `MIX_ENV=dev mix docs --warnings-as-errors` | PASS |
| `mix dialyzer` | **FAIL — `:eex` not in PLT** |
| `mix hex.build` + tarball contents | PASS (after `priv` fix) |

**Release gate status: BLOCKED (dialyzer)**

---

## Findings

| # | Classification | Severity | Description |
|---|---------------|----------|-------------|
| F1 | `code_bug` | Release blocker | `mix dialyzer` fails: `EEx.eval_file/2` flagged `unknown_function` because `:eex` is absent from `plt_add_apps` in `mix.exs`. Fix: add `:eex` to the `plt_add_apps` list. |
| F2 | `release_config_bug` | High | `"priv"` glob in `files:` ships 6 dialyxir PLT/hash files (~12MB), ballooning the hex package. Correct fix: use `"priv/runtime_bootstrap"` instead of `"priv"`. |

Executed fix (pre-authorized, not a finding): added `"priv"` to `mix.exs` `files:` to ensure `priv/runtime_bootstrap/` ships in the package.

---

## Overall Result

**QA-CHECKPOINT C: NOT CLEARED — 2 findings, 1 release blocker (F1).**

Scenarios 1–5: all passed (308 tests green, injection protection verified, allowlist matrix correct, bootstrap derived never stored, idempotency confirmed). Release gate blocked by dialyzer `:eex` PLT omission (F1). Package will also ship oversized with PLT blobs after the `"priv"` fix until F2 is addressed.
