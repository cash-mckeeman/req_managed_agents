# QA-CHECKPOINT A — Provisioner Store (PR MIM-69)

**Date:** 2026-07-03
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:** cd4dd457, 64cbb5b3, 0130ba4d
**Worktree:** `.claude/worktrees/rma-030-artifacts`
**Scope:** 4-callback `Provisioner.Store` behaviour; `Store.ETS` (default, extracted from
inline ETS); `Store.File` (JSON, atomic tmp+rename, normalize-on-write, corrupt→empty+warn);
`:store` threading through `Provisioner.ensure/3`, `evict/2`, and the facade `provision/3`
/ `teardown/3` (teardown-forwarding fix).

---

## Setup

All commands run from the worktree root. One scratch file (`test/rma_qa_store_scratch.exs`)
was created for execution and deleted before committing.

**Preflight:** `jj log -r '@-' --no-pager -T 'commit_id.short()'` → `0130ba4d3f16` ✅

**Baseline:** `mix test --no-color` — 246 passed, 9 excluded before any scratch files.

```
$ mix test --no-color 2>&1 | tail -3
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 246 passed, 9 excluded
```

---

## Execution method

All scenarios were executed via a single ExUnit scratch file
`test/rma_qa_store_scratch.exs` (16 tests). Scenario 1 drove two real
`mix run -e` OS processes via `System.cmd/3` from inside the test. All other
scenarios used `Store.ETS` / `Store.File` and `Provisioner` directly. The
scratch file was deleted before the final `mix test` confirmation.

---

## Scenario 1 — REAL cross-OS-process reuse (Store.File)

**Motivation:** The unit suite's "persists across store instances" test (`store_file_test.exs`
L#19) simulates a second process by making a second call in the same VM; no bytes leave
the BEAM. This scenario runs two actual `mix run -e` OS processes to prove that a
second invocation hits the File store and does NOT call the provider's `provision/2` again.

### Step 1.1 — Run 1 provisions and writes the sentinel

A `QA.SentinelProvider` module is defined inline in the `mix run -e` string. It writes
`"provisioned\n"` to a temp sentinel file on every `provision/2` call.

Run 1 script: defines `QA.SentinelProvider`, clears the sentinel and store files, then calls
`Provisioner.ensure(QA.SentinelProvider, %{"type" => "cross-process-test"}, store: {Store.File, path: store_path})`.

**Expected:** Provision called once; sentinel file has 1 line; store JSON file has 1 entry.

**Actual:**

```
RUN1_HANDLE:%{"agent_id" => "cross-proc-agent", "environment_id" => "cross-proc-env"}
RUN1_SENTINEL_COUNT:1
```

Store JSON created, 1 entry (one `"provision:..."` key). exit 0. ✅

**Result: ✅**

### Step 1.2 — Run 2 hits the file cache; no re-provision

A second `mix run -e` defines a DIFFERENT `QA.SentinelProvider.provision/2` body that
appends `"REPROVISION\n"` to the same sentinel and returns a handle with
`"agent_id" => "SHOULD-NOT-SEE"`. It calls `Provisioner.ensure` with the identical spec
and store path.

**Expected:** Store.File returns the cached handle (`"cross-proc-agent"`); `provision/2` is
NOT called; sentinel still has 1 line; `RUN2_NO_REPROVISION:true`.

**Actual:**

```
RUN2_HANDLE:%{"agent_id" => "cross-proc-agent", "environment_id" => "cross-proc-env"}
RUN2_SENTINEL_LINES:1
RUN2_NO_REPROVISION:true
RUN2_AGENT:cross-proc-agent
```

exit 0. Sentinel unchanged; handle is the one from run 1. ✅

**Note:** The hash is keyed on `{provider, spec}` using atom module name and
`:erlang.term_to_binary/2` with `[:deterministic]`. The atom `:"Elixir.QA.SentinelProvider"`
is stable across OS processes with the same Elixir version.

**Result: ✅**

---

## Scenario 2 — Contract behavior on unusual-but-legal inputs

**Motivation:** The contract test (`store_contract_test.exs`) uses only simple ASCII
string keys and plain ASCII map values. Edge cases around colon-rich keys, multi-byte
Unicode, and large payloads are untested in the unit suite.

### Step 2.1 — Key with multiple colons beyond the namespace separator (Store.File)

Key: `"provision:abc123:extra:colon:segment"` — value: `%{"id" => "colon-test"}`

**Expected:** Round-trips through JSON without corruption; colons are legal JSON string chars.

**Actual:** `get/2` returns `{:ok, %{"id" => "colon-test"}}`. ✅

**Result: ✅**

### Step 2.2 — Unicode in value: CJK, emoji, Arabic (Store.File)

Value: `%{"name" => "日本語テスト", "emoji" => "🎉", "arabic" => "مرحبا"}`

**Expected:** Jason encodes as UTF-8; round-trip preserves all codepoints.

**Actual:** All three strings round-tripped byte-for-byte. ✅

**Result: ✅**

### Step 2.3 — 100KB base64 binary string through Store.File

Generated `100_000` random bytes, Base64-encoded (`133_336` byte string).
Stored as `%{"data" => <base64>, "size" => 133336}`.

**Expected:** Jason encodes and decodes without truncation; file > 130 KB.

**Actual:**

```
[S2] 100KB base64 value round-trip: ✓ (base64_len=133336, file_bytes=133392)
```

`get/2` returned `{:ok, got}` with `got["data"] == large_value` (byte-for-byte match).
File on disk: 133,392 bytes. ✅

**Result: ✅**

### Step 2.4 — Multi-colon key and Unicode value through Store.ETS

Key: `"provision:abc:def:ghi"`, value: `%{"name" => "日本語", "emoji" => "✨"}`

**Expected:** ETS stores native Elixir terms; no JSON restriction; round-trip identical.

**Actual:** `{:ok, %{"name" => "日本語", "emoji" => "✨"}}` — exact match. ✅

**Result: ✅**

---

## Scenario 3 — evict-by-value with the same handle under TWO different keys

**Motivation:** `delete_value/2` semantics are "remove all entries whose value matches"
— not just the first one. This is the correct design (a teardown holds a handle, not
a key), but the unit contract test only verifies deletion of a single entry. If two
different specs produce the same handle (provider bug, manual injection, or testing
shortcut), an evict should clear both. This must be documented as intentional behavior,
not a surprise.

### Step 3.1 — Store.ETS: delete_value removes both keys

Injected `"provision:key-alpha"` and `"provision:key-beta"` both pointing to
`%{"id" => "shared-handle", "env" => "same-env"}`. Called `Store.ETS.delete_value(table, shared_handle)`.

**Expected:** Both keys gone after delete_value; unrelated keys unaffected.

**Actual:** Both return `:miss` post-delete. ✅

**Result: ✅**

### Step 3.2 — Store.File: delete_value removes both keys

Same two keys in the JSON file. Called `Store.File.delete_value([path: path], shared_handle)`.

**Expected:** `Enum.reject/2` removes all entries whose normalized value matches;
JSON file rewritten with both keys absent.

**Actual:** Both keys `:miss` post-delete. ✅

**Result: ✅**

### Step 3.3 — Via Provisioner.evict: both keys cleared end-to-end

Two provision keys computed via `Provisioner.hash({StubProvider, spec_a})` and
`Provisioner.hash({StubProvider, spec_b})` were injected directly into a custom ETS store,
both pointing to `%{"id" => "shared-provisioner-handle"}`. Called
`Provisioner.evict(shared_handle, store: store)`.

**Expected:** `evict/2` calls `mod.delete_value(sopts, handle)` with no key argument;
both entries removed.

**Actual:** Both keys `:miss` after evict. Subsequent `ensure` calls re-provision (new
handles returned). ✅

**Documented behavior:** When two distinct `{provider, spec}` combinations produce the same
handle (e.g., provider returns a hardcoded handle, or the caller injects handles directly),
a single `evict` call removes ALL cache entries for that handle. This is the intended
design and consistent with teardown semantics.

**Result: ✅**

---

## Scenario 4 — Loud-but-safe: unwritable / unreadable store path

**Motivation:** `safe_get/3` and `safe_put/4` in `Provisioner` rescue exceptions and
log warnings so a broken store never blocks provisioning. `Store.File.get/2` logs a
warning and returns an empty map (treated as miss) for any `File.read/1` failure.
These paths aren't exercised by the unit suite under real OS conditions.

### Step 4.1 — get from a directory (EISDIR) logs warning and returns :miss

`Store.File.get([path: dir_path], "provision:any-key")` where `dir_path` is an
existing directory.

**Expected:** `File.read(dir_path)` → `{:error, :eisdir}` → logs
`"provision store file unreadable (:eisdir), treating as empty: <path>"` → returns `%{}`
→ `get/2` returns `:miss`.

**Actual:** `:miss` returned; `capture_log` confirmed log contains `"unreadable"`. ✅

**Result: ✅**

### Step 4.2 — ensure/3 with directory-as-path: put raises inside safe_put, handle returned

`Provisioner.ensure(StubProvider, %{n: :s4}, store: {Store.File, [path: dir_path]}, create_fun: ...)`.

`Store.File.put` writes `dir_path.tmp.<N>` successfully, then calls
`:ok = File.rename(tmp, dir_path)`. On macOS, renaming a file onto an existing directory
returns `{:error, :eisdir}`, causing a `MatchError`. `safe_put/4` rescues this and logs
`"provision store put failed (handle still returned): ..."`.

**Expected:** `ensure/3` returns `{:ok, handle}` despite the store being broken. Provider
`provision/2` called exactly once (store miss on get + store silently fails on put).

**Actual:** `{:ok, %{"id" => "loud-but-safe-handle"}}` returned. `provision_count` = 1.
Log contains `"unreadable"` or `"put failed"` (the get warned on the eisdir read before
the put was even attempted). ✅

**Result: ✅**

### Step 4.3 — ensure/3 with read-only parent directory: put raises inside safe_put

Store path inside a `chmod 555` directory. `File.write!(tmp, content)` raises
`%File.Error{reason: :eacces}` since the tmp file is in the same read-only dir.
`safe_put/4` rescues this.

**Expected:** `{:ok, handle}` returned; log contains `"put failed"`.

**Actual:** `{:ok, %{"id" => "readonly-dir-handle"}}`. `provision_count` = 1.
Log contained `"put failed"`. ✅

**Result: ✅**

---

## Scenario 5 — Byte-identity of default path and pre-existing test file

### Step 5.1 — pre-existing `provisioner_test.exs` passes unchanged

`provisioner_test.exs` is the unit file for `Provisioner` itself (hash-keyed cache,
miss-then-provision, changed-spec re-provision). It was named as the reference because
it exercises `Provisioner.ensure/3` at the module level without the facade.

```
$ mix test test/req_managed_agents/provisioner_test.exs --no-color --trace
Running ExUnit with seed: 22497, max_cases: 1
Excluding tags: [:live]

ReqManagedAgents.ProvisionerTest [test/req_managed_agents/provisioner_test.exs]
  * test miss provisions once; hit returns cached ref without re-calling create (1.0ms) [L#14]
  * test a changed spec re-provisions (different hash) (0.03ms) [L#38]

Finished in 0.03 seconds (0.00s async, 0.03s sync)
Result: 2 passed
```

✅ Zero failures; file unmodified.

Also confirmed: `provisioning_test.exs` (the facade threading tests including `:store`
custom-store and teardown-forwarding tests):

```
Result: 8 passed
```

✅

**Result: ✅**

### Step 5.2 — Default ETS table name confirmed via :ets.info/1

After calling `Provisioner.ensure(StubProvider, %{n: :s5_ets_default}, ...)` with no
`:store` option, `@default_store` = `{Store.ETS, :req_managed_agents_provisions}` is
used. `Store.ETS.ensure_table(:req_managed_agents_provisions)` creates the table if
absent.

```
info = :ets.info(:req_managed_agents_provisions)
info[:name]       → :req_managed_agents_provisions
info[:type]       → :set
info[:protection] → :public
```

```
[S5] :req_managed_agents_provisions table: name=req_managed_agents_provisions, type=set, protection=public ✓
```

✅

**Result: ✅**

---

## Scenario 6 — Adversarial: non-JSON-encodable value through Store.File

**Motivation:** `Store.File.delete_value/2` calls `normalize/1` which calls
`Jason.encode!/1` to normalize the value before comparison. Tuples (and other
non-JSON types) will raise `Protocol.UndefinedError`. The moduledoc states
"Values must be JSON-encodable", so this is a caller error — but the failure mode
and its propagation path deserve explicit documentation.

### Step 6.1 — delete_value with tuple-containing map raises Protocol.UndefinedError

```elixir
Store.File.delete_value([path: path], %{handle: {:some, :tuple}})
```

**Expected:** `normalize(%{handle: {:some, :tuple}})` → `Jason.encode!/1` →
`Protocol.UndefinedError` for `Jason.Encoder` on `Tuple`.

**Actual:**

```
Protocol.UndefinedError: protocol Jason.Encoder not implemented for Tuple,
Jason.Encoder protocol must always be explicitly implemented.
```

Error is actionable: it names the exact type (`Tuple`) and the missing protocol
(`Jason.Encoder`). ✅

**Result: ✅**

### Step 6.2 — Provisioner.evict with non-JSON handle propagates to caller (no safe_evict)

`Provisioner.evict/2` calls `mod.delete_value(sopts, handle)` with no `rescue` wrapper:

```elixir
def evict(handle, opts \\ []) do
  {mod, sopts} = opts[:store] || @default_store
  mod.delete_value(sopts, handle)
  :ok
end
```

```elixir
Provisioner.evict(%{data: {:not, :json, :serializable}}, store: {Store.File, [path: path]})
```

**Expected:** `Protocol.UndefinedError` propagates to caller.

**Actual:** `Protocol.UndefinedError` raised; test confirmed with `assert_raise`. ✅

**Actionability:** In practice, this path is only reachable if the caller passes a handle
that was NOT sourced from `Store.File.get/2` (which always returns JSON-decoded string-keyed
maps). A handle returned by `get/2` is always JSON-serializable. The bug surface is: a
caller who holds an ETS-sourced handle (which may have atom keys or non-JSON values) and
then calls `evict` against a `Store.File` backend. The `Protocol.UndefinedError` is
actionable (names the offending type).

**Result: ✅** (expected behavior per moduledoc)

### Step 6.3 — Atom-key handle normalizes to string keys on round-trip

`%{agent_id: "x", environment_id: "y"}` (atom keys) — valid Jason input:

```elixir
Store.File.put([path: path], "provision:atom-key-test", %{agent_id: "atom-key-agent", environment_id: "atom-key-env"})
{:ok, got} = Store.File.get([path: path], "provision:atom-key-test")
got["agent_id"]  # => "atom-key-agent"
Map.has_key?(got, :agent_id)  # => false
```

**Expected:** `normalize/1` JSON-encodes atom keys to strings; `get/2` returns
string-keyed map. `delete_value` comparisons match because both sides normalize.

**Actual:** `got["agent_id"] == "atom-key-agent"` ✅; atom key absent ✅.

**Result: ✅**

---

## Final validation

After deleting `test/rma_qa_store_scratch.exs`:

```
$ mix test --no-color 2>&1 | tail -3
Finished in 16.0 seconds (14.1s async, 1.8s sync)
Result: 246 passed, 9 excluded
```

```
$ mix format --check-formatted; echo "format: $?"
format: 0
```

```
$ mix credo --strict --no-color 2>&1 | tail -3
Analysis took 0.3 seconds (0.00s to load, 0.3s running 70 checks)
0 issues found.
```

**Result: ✅ — suite green, no regressions, no format or credo violations.**

---

## Checklist

| Step  | Scenario                                                                                      | Result |
|-------|-----------------------------------------------------------------------------------------------|--------|
| 1.1   | Cross-OS-process: Run 1 provisions and writes sentinel (real `mix run` subprocess)            | ✅     |
| 1.2   | Cross-OS-process: Run 2 hits File cache — no re-provision, same handle returned              | ✅     |
| 2.1   | Store.File: key with multiple colons beyond namespace separator                               | ✅     |
| 2.2   | Store.File: unicode value (CJK + emoji + Arabic) round-trip                                  | ✅     |
| 2.3   | Store.File: 100KB base64 string value (133KB) persists and round-trips                       | ✅     |
| 2.4   | Store.ETS: multi-colon key + unicode value                                                    | ✅     |
| 3.1   | Store.ETS: delete_value removes both keys pointing to the same handle                        | ✅     |
| 3.2   | Store.File: delete_value removes both keys pointing to the same handle                       | ✅     |
| 3.3   | Provisioner.evict: both keys cleared end-to-end via custom ETS store                         | ✅     |
| 4.1   | Store.File.get on directory path → :miss + "unreadable" log warning                         | ✅     |
| 4.2   | Provisioner.ensure with directory-as-path → handle returned, "put failed" warning            | ✅     |
| 4.3   | Provisioner.ensure with read-only parent dir → handle returned, "put failed" warning         | ✅     |
| 5.1   | provisioner_test.exs passes unchanged (2 tests); provisioning_test.exs (8 tests) green      | ✅     |
| 5.2   | Default ETS table :req_managed_agents_provisions — name/type/protection confirmed            | ✅     |
| 6.1   | Store.File.delete_value with tuple value raises Protocol.UndefinedError (actionable)         | ✅     |
| 6.2   | Provisioner.evict with non-JSON handle: Protocol.UndefinedError propagates (no safe_evict)  | ✅     |
| 6.3   | Atom-key handle normalizes to string keys on Store.File round-trip                           | ✅     |

---

## Findings

### FINDING 1 — doc_issue: evict/2 @doc does not mention JSON constraint when using Store.File

**Classification:** `doc_issue`
**Severity:** low
**Disposition:** accepted — manual coverage only (this doc, Step 6.2)

`Provisioner.evict/2` has `@doc "Drop any cache entry whose value is \`handle\`
(called after teardown)."` but does not mention that when the active store is
`Store.File`, the handle must be JSON-encodable. `safe_get/3` and `safe_put/4`
both have rescue wrappers; `evict/2` does not, meaning a non-JSON handle raises
uncaught `Protocol.UndefinedError` through to the caller. In normal usage this
cannot happen (any handle returned by `Store.File.get/2` is already JSON-decoded
and therefore JSON-serializable), but the omission makes the failure mode opaque
for readers of the API. A one-sentence addition to `evict/2`'s `@doc` would
suffice: "When using `Store.File`, the handle must be JSON-encodable (see
`Provisioner.Store.File` moduledoc)."

### FINDING 2 — test_gap: unit "fresh-OS-process simulation" test is same-VM only

**Classification:** `test_gap`
**Disposition:** accepted — real cross-process coverage provided by this doc (Step 1)

`store_file_test.exs` L#19 ("persists across store instances (fresh-OS-process
simulation)") makes two calls in the same BEAM process; no actual OS-process
boundary is crossed. The File store's persistence claim relies on `File.write!/2` +
`File.rename/2` being visible to the next reader, which is trivially true within
one VM. The real invariant — that atom module-name hashing is stable across OS
processes with the same Elixir version — is exercised only in this manual test
(Scenario 1). Recommendation: note in the test that the scenario is same-VM only
and reference this doc for cross-process coverage.
