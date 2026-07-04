# QA-CHECKPOINT B — Environment Images (PR MIM-70)

**Date:** 2026-07-03
**Tester:** QA-tester subagent (automated manual execution)
**Commits under test:** 80a639be, 9190715b, 29cba367 (on top of main 9c9d95b7)
**Worktree:** `.claude/worktrees/rma-030-artifacts`
**Scope:** Environments as content-addressed images — `Provisioner.ensure_environment/3`
(name `<base>_<digest8>`, build-if-absent, pure cache hit, 409 recover-by-exact-name,
archived → error, malformed store entry → rebuild); `tag/4` + `resolve/2` (registry
`"tags:" <> base`, base-scoped digest index, never-falls-back errors, ArgumentError on
colon-free ref); `prune_environments/3` (`keep:` required, newest-N + tagged protected,
strict 8-hex membership, oldest-first archival, partial-failure shape, dual-shape
delete_value + base-scoped index cleanup). All client interaction via injected
`create_fun`/`list_fun`/`archive_fun` — no live credentials used.

---

## Setup

All commands run from the worktree root. One scratch file
(`test/rma_qa_env_images_scratch.exs`, 22 tests) was created for execution and deleted
before committing. Store.File scenarios used per-test temp JSON files under
`System.tmp_dir!()`, removed via `on_exit`.

**Preflight:** `jj log -r '@-' --no-pager -T 'commit_id.short()'` → `29cba367d0d5` ✅

**Baseline:** `mix test --no-color` before scratch file existed:

```
Finished in 16.0 seconds (14.2s async, 1.8s sync)
Result: 263 passed, 9 excluded
```

## Execution method

All scenarios executed via a single ExUnit scratch file run with
`mix test test/rma_qa_env_images_scratch.exs --no-color --trace`. Every scripted client
fn (`create_fun` / `list_fun` / `archive_fun`) either counts calls in a public ETS
sentinel table, sends messages to the test pid, or `flunk`s outright when it must not be
called — so "no create on cache hit" is proven, not assumed. Evidence lines below are
pasted verbatim from the run output (`[S<n>.<m>]` prefixes).

---

## Scenario 1 — Full image story over Store.File (release narrative)

**Motivation:** The unit suite covers each verb against fresh ETS stores. This scenario
runs the whole lifecycle against ONE persistent Store.File JSON file: build → cache hit →
tag → retag → resolve → prune keep:1 → resolve post-prune, with call-counting sentinels.

### Step 1.1 — First ensure builds (create called exactly once, list never)

`create_fun` increments an ETS counter and messages the test pid; `list_fun` is
`fn -> flunk(...) end`.

**Expected:** `{:ok, %{environment_id, name: "svc_" <> digest8, digest}}`; create count 1;
store file has exactly 2 keys (`provision:env:<hash>` + `digest:svc:<digest>`).

**Actual:**

```
[S1.1] First ensure → build
[S1.1] create calls=1, name=svc_5284a998, digest=5284a998
[S1.1] store has 2 keys after first ensure ✓
```

Name is `base <> "_" <> digest8`, digest matches `^[0-9a-f]{8}$`, `assert_received
{:created, "svc_5284a998"}` passed. **Result: ✅**

### Step 1.2 — Second ensure is a PURE cache hit (no create, no list — sentinel-proven)

Both `create_fun` and `list_fun` are `flunk/1` closures on the second call; the ETS
counter from step 1.1 is re-read.

**Expected:** Same handle (`environment_id`, `name`, `digest` all pin-matched); counter
still 1.

**Actual:**

```
[S1.2] Second ensure → must be a pure cache hit (no create, no list)
[S1.2] create count still=1 (no second call) ✓
```

**Result: ✅**

### Step 1.3 — tag "prod" → retag → resolve → prune keep:1 → resolve post-prune

Three images ensured against one Store.File (`spec1`/`spec2`/`spec3` → h1/h2/h3, all
distinct names). Tag `prod` → h1, resolve; retag `prod` → h2, resolve. Then prune with
`keep: 1` over a fake `list_fun` where h3 is newest, h2 middle (tagged), h1 oldest.

**Expected:** keep h3 (newest-1) + h2 (tagged); archive h1 only. `svc:prod` resolves to
h2 after prune. A stale tag pointed at pruned h1's digest resolves to
`{:error, {:untracked_digest, h1.digest}}` (digest index deleted by prune).

**Actual:**

```
[S1.3] h1=svc_5284a998, h2=svc_576fc270, h3=svc_62ae7569
[S1.3] tagged prod→h1, resolve: id_svc_5284a998 ✓
[S1.3] retagged prod→h2, resolve: id_svc_576fc270 ✓
[S1.3] prune result: archived=["svc_5284a998"], kept=["svc_62ae7569", "svc_576fc270"]
[S1.3] resolve svc:prod post-prune: id_svc_576fc270 ✓
[S1.3] resolve pruned digest → :untracked_digest ✓
```

`assert_received {:archived, "id_svc_5284a998"}` passed; the tagged old image (h2)
survived the prune; the tagged digest stays resolvable. **Result: ✅**

---

## Scenario 2 — Cross-store handle shapes

**Motivation:** ETS stores handles as-written (atom keys); Store.File JSON-normalizes to
string keys. A handle produced under one store and consumed under the other must not
surface a shape mismatch to callers.

### Step 2.1 — ensure via ETS → seed JSON-normalized handle into Store.File → resolve

The atom-keyed handle from an ETS-backed `ensure_environment` was round-tripped through
`Jason.encode!/decode!` (exactly what Store.File's `normalize/1` does) and seeded into a
Store.File under `digest:app:<digest>` plus a `tags:app` registry.

**Expected:** `resolve("app:stable")` returns an ATOM-keyed handle with the same
`environment_id` (via `atomize_handle/1`).

**Actual:**

```
[S2.1] ETS handle: %{name: "app_5284a998", digest: "5284a998", environment_id: "id_app_5284a998"}
[S2.1] JSON-normalized: %{"digest" => "5284a998", "environment_id" => "id_app_5284a998", "name" => "app_5284a998"}
[S2.1] resolve from File store (seeded from ETS handle): id_app_5284a998 ✓
```

`Map.has_key?(resolved, :environment_id)` — atom keys confirmed. **Result: ✅**

### Step 2.2 — ensure via Store.File → seed string-keyed handle into ETS → resolve

Reverse direction: `ensure_environment` against Store.File returns an atom-keyed handle
even though the file stores string keys (proving `normalize_or_miss/1` re-atomizes on the
read path — the ensure itself IS the cross-shape test here). The string-keyed variant was
then seeded into an ETS store and resolved.

**Actual:**

```
[S2.2] File handle (atom-keyed after normalize_or_miss): %{name: "app_576fc270", digest: "576fc270", environment_id: "id_app_576fc270"}
[S2.2] resolve from ETS store (string-keyed handle): id_app_576fc270 ✓
```

Both directions produce one caller-facing shape (atom keys, three fields). No shape
mismatch surfaces. **Result: ✅**

---

## Scenario 3 — Empty-store recovery (409 paths)

**Motivation:** A fresh machine (empty store) racing an existing provider-side image hits
409 on create. The digest-name makes recovery-by-exact-name version-correct; the three
sub-cases must each surface distinctly.

### Step 3.1 — 409 + live exact-name match → recovered handle

`create_fun` records the attempted name then returns
`{:error, {:http_error, 409, %{"error" => "AlreadyExists"}}}`; `list_fun` returns that
exact name live (`"archived_at" => nil`).

**Actual:**

```
[S3.1] 409 + live match → {:ok, recovered} ✓
```

`{:ok, %{environment_id: "env_recovered_live"}}` returned. **Result: ✅**

### Step 3.2 — 409 + archived-only match → `{:error, {:environment_archived, name}}`

Same setup, but `list_fun` returns the name with `"archived_at" => "2026-01-15T00:00:00Z"`.

**Actual:**

```
[S3.2] 409 + archived-only → {:error, {:environment_archived, name}} ✓
```

**Result: ✅**

### Step 3.3 — 409 + no name match at all → `{:error, {:environment_name_conflict, name}}`

`list_fun` returns only an unrelated live env (`"completely_different_deadbeef"`).

**Actual:**

```
[S3.3] 409 + no match → {:error, {:environment_name_conflict, name}} ✓
```

**Result: ✅**

---

## Scenario 4 — Prune adversarial matrix

### Step 4.1 — keep missing / keep: 0 / keep: -1 → `{:error, :keep_required}`

All three variants (option absent, `keep: 0`, `keep: -1`) against an empty list_fun.

**Actual:**

```
[S4.1] keep missing/0/-1 → {:error, :keep_required} ✓
```

The guard is `is_integer(keep) and keep > 0`, so 0 and negatives are rejected, not
treated as "archive everything". **Result: ✅**

### Step 4.2 — base with underscores: prune "my_base" must not touch "my_base_extra_abcd1234"

Envs: `my_base_aaaaaaaa` (oldest), `my_base_bbbbbbbb`, and `my_base_extra_abcd1234`
(newest, belongs to base `my_base_extra`). Prune `"my_base"` with `keep: 1`.

**Expected:** strict membership — after stripping `"my_base_"`, the suffix
`"extra_abcd1234"` fails `^[0-9a-f]{8}$`, so the foreign-base env is neither kept nor
archived.

**Actual:**

```
[S4.2] my_base prune: archived=["my_base_aaaaaaaa"], kept=["my_base_bbbbbbbb"]
[S4.2] my_base_extra_abcd1234 untouched ✓
```

`refute_received {:archived, "id_my_base_extra_abcd1234"}` passed. **Result: ✅**

### Step 4.3 — foreign-base isolation: prune "a" leaves "b_*" untouched

Envs across two bases (`a_*` older, `b_*` newer). Prune `"a"` keep:1.

**Actual:**

```
[S4.3] foreign-base isolation: archived=["a_aaaaaaaa"], kept=["a_bbbbbbbb"]
[S4.3] b_* entirely untouched ✓
```

`b_*` names appear in neither `archived` nor `kept`; no archive calls received for
them. **Result: ✅**

### Step 4.4 — partial failure mid-sequence: progress accurate, failed env's store entries untouched

Three envs `d_11111111 < d_22222222 < d_33333333`; keep:1 keeps the newest, so archival
(oldest-first) hits `d_11111111` then `d_22222222`. `archive_fun` succeeds for the first
and returns `{:error, {:http_error, 503, %{}}}` for the second. The store was pre-seeded
with `digest:d:11111111` and `digest:d:22222222` index entries.

**Expected:** `{:error, {:partial, ["d_11111111"], {"d_22222222", {:http_error, 503, %{}}}}}`;
the SUCCEEDED env's index entry deleted; the FAILED env's index entry intact.

**Actual:**

```
[S4.4] partial failure: d_11111111 archived+store-deleted; d_22222222 store intact ✓
```

`smod.get(sopts, "digest:d:11111111")` → `:miss`; `smod.get(sopts, "digest:d:22222222")`
→ `{:ok, <original handle>}`. Exact partial tuple pattern asserted. **Result: ✅**

### Step 4.5 — ALL versions tagged → nothing archived

Three envs, all three digests tagged (`v1`/`v2`/`v3`). Prune keep:1.

**Actual:**

```
[S4.5] all tagged: archived=[], kept=["svc4_cccccccc", "svc4_bbbbbbbb", "svc4_aaaaaaaa"]
```

`archived == []`, all three kept, zero archive-fn invocations (`refute_received`).
**Result: ✅**

---

## Scenario 5 — resolve edge matrix

### Step 5.1 — unknown base → `{:error, :unknown_tag}`

`resolve("nobase:tag")` against a fresh empty store (registry `:miss`).

```
[S5.1] unknown base → {:error, :unknown_tag} ✓
```

**Result: ✅**

### Step 5.2 — known base, unknown tag → `{:error, :unknown_tag}`

Registry exists (`known:t1` tagged) but `t2` requested.

```
[S5.2] known base, unknown tag → {:error, :unknown_tag} ✓
```

**Result: ✅**

### Step 5.3 — tag → digest whose index entry was deleted → `{:untracked_digest, digest}` carries the RIGHT digest

Ensure + tag, then `smod.delete(sopts, "digest:svc5c:" <> handle.digest)` directly.

```
[S5.3] resolve after index deletion: {:error, {:untracked_digest, "5284a998"}}
[S5.3] untracked_digest carries correct digest 5284a998 ✓
```

`digest == handle.digest` asserted — the error payload names the exact digest the tag
points at, enabling "re-ensure the spec to heal". **Result: ✅**

### Step 5.4 — colon-free ref → ArgumentError

```
[S5.4] colon-free ref raises ArgumentError ✓
```

`assert_raise ArgumentError, ~r/base:tag/` — message names the required form.
**Result: ✅**

### Step 5.5 — ref with MULTIPLE colons: `"a:b:c"` → base `"a"`, tag `"b:c"` (documented actual behavior)

Seeded registry `"tags:a"` with tag key `"b:c" => "deadbeef"` and a matching
`digest:a:deadbeef` index entry, then resolved `"a:b:c"`.

**Actual:**

```
[S5.5] resolve('a:b:c'): {:ok, %{name: "a_deadbeef", digest: "deadbeef", environment_id: "env_multi_colon"}}
[S5.5] 'a:b:c' → base='a', tag='b:c' — resolves successfully (parts: 2 split) ✓
```

**Documented behavior:** `String.split(ref, ":", parts: 2)` treats only the FIRST colon
as the base/tag separator; any further colons are part of the tag name. So `"a:b:c"`
resolves tag `"b:c"` under base `"a"`. This is consistent (tag/4 places whatever tag
string it's given into the registry map), but the `resolve/2` @doc only says "must be of
the form \"base:tag\"" without stating first-colon semantics — see FINDING 2
(doc_issue, low). **Result: ✅**

---

## Scenario 6 — Adversarial store content

### Step 6.1 — corrupt Store.File JSON mid-lifecycle

Full ensure + tag + verified resolve, then the store file was overwritten with
`"THIS IS NOT JSON {corrupted"`.

**Expected:** resolve degrades to `{:error, :unknown_tag}` (corrupt file reads as empty
map → registry miss), logs the corrupt warning, no crash. A subsequent `tag/4` rewrites
a valid file.

**Actual:**

```
[S6.1] resolve OK before corruption ✓
[S6.1] resolve after file corruption: {:error, :unknown_tag}
[S6.1] resolve returns :unknown_tag on corrupt file (no crash); log warns 'corrupt' ✓
[S6.1] tag() after corruption re-creates valid file ✓
```

`capture_log` contains `"corrupt"`; post-corruption `tag/4` produced a valid JSON file
containing `"tags:svc6a"`. **Important caveat:** the tag registry does NOT survive file
corruption — the whole flat file is the blast radius (one JSON object). That is the
documented Store.File contract ("missing or corrupt file is treated as empty"); the
provider-side images remain recoverable via re-ensure (409 → recover-by-name), so no
data is lost that cannot be re-derived. **Result: ✅** (behavior matches contract)

### Step 6.2 — registry entry manually set to a non-map value → resolve returns :unknown_tag (no raise)

`smod.put(sopts, "tags:svc6b", "not_a_map_at_all")` then `resolve("svc6b:any")`.

**Actual:**

```
[S6.2] resolve with non-map registry: {:error, :unknown_tag}
[S6.2] non-map registry → :unknown_tag (no raise, no crash) ✓
```

The `with`/`else` catch-all (`_ -> {:error, :unknown_tag}`) absorbs the corrupt
registry. Note this is silent (no Logger warning), unlike the malformed provision-entry
path which warns — acceptable for a read path. **Result: ✅**

### Step 6.3 — string-keyed partial provision entry → miss + rebuild (unit parity)

`%{"environment_id" => "old_id"}` (missing `"name"`/`"digest"`) seeded under the exact
provision key, then ensure with a fresh `create_fun`.

**Actual:**

```
[S6.3] string-keyed partial entry → 'unexpected shape' warning; rebuilt ✓
```

Log contains `"unexpected shape"`; rebuilt handle has all three fields, digest 8-hex.
**Result: ✅**

### Step 6.3b — atom-keyed PARTIAL provision entry passes through normalize_or_miss — ❌ code_bug

Adversarial variant of 6.3: `%{environment_id: "partial_id", name: "partial_name"}`
(atom keys, MISSING `:digest`) seeded under the exact provision key. `create_fun` is a
`flunk/1` sentinel.

**Expected (per module intent):** "Anything else (foreign store content, missing keys)
is treated as a miss and rebuilt" — the entry should be logged + rebuilt like 6.3.

**Actual:**

```
[S6.3b] actual result from partial atom-keyed handle: {:ok, %{name: "partial_name", environment_id: "partial_id"}}
[S6.3b] BUG CONFIRMED: atom-key partial handle (missing :digest) returns from ensure without rebuild
```

`create_fun` was never called; `ensure_environment/3` returned the two-field partial
handle to the caller. Root cause: `normalize_or_miss/1` clause 1
(`lib/req_managed_agents/provisioner/environments.ex:247`) is

```elixir
defp normalize_or_miss(%{environment_id: _} = h), do: {:ok, h}
```

— it pattern-matches ANY map carrying `:environment_id`, while the string-key clause
(line 249) correctly requires all three fields. A caller doing `handle.digest` or
`Provisioner.tag(base, tag, handle)` (whose `to_digest/1` matches `%{digest: d}`) then
crashes with `KeyError`/`FunctionClauseError` far from the corrupt-store root cause —
exactly what the "loud-but-safe / rebuilt" comment promises to prevent. See FINDING 1
(code_bug). **Result: ❌ code_bug**

### Step 6.4 — integer as provision entry → miss + rebuild

`smod.put(sopts, key, 42)` then ensure.

```
[S6.4] integer provision entry → miss + rebuild ✓
```

Non-map values hit the catch-all correctly. **Result: ✅**

---

## Final validation

After deleting `test/rma_qa_env_images_scratch.exs`:

```
$ mix test --no-color 2>&1 | tail -3
Finished in 16.0 seconds (14.2s async, 1.8s sync)

Result: 263 passed, 9 excluded
```

```
$ mix format --check-formatted; echo "format: $?"
format: 0
```

```
$ mix credo --strict --no-color 2>&1 | grep issues
669 mods/funs, found no issues.
```

**Result: ✅ — suite green (263), no format or credo violations, scratch file deleted.**

---

## Checklist

| Step  | Scenario                                                                                   | Result |
|-------|--------------------------------------------------------------------------------------------|--------|
| 1.1   | Store.File: first ensure builds — create called once, list never, 2 store keys            | ✅     |
| 1.2   | Store.File: second ensure is a pure cache hit — sentinel proves zero create/list calls    | ✅     |
| 1.3   | tag → retag → resolve → prune keep:1 (tagged old survives) → resolve post-prune           | ✅     |
| 2.1   | ETS handle JSON-normalized into Store.File → resolve returns atom-keyed handle            | ✅     |
| 2.2   | Store.File handle string-keyed into ETS → resolve returns atom-keyed handle               | ✅     |
| 3.1   | 409 + live exact-name match → recovered handle                                            | ✅     |
| 3.2   | 409 + archived-only match → {:error, {:environment_archived, name}}                       | ✅     |
| 3.3   | 409 + no name match → {:error, {:environment_name_conflict, name}}                        | ✅     |
| 4.1   | keep missing / 0 / -1 → {:error, :keep_required}                                          | ✅     |
| 4.2   | prune "my_base" never touches "my_base_extra_abcd1234" (strict 8-hex membership)         | ✅     |
| 4.3   | foreign-base isolation: prune "a" leaves "b_*" untouched                                  | ✅     |
| 4.4   | partial failure: progress accurate; failed env's store index entry untouched              | ✅     |
| 4.5   | all versions tagged → nothing archived                                                     | ✅     |
| 5.1   | unknown base → :unknown_tag                                                                | ✅     |
| 5.2   | known base, unknown tag → :unknown_tag                                                     | ✅     |
| 5.3   | deleted index entry → {:untracked_digest, <correct digest>}                                | ✅     |
| 5.4   | colon-free ref → ArgumentError                                                             | ✅     |
| 5.5   | "a:b:c" → base "a", tag "b:c" (first-colon split; documented)                             | ✅     |
| 6.1   | corrupt Store.File JSON: resolve → :unknown_tag, no crash; tag rewrites valid file        | ✅     |
| 6.2   | non-map registry value → :unknown_tag (no raise)                                          | ✅     |
| 6.3   | string-keyed partial provision entry → warned + rebuilt                                    | ✅     |
| 6.3b  | atom-keyed partial provision entry (missing :digest) passes through — NOT rebuilt         | ❌     |
| 6.4   | integer provision entry → miss + rebuild                                                   | ✅     |

22 steps executed: 21 ✅ / 1 ❌.

---

## Findings

### FINDING 1 — code_bug: `normalize_or_miss/1` atom-key clause over-matches partial handles

**Classification:** `code_bug`
**Severity:** medium
**Location:** `lib/req_managed_agents/provisioner/environments.ex:247`
**Evidence:** Step 6.3b

```elixir
defp normalize_or_miss(%{environment_id: _} = h), do: {:ok, h}
```

matches ANY map with an `:environment_id` atom key — including partial handles missing
`:name`/`:digest` — and returns it verbatim from `ensure_environment/3`. The string-key
clause on line 249 correctly demands all three fields. The moduledoc-adjacent comment
("Anything else (foreign store content, missing keys) is treated as a miss and rebuilt")
promises the opposite. Downstream, `handle.digest` raises `KeyError` and
`tag(base, t, handle)` raises `FunctionClauseError` in `to_digest/1`, far from the
corrupt-store root cause. Reachable via any ETS-store writer that seeds/mutates
provision entries (foreign code sharing the default named table, or a future refactor).
**Fix (one line):** `defp normalize_or_miss(%{environment_id: _, name: _, digest: _} = h), do: {:ok, h}`.
The existing unit test ("malformed store entry is treated as a miss") only covers the
string-keyed shape — add an atom-keyed partial case alongside the fix.

### FINDING 2 — doc_issue: `resolve/2` @doc silent on multi-colon ref semantics

**Classification:** `doc_issue`
**Severity:** low
**Evidence:** Step 5.5

`resolve/2`'s @doc says the ref "must be of the form \"base:tag\"" and documents the
ArgumentError for a colon-free ref, but not that the split is `parts: 2` — first colon
separates, the remainder (colons included) is the tag. `"a:b:c"` silently resolves tag
`"b:c"` under base `"a"`. Harmless and internally consistent with `tag/4`, but one
sentence ("only the first colon separates base from tag; tags may contain colons")
would remove the ambiguity.

### FINDING 3 — test_gap: no unit coverage for keep: 0 / negative keep

**Classification:** `test_gap`
**Severity:** low
**Evidence:** Step 4.1

`environments_test.exs` asserts `:keep_required` only for the OMITTED option. The
`keep: 0` and negative-keep rejections (guard `is_integer(keep) and keep > 0`) are
untested in the unit suite — the difference between "keep is required" and "keep must be
positive" is exactly where a future guard refactor could regress into
"keep: 0 archives everything". Covered manually here; recommend two one-line unit cases.

### FINDING 4 — test_gap: no unit coverage that prune leaves the FAILED env's store entries intact on partial failure

**Classification:** `test_gap`
**Severity:** low
**Evidence:** Step 4.4

The unit partial-failure test asserts the return tuple shape only. The store-side
invariant — succeeded envs' `digest:<base>:<digest>` index entries deleted, failed env's
entries untouched (so a later resolve/retry still works) — is only verified in this
manual doc. Recommend extending the existing unit test with two `store.get` assertions.
