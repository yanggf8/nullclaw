# AGENTS.md — nullclaw Agent Engineering Protocol

This file defines the default working protocol for coding agents in this repository.
Scope: entire repository.

## 1) Project Snapshot (Read First)

nullclaw is a Zig-first autonomous AI assistant runtime optimized for:

- minimal binary size (target: < 1 MB ReleaseSmall)
- minimal memory footprint (target: < 5 MB peak RSS)
- zero dependencies beyond libc and optional SQLite
- full feature parity with ZeroClaw (Rust reference implementation)

Core architecture is **vtable-driven** and modular. All extension work is done by implementing
vtable structs and registering them in factory functions.

Key extension points:

- `src/providers/root.zig` (`Provider`) — AI model providers
- `src/channels/root.zig` (`Channel`) — messaging channels
- `src/tools/root.zig` (`Tool`) — tool execution surface
- `src/memory/root.zig` (`Memory`) — memory backends
- `src/observability.zig` (`Observer`) — observability hooks
- `src/runtime.zig` (`RuntimeAdapter`) — execution environments
- `src/peripherals.zig` (`Peripheral`) — hardware boards (Arduino, STM32, RPi)

Current scale: **245 source files, ~204K lines of code, 5,640+ tests**.

Build and test:

```bash
zig build                           # dev build
zig build -Doptimize=ReleaseSmall  # release build
zig build test --summary all        # run all tests
```

## 2) Deep Architecture Observations (Why This Protocol Exists)

These codebase realities should drive every design decision:

1. **Vtable + factory architecture is the stability backbone**
   - Extension points are explicit and swappable via `ptr: *anyopaque` + `vtable: *const VTable`.
   - Callers must OWN the implementing struct (local var or heap-alloc). Never return a vtable interface pointing to a temporary — the pointer will dangle.
   - Most features should be added via vtable implementation + factory registration, not cross-cutting rewrites.

2. **Binary size and memory are hard product constraints**
   - `zig build -Doptimize=ReleaseSmall` is the release target. Every dependency and abstraction has a size cost.
   - Avoid adding libc calls, runtime allocations, or large data tables without justification.
   - `MaxRSS` during `zig build test` must stay well under 50 MB.

3. **Security-critical surfaces are first-class**
   - `src/gateway.zig`, `src/security/`, `src/tools/`, `src/runtime.zig` carry high blast radius.
   - Defaults are secure-by-default (pairing, HTTPS-only, allowlists, AEAD encryption). Keep it that way.

4. **Zig 0.15.2 API is the baseline — no newer features**
   - HTTP client: `std.http.Client.fetch()` with `std.Io.Writer.Allocating` for response body capture.
   - Child processes: `std.process.Child.init(argv, allocator)`, `.Pipe` (capitalized).
   - stdout: `std.fs.File.stdout().writer(&buf)` → use `.interface` for `print`/`flush`.
   - `std.io.getStdOut()` does NOT exist in 0.15 — use `std.fs.File.stdout()`.
   - SQLite: linked via `/opt/homebrew/opt/sqlite/{lib,include}` on the compile step, not the module.
   - `ArrayListUnmanaged`: init with `.empty`, pass allocator to every method.

5. **All 5,640+ tests must pass at zero leaks**
   - The test suite uses `std.testing.allocator` (leak-detecting GPA). Every allocation must be freed.
   - `Config.load()` allocates — always wrap in `std.heap.ArenaAllocator` in tests and production.
   - `ChaCha20Poly1305.decrypt` segfaults on tag failure with heap-allocated output on macOS/Zig 0.15 — use a stack buffer then `allocator.dupe()`.

## 3) Engineering Principles (Normative)

These principles are mandatory. They are implementation constraints, not suggestions.

### 3.1 KISS

Required:
- Prefer straightforward control flow over meta-programming.
- Prefer explicit comptime branches and typed structs over hidden dynamic behavior.
- Keep error paths obvious and localized.

### 3.2 YAGNI

Required:
- Do not add config keys, vtable methods, or feature flags without a concrete caller.
- Do not introduce speculative abstractions.
- Keep unsupported paths explicit (`return error.NotSupported`) rather than silent no-ops.

### 3.3 DRY + Rule of Three

Required:
- Duplicate small local logic when it preserves clarity.
- Extract shared helpers only after repeated, stable patterns (rule-of-three).
- When extracting, preserve module boundaries and avoid hidden coupling.

### 3.4 Fail Fast + Explicit Errors

Required:
- Prefer explicit errors for unsupported or unsafe states.
- Never silently broaden permissions or capabilities.
- In tests: `builtin.is_test` guards are acceptable to skip side effects (e.g., spawning browsers), but the guard must be explicit and documented.

### 3.5 Secure by Default + Least Privilege

Required:
- Deny-by-default for access and exposure boundaries.
- Never log secrets, raw tokens, or sensitive payloads.
- All outbound URLs must be HTTPS. HTTP is rejected at the tool layer.
- Keep network/filesystem/shell scope as narrow as possible.

### 3.6 Determinism + No Flaky Tests

Required:
- Tests must not spawn real network connections, open browsers, or depend on system state.
- Use `builtin.is_test` to bypass side effects (spawning, opening URLs, real hardware I/O).
- Tests must be reproducible across macOS and Linux.

## 4) Repository Map (High-Level)

```
src/
  main.zig              CLI entrypoint and command routing
  root.zig              module exports (lib root)
  agent.zig             orchestration loop
  config.zig            schema + config loading/merging (~/.nullclaw/config.json)
  gateway.zig           webhook/HTTP gateway server
  onboard.zig           interactive setup wizard
  health.zig            component health registry
  runtime.zig           runtime adapters (native, docker, wasm, cloudflare)
  tunnel.zig            tunnel providers (cloudflared, ngrok, tailscale, custom)
  skillforge.zig        skill discovery and integration
  migration.zig         memory migration from other backends
  hardware.zig          hardware discovery and management
  peripherals.zig       hardware peripherals (Arduino, STM32/Nucleo, RPi)
  security/             policy, pairing, secrets, sandbox backends
  memory/               SQLite + markdown backends, embeddings, vector search
  providers/            50+ AI provider implementations (9 core + 41 compatible services)
  channels/             17 channel implementations
  tools/                30+ tool implementations
  agent/                agent loop, context, planner
```

## 5) Risk Tiers by Path (Review Depth Contract)

- **Low risk**: docs, comments, test additions, minor formatting
- **Medium risk**: most `src/**` behavior changes without boundary/security impact
- **High risk**: `src/security/**`, `src/gateway.zig`, `src/tools/**`, `src/runtime.zig`, config schema, vtable interfaces

When uncertain, classify as higher risk.

## 6) Agent Workflow (Required)

1. **Read before write** — inspect existing module, vtable wiring, and adjacent tests before editing.
2. **Define scope boundary** — one concern per change; avoid mixed feature+refactor+infra patches.
3. **Implement minimal patch** — apply KISS/YAGNI/DRY rule-of-three explicitly.
4. **Validate** — `zig build test --summary all` must show 0 failures and 0 leaks.
5. **Document impact** — update comments/docs for behavior changes, risk, and side effects.

### 6.1 Code Naming Contract (Required)

Apply these naming rules consistently:

- Functions and methods: `camelCase` (e.g., `parseCommand`, `buildSimpleRequestBody`, `healthCheck`). This follows standard Zig convention.
- Variables, fields, modules, files: `snake_case` (e.g., `workspace_dir`, `bot_user_id`, `config_parse.zig`).
- Types, structs, enums, unions: `PascalCase` (e.g., `AnthropicProvider`, `BrowserTool`, `CommandRiskLevel`).
- Value constants (numeric limits, URLs, timeouts): `SCREAMING_SNAKE_CASE` (e.g., `MAX_BODY_SIZE`, `DEFAULT_BASE_URL`, `KEY_LEN`).
- Comptime array/table constants: `snake_case` (e.g., `high_risk_commands`, `compat_providers`, `default_allowed_commands`).
- Vtable implementer naming: `<Name>Provider`, `<Name>Channel`, `<Name>Tool`, `<Name>Memory`, `<Name>Sandbox`.
- Vtable function-pointer fields: `camelCase` for new vtables (e.g., `chatWithSystem`, `supportsNativeTools`, `getName`). Note: some older vtable fields use `snake_case` (`supports_streaming`, `record_event`); prefer `camelCase` for new additions and consolidate over time.
- Factory registration keys: stable, lowercase, user-facing (e.g., `"openai"`, `"telegram"`, `"shell"`). Use hyphens for multi-word keys (e.g., `"together-ai"`, `"aws-bedrock"`).
- Tests: named with space-separated descriptive phrases as the test block string (e.g., `"command risk low for read commands"`, `"pushover execute missing message"`). Prefix with the subject or subsystem when helpful. Fixtures use neutral names.

### 6.2 Architecture Boundary Contract (Required)

- Extend capabilities by adding vtable implementations + factory wiring first.
- Keep dependency direction inward to contracts: concrete implementations depend on vtable/config/util, not on each other.
- Avoid cross-subsystem coupling (provider code importing channel internals, tool code mutating gateway policy).
- Keep module responsibilities single-purpose: orchestration in `agent/`, transport in `channels/`, model I/O in `providers/`, policy in `security/`, execution in `tools/`.

## 7) Change Playbooks

### 7.1 Adding a Provider

- Add `src/providers/<name>.zig` implementing `Provider.VTable` (`chatWithSystem`, `chat`, `supportsNativeTools`, `getName`, `deinit`).
- Register in `src/providers/root.zig` factory.
- `chatImpl` must extract system/user from `request.messages` (see existing providers for pattern).
- Add tests for vtable wiring, error paths, and config parsing.

### 7.2 Adding a Channel

- Add `src/channels/<name>.zig` implementing `Channel.VTable`.
- Keep `send`, `listen`, `name`, `isConfigured` semantics consistent with existing channels.
- Cover auth/config/health behavior with tests.

### 7.3 Adding a Tool

- Add `src/tools/<name>.zig` implementing `Tool.VTable` (`execute`, `name`, `description`, `parameters_json`).
- Validate and sanitize all inputs. Return `ToolResult`; never panic in the runtime path.
- Add `builtin.is_test` guard if the tool spawns processes or opens network connections.
- Register in `src/tools/root.zig`.

### 7.4 Adding a Peripheral

- Implement the `Peripheral` interface in `src/peripherals.zig`.
- Peripherals expose `read`/`write` methods that delegate to real hardware I/O.
- Use `probe-rs` CLI for STM32/Nucleo flash access; serial JSON protocol for Arduino.
- Non-Linux platforms must return `error.UnsupportedOperation` (not silent 0).

### 7.5 Security / Runtime / Gateway Changes

- Include threat/risk notes in the commit or PR.
- Add/update tests for failure modes and boundaries.
- Keep observability useful but non-sensitive (no secrets in logs or errors).

### 7.6 Cron Job Authoring and Skill Delivery

#### Job types

| `job_type` | Execution | Delivery |
|------------|-----------|----------|
| `shell`    | subprocess via `sh -c <command>` | script self-delivers via `--deliver-to`; set `delivery_mode: none` |
| `agent`    | inline agent loop | cron delivers stdout; set `delivery_mode: always` + `delivery_channel` + `delivery_to` |
| `skill`    | `resolveSkillExec` → `python3 <script> [args]` subprocess | script self-delivers; gateway injects `NULLCLAW_JOB_ID` env var |

#### First-class `skill` job type

Set `job_type: "skill"`, `skill_name: "<name>"`, and optionally `skill_args: "<args>"`. The gateway calls `resolveSkillExec()` (or the testable `resolveSkillExecFrom()`) in `src/cron.zig` to read `## Script` from `~/.claude/skills/<name>/SKILL.md`, expand `~/`, and build `python3 <path> [args]`. The subprocess receives `NULLCLAW_JOB_ID=<job-instance-id>` as an environment variable so scripts can embed the job ID in their output for tracking.

Both execution paths (DB-direct via `DbCronBackend` and legacy via `CronScheduler`) support skill jobs. The `vtableAdd` in `src/cron/db.zig` heap-dupes all delivery fields (`channel`, `account_id`, `to`, `best_effort`) for ownership consistency.

#### `skill:` prefix (legacy)

The `skill:` prefix in `command` or `prompt` is resolved at execution time by `resolveSkillCommand()` / `resolveSkillPrompt()` in `src/cron.zig`. It is **not** the same as the CLI `/skill <name>` command (which spawns a background subagent and returns immediately — unusable in cron).

- **Shell job**: set `command = "skill:<name> <extra-args>"`. `resolveSkillCommand` reads `## Script` from `~/.claude/skills/<name>/SKILL.md`, expands `~/`, builds `python3 <path> <extra-args>`.
- **Agent job**: set `prompt = "skill:<name>"`. `resolveSkillPrompt` reads `## Prompt` from `~/.claude/skills/<name>/SKILL.md` and inlines the full prompt text. The agent runs it directly — no subagent spawn.

Never use `/skill <name>` or `-m /skill <name>` as a cron prompt. It spawns a subagent and the output is lost.

#### Delivery contract

- **Skill jobs** (`job_type: skill`) must accept `--deliver-to CHAT_ID` and call the Python telegram helper directly (`~/.claude/skills/lib/telegram.py`). Scripts can read `NULLCLAW_JOB_ID` from the environment to append the job instance ID.
- **Shell skills** (legacy `skill:` prefix) follow the same contract as skill jobs.
- **Agent skills** set `delivery_mode: always`. The agent's stdout is captured and sent by the cron runner. No `--deliver-to` needed.
- The `## Script` section in `SKILL.md` must contain the script path as its first non-empty, non-backtick line, prefixed with `~/`.

#### Skill verification contract

- `--verify content_has_trace`: successful skill runs must emit the `NULLCLAW_JOB_ID` to stdout. The recommended helper is `trace_marker.emit_trace()`, called only after delivery succeeds.
- `--verify skill_contract`: successful skill runs must emit two scheduler-parsed markers to stdout:
  - `[skill-status:ok]`
  - `[trace:<job_id>]`
- To report a semantic problem while still exiting `0`, emit `[skill-status:degraded]` or `[skill-status:failed]` and still emit the trace marker. The scheduler records these as `failure_class=contract_degraded` / `contract_failed` and applies the configured repair policy.
- Use non-zero exit codes for transport/execution failures (spawn error, timeout, uncaught exception). Use the skill-status markers for semantic “the script ran but the result is not good enough” outcomes.

#### Source of truth

`~/.nullclaw/cron-seed.json` is the canonical job definition. To reload jobs from seed into the live DB:

```bash
curl -s -X POST http://localhost:PORT/cron/load-from-seed
```

Never edit the live DB directly to apply config changes — update `cron-seed.json` and call `load-from-seed`. Exception: correcting a corrupted `next_run_secs` after a manual trigger may require a direct `UPDATE` followed by a seed backup (`cp ~/.nullclaw/cron.db ~/.nullclaw/cron.db.bak.<timestamp>` then re-export with the Python dump script).

#### Manual job trigger

POST `/cron/run` with `{"id": "<job-id>"}` to trigger a job immediately. The DB-direct path uses `dbManualEnqueueJob` which atomically inserts into `cron_run_queue` **and** advances `next_run_secs` to the next scheduled occurrence in one `BEGIN IMMEDIATE` transaction. This prevents the scheduler tick from re-firing the job immediately after a manual run.

Never call `dbEnqueueJob` for manual triggers — it is a raw queue insert that does not advance the schedule.

#### Scheduler tick merge invariant

`mergeSchedulerTickChangesAndSave` (in `src/daemon.zig`) performs a read-modify-write cycle on the on-disk cron state after every scheduler tick. It calls `upsertSchedulerRuntimeJob` to either append new jobs or update existing ones.

**Invariant**: for the existing-job path, **all** routing-critical fields must be propagated from the in-memory runtime job to the on-disk copy. These include:

- `session_target`
- `delivery.account_id` / `account_id_owned`
- `delivery.peer_kind`
- `delivery.peer_id` / `peer_id_owned`
- `delivery.thread_id` / `thread_id_owned`

If any of these are omitted, a concurrent on-disk write (e.g. `load-from-seed` or a gateway API call) can silently strip the routing config from the persisted job. The regression test `mergeSchedulerTickChangesAndSave preserves routing fields on existing job update` in `src/daemon.zig` covers this path.

#### Operator alert delivery

`Config.scheduler.alert_channel` / `alert_to` / `alert_account` configure a fallback delivery destination for skill job failures. Both execution paths honour it:

- **Legacy (`CronScheduler`)**: `alert_delivery` is set via `setAlertDelivery()` in `schedulerThread`.
- **DB-direct (`runQueueWorker`)**: `GatewayState.alert_delivery` is populated from config in `gateway.run()` and used in all four failure branches (resolution, exec, collect, wait) plus non-zero exit.

When a job has `delivery_mode != none`, its own delivery config is used for alerts. The `alert_delivery` fallback is only used when the job has no delivery config.

#### Run history

Every completed job execution is appended to the `cron_runs` table (created by `ensureCronRunsTable`, called inside `ensureCronTable`). The table schema:

```sql
CREATE TABLE IF NOT EXISTS cron_runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id      TEXT NOT NULL,
  started_at  INTEGER NOT NULL DEFAULT 0,
  finished_at INTEGER NOT NULL DEFAULT 0,
  status      TEXT NOT NULL DEFAULT 'ok',
  output      TEXT
);
```

`dbCompleteJob` INSERTs the row and immediately prunes rows older than 30 days for that job (inline `DELETE`; no separate vacuum job needed).

CLI access:
- `nullclaw cron runs <id> [--limit N] [--json]` — per-job history (last 50 by default)
- `nullclaw cron job-status [--json]` — last known status per job, sorted by recency
- `nullclaw cron list [--limit N] [--json]` — all jobs as JSON array (stdout)
- `nullclaw cron schedule [--hours N] [--all] [--today] [--json]` — upcoming fires as JSON array

`--json` always writes to stdout (not stderr). Human-readable output continues to use `log.info` (stderr).

#### E2E verification

After a job runs, verify in `journalctl`:

```bash
journalctl --user -u nullclaw.service -n 50 --no-pager | grep "cron_queue\|cron_tick\|scheduler"
```

Expected log sequence for a healthy skill run:
1. `info(cron_tick): enqueued job '<id>' [<expr>] next_run=<ts>` — tick fired, next schedule set
2. `info(cron_queue): running queued job '<id>'` — worker picked it up
3. `info(cron_queue): [<id>] skill completed (ok): Delivered to Telegram chat <id>` — script ran and delivered

Scheduler liveness: `info(scheduler): alive, 0 jobs due (DbCronBackend)` appears every ~5 minutes when no jobs are due. Absence of this line for >10 minutes indicates the scheduler thread has stalled.

## 8) Validation Matrix

Required before any code commit:

```bash
zig build test --summary all        # all tests must pass, 0 leaks
```

For release changes:

```bash
zig build -Doptimize=ReleaseSmall  # must compile clean
```

Before any version bump, release branch, or tag work: read `RELEASING.md` and follow it exactly. Do not tag feature branches.

Additional expectations by change type:

- **Docs/comments only**: no build required, but verify no broken code references.
- **Security/runtime/gateway/tools**: include at least one boundary/failure-mode test.
- **Provider additions**: test vtable wiring + graceful failure without credentials.

If full validation is impractical, document what was run and what was skipped.

### 8.1 Test Coverage Mandate

**Every code change must be accompanied by tests.** No exceptions.

- **Behavior changes**: add or update tests that directly exercise the changed code path.
- **Bug fixes**: add a regression test that reproduces the original failure *before* the fix and passes after.
- **Logging-only or pure error-propagation changes** (e.g., `catch |err|` + `log.err(...)`): unit testing may not be practical. In this case add a comment near the change explaining why formal test coverage is omitted. Example:
  ```zig
  // NOTE: No unit test for this log path — would require a mock session manager.
  // Covered by manual integration testing against a running NullClaw instance.
  ```
- **Error path resource cleanup**: when a function allocates resources before returning an error, always free them before the `return error.Foo`. Verify with `zig build test` that the test allocator reports 0 leaks.
- Tests that were added to cover a specific fix must have a comment citing the bug they guard against, e.g.:
  ```zig
  // Regression: GLM-5 returns content=null on context-limit; parseNativeResponse must not silently succeed.
  ```

### 8.2 Git Hooks

The repository ships with pre-configured hooks in `.githooks/`. Activate once per clone:

```bash
git config core.hooksPath .githooks
```

Hooks:

| Hook | What it does |
|------|-------------|
| `pre-commit` | Runs `zig fmt --check src/` — blocks commit if any file is not formatted |
| `pre-push` | Runs `zig build test --summary all` — blocks push if any test fails or leaks |

To bypass a hook in an emergency: `git commit --no-verify` / `git push --no-verify`.

## 9) Autonomy and Security Policy

### Autonomy levels

Autonomy is **global** — there is no per-agent override in the current config model (`src/config_types.zig` `AutonomyConfig`, `src/security/policy.zig`). The mode name is `full`, not `autonomous`.

| Level | Shell tools | Notes |
|-------|------------|-------|
| `supervised` | blocked unless in `allowed_commands` | default; safe for multi-user bots |
| `full` | unrestricted | use only for trusted single-user deployments |

### `allowed_commands`

In `supervised` mode, agents can only run shell commands whose executable basename appears in `autonomy.allowed_commands`. Example config (`~/.nullclaw/config.json`):

```json
"autonomy": {
  "level": "supervised",
  "workspace_only": true,
  "max_actions_per_hour": 20,
  "allowed_commands": ["python3"]
}
```

`python3` must be present for interactive skill invocations — agents answering stock/weather/news queries call skill scripts directly via the `bash` tool. Cron skill jobs run outside the agent loop and are not subject to this policy.

### Known limitation

There is no per-agent autonomy or per-channel allowlist. Both `nunu` and `ping` bots share the global `allowed_commands`. If you need tighter restrictions per bot, the correct long-term fix is either:
- add per-agent autonomy config in `AgentConfig` / `AutonomyConfig`
- or route skill execution through a first-class skill tool path that does not depend on generic shell access

## 10) Web Retrieval and MCP Servers

### Search provider chain

`http_request.search_provider` defaults to `"auto"`, which tries providers in this order:

1. SearXNG (if `searxng_base_url` is configured)
2. **Brave** (requires `BRAVE_API_KEY` env var)
3. Firecrawl, Tavily, Perplexity, Exa, Jina (each requires its own API key)
4. DuckDuckGo (no key required, rate-limited)

API keys are read from environment variables only — not from `config.json`. Set them in `~/.nullclaw/.env` (loaded by the systemd `EnvironmentFile`). Never store live keys in `config.json` or commit them.

### MCP servers

MCP servers are configured in `config.json` under `mcp_servers` as an object-of-objects (compatible with Claude Desktop / Cursor format). Supported transports: `stdio` (child process) and `http` (JSON-RPC over HTTP).

**Critical for systemd**: the service runs with a restricted `PATH` that does not include nvm or user-local bin directories. Always use **absolute paths** for both `command` and script arguments.

```json
"mcp_servers": {
  "playwright": {
    "command": "/home/yanggf/.nvm/versions/node/v24.3.0/bin/node",
    "args": ["/home/yanggf/.nvm/versions/node/v24.3.0/bin/playwright-mcp", "--headless"]
  }
}
```

MCP tools are registered at agent startup as `mcp_<server>_<tool>` (e.g., `mcp_playwright_browser_navigate`). If a server fails to connect, its tools are silently omitted and an `error(mcp)` log line is emitted — check `journalctl` if tools are missing.

### Playwright MCP

- Package: `@playwright/mcp` (globally installed at `~/.nvm/versions/node/v24.3.0/lib`)
- Browser: Chromium headless shell at `~/.cache/ms-playwright/chromium_headless_shell-1217/`
- 21 tools registered: navigate, snapshot, click, type, screenshot, network requests, etc.
- Use for deep retrieval when web search and HTTP fetch both fail (e.g., JS-rendered pages, paywalled previews)

## 11) Skill Execution Security

Skill jobs run scripts via `sh -c`. Two invariants are enforced in `resolveSkillExecFrom` (`src/cron.zig`):

**Skill name validation** (`validateSkillNameSafe`): rejects names containing `/`, `\`, `..`, null bytes, or control characters before constructing the SKILL.md path. Prevents path traversal out of `~/.nullclaw/skills/`.

**Skill args validation** (`validateSkillArgsSafe`): rejects `skill_args` containing shell metacharacters (`;`, `&&`, `$()`, backticks, `|`, `>`, etc.) before interpolating args into the `sh -c` string. Only alphanumerics, spaces, `-`, `_`, `.`, `/`, `@`, `+`, `=`, `:` are permitted.

Both validators return typed errors (`UnsafeSkillName`, `UnsafeSkillArgs`) that propagate as job resolution failures — the job is marked `error` and an operator alert is sent.

**When adding a new skill execution path**: always call both validators before constructing any path or shell string. The existing `validateSkillName` in `src/skills.zig` covers the skills install/list surface; `validateSkillNameSafe`/`validateSkillArgsSafe` in `src/cron.zig` cover the execution surface. Do not bypass either.

## 12) Privacy and Sensitive Data (Required)

- Never commit real API keys, tokens, credentials, personal data, or private URLs.
- Use neutral placeholders in tests: `"test-key"`, `"example.com"`, `"user_a"`.
- Test fixtures must be impersonal and system-focused.
- Review `git diff --cached` before push for accidental sensitive strings.

## 13) Anti-Patterns (Do Not)

- Do not add C dependencies or large Zig packages without strong justification (binary size impact).
- Do not return vtable interfaces pointing to temporaries — dangling pointer.
- Do not use `std.io.getStdOut()` — it does not exist in Zig 0.15.
- Do not silently weaken security policy or access constraints.
- Do not add speculative config/feature flags "just in case".
- Do not skip `defer allocator.free(...)` — every allocation must be freed.
- Do not use `ArrayListUnmanaged.writer()` as `?*Io.Writer` — incompatible types.
- Do not modify unrelated modules "while here".
- Do not include personal identity or sensitive information in tests, examples, docs, or commits.
- Do not use `SQLITE_TRANSIENT` in auto-translated C code — use `SQLITE_STATIC` (null) instead.
- Do not use heap-allocated output buffers in `ChaCha20Poly1305.decrypt` — use stack buffer + `allocator.dupe()`.

## 14) Handoff Template (Agent → Agent / Maintainer)

When handing off work, include:

1. What changed
2. What did not change
3. Validation run and results (`zig build test --summary all`)
4. Remaining risks / unknowns
5. Next recommended action

## 15) Vibe Coding Guardrails

When working in fast iterative mode:

- Keep each iteration reversible (small commits, clear rollback).
- Validate assumptions with code search before implementing.
- Prefer deterministic behavior over clever shortcuts.
- Do not "ship and hope" on security-sensitive paths.
- If uncertain about Zig 0.15 API, check `src/` for existing usage patterns before guessing.
- If uncertain about architecture, read the vtable interface definition before implementing.
