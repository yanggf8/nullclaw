# Commands

This page groups the NullClaw CLI by task so you can find the right command quickly without scanning the full help output.

`nullclaw help` gives the top-level summary; this page stays aligned with it and expands into the detailed subcommands and notes.

## Page Guide

**Who this page is for**

- Users who already have NullClaw installed and need the right CLI entry point
- Operators checking runtime, service, channel, or diagnostic commands
- Contributors verifying command names, flags, and task groupings

**Read this next**

- Open [Configuration](./configuration.md) if you need to understand what the commands act on
- Open [Usage and Operations](./usage.md) if you want workflows instead of command listings
- Open [Development](./development.md) if you are changing CLI behavior or docs

**If you came from ...**

- [README](./README.md): this page is the fastest way to find a concrete command
- [Installation](./installation.md): after setup, use this page to validate the install and learn daily commands
- `nullclaw help`: use this page when the built-in help is correct but too terse

## Start with these

- Show help: `nullclaw help`
- Show version: `nullclaw version` or `nullclaw --version`
- First-time setup: `nullclaw onboard --interactive`
- Quick validation: `nullclaw agent -m "hello"`
- Long-running mode: `nullclaw gateway`

## Setup and interaction

| Command | Purpose |
|---|---|
| `nullclaw help` | Show top-level help |
| `nullclaw version` / `nullclaw --version` | Show CLI version |
| `nullclaw onboard --interactive` | Run the interactive setup wizard |
| `nullclaw onboard --api-key sk-... --provider openrouter` | Quick provider + API key setup |
| `nullclaw onboard --api-key ... --provider ... --model ... --memory ...` | Set provider, model, and memory backend in one command |
| `nullclaw onboard --channels-only` | Reconfigure channels and allowlists only |
| `nullclaw agent -m "..."` | Run a single prompt |
| `nullclaw agent` | Start interactive chat mode |

### Interactive model routing

- In `nullclaw agent`, `/model` shows the current model plus configured routing/fallback status.
- `/config reload` hot reloads supported keys from `config.json` (including agent profiles).
- When auto-routing is configured, `/model` also shows the last auto-route decision and why it was chosen.
- If a routed provider is temporarily rate-limited or out of credits, `/model` shows that route as degraded until its cooldown expires.
- `/model` also lists configured auto routes with their `cost_class` and `quota_class` metadata.
- `/model <provider/model>` pins the current session to that model and disables automatic routing.
- `/model auto` clears the user pin, restores the configured default model, and re-enables `model_routes` for later turns in the same session.
- If no `model_routes` are configured, `/model auto` still clears the pin and returns the session to the configured default model.
- Starting `nullclaw agent` with `--model` or `--provider` also pins the run and bypasses `model_routes`.

## Runtime and operations

| Command | Purpose |
|---|---|
| `nullclaw gateway` | Start the long-running runtime using configured host and port |
| `nullclaw gateway --port 8080` | Override the gateway port from the CLI |
| `nullclaw gateway --host 0.0.0.0 --port 8080` | Override host and port from the CLI |
| `nullclaw service install` | Install the background service |
| `nullclaw service start` | Start the background service |
| `nullclaw service stop` | Stop the background service |
| `nullclaw service restart` | Restart the background service |
| `nullclaw service status` | Show service status |
| `nullclaw service uninstall` | Remove the background service |
| `nullclaw status` | Show overall system status |
| `nullclaw doctor` | Run diagnostics |
| `nullclaw update --check` | Check for updates without installing |
| `nullclaw update --yes` | Install updates without prompting |
| `nullclaw auth login openai-codex` | Authenticate `openai-codex` via OAuth device flow |
| `nullclaw auth login openai-codex --import-codex` | Import auth from `~/.codex/auth.json` |
| `nullclaw auth status openai-codex` | Show authentication state |
| `nullclaw auth logout openai-codex` | Remove stored credentials |

Notes:

- `auth` currently supports only `openai-codex`.
- `gateway --host/--port` overrides only the bind settings; the rest of gateway security still comes from config.

## Channels, scheduling, and extensions

### `channel`

| Command | Purpose |
|---|---|
| `nullclaw channel list` | List known and configured channels |
| `nullclaw channel start` | Start the default available channel |
| `nullclaw channel start telegram` | Start a specific channel |
| `nullclaw channel status` | Show channel health |
| `nullclaw channel add <type>` | Print guidance for adding a channel to config |
| `nullclaw channel remove <name>` | Print guidance for removing a channel from config |

### `cron`

| Command | Purpose |
|---|---|
| `nullclaw cron list [--json] [--limit N] [--all] [--skill <name>] [--channel <name>] [--to <id>] [--status <ok\|error\|paused>] [--match <substring>]` | Weekly chronological fire-time table (human) or JSON array; filters are ANDed and `--all` shows all matching jobs without a limit |
| `nullclaw cron schedule [--hours N] [--today] [--all] [--json]` | Upcoming fires within a time window |
| `nullclaw cron status` | Scheduler daemon health summary |
| `nullclaw cron job-status [--json]` | Per-job last-run status and timestamps (includes `verification_mode` and `repair_policy` when configured) |
| `nullclaw cron add "0 * * * *" "command" [--tz <offset>] [--verify <mode>] [--repair <policy>]` | Add a recurring shell task |
| `nullclaw cron add-agent "0 * * * *" "prompt" --model <model> [--session-target isolated\|main] [--channel <name>] [--account <id>] [--to <id>] [--tz <offset>] [--verify <mode>] [--repair <policy>]` | Add a recurring agent task |
| `nullclaw cron add-skill "0 * * * *" <skill> [--skill-args "..."] [--deliver-to <id>] [--account <id>] [--timeout <secs>] [--tz <offset>] [--verify <mode>] [--repair <policy>] [-- <skill-args...>]` | Add a recurring skill task. Use `--` to forward args to the skill verbatim (needed if the skill itself takes `--verify`/`--repair`) |
| `nullclaw cron once <delay> "command"` | Add a one-shot delayed shell task |
| `nullclaw cron once-agent <delay> "prompt" --model <model> [--session-target isolated\|main]` | Add a one-shot delayed agent task |
| `nullclaw cron run <id> [--dry-run]` | Run a task immediately with full verify/repair semantics (records a `manual=1` run row). `--dry-run` prints the resolved spec without executing |
| `nullclaw cron show <id> [--runs N] [--json]` | Show a single job's full spec, next fire time, and last N runs (default 10) |
| `nullclaw cron explain <id> [--json]` | Show resolved execution, delivery, verification/repair, and trace environment for a job |
| `nullclaw cron pause <id>` / `resume <id>` | Pause or resume a task |
| `nullclaw cron remove <id>` | Delete a task |
| `nullclaw cron update <id> [--expression <expr>] [--command <cmd>] [--prompt <p>] [--model <m>] [--session-target isolated\|main] [--enable\|--disable] [--tz <offset>] [--verify <mode>] [--repair <policy>]` | Update an existing task; `--enable` also clears the paused flag, `--disable` sets it |
| `nullclaw cron runs <id> [--limit N] [--json]` | Show recent run history for a task (includes exit code, failure class, repair action, verified state, and trace ID) |
| `nullclaw cron degraded [--hours N] [--job <id>] [--json]` | List failed or degraded runs across all jobs in a time window (default 24h). Matches runs where `status=error` OR `verified>=2`. Prints a `run-by-trace` hint when results are found |
| `nullclaw cron run-by-trace <trace_id> [--json]` | Look up a run by its `trace_id`. Exits 1 if no runs match, for use in shell pipelines. |
| `nullclaw cron backup` | Export all jobs to a timestamped seed file |
| `nullclaw cron restore [<file>]` | Restore jobs from a seed file |
| `nullclaw cron export-seed` | Print jobs as a portable seed JSON |
| `nullclaw cron init-seed [--rebuild]` | Load seed file into an empty DB for a new install. Refuses a populated DB unless `--rebuild` is passed |

**Verification and repair policies** (`--verify` / `--repair`):

- `--verify <mode>` — how the scheduler judges a completed run. One of:
  - `none` (default) — no verification
  - `exit_only` — only non-zero exit is treated as failure
  - `content_nonempty` — empty stdout is treated as degraded
  - `content_has_trace` — stdout must contain the job ID (skills can use the `trace_marker.emit_trace()` helper)
  - `skill_contract` — stdout must include both `[skill-status:ok]` and `[trace:<job_id>]`, each on its own line; `[skill-status:degraded]` records a degraded run and `[skill-status:failed]` records a hard semantic failure
- `--repair <policy>` — what the scheduler does when a run is marked degraded/failed. One of:
  - `none` (default) — record the outcome and move on
  - `retry_once` — immediately re-run once; the retry outcome is recorded as `repair_action=retried_ok` or `retried_failed`
  - `alert_only` — send an operator alert without retrying (`repair_action=alert_sent`)
  - `pause_on_fail` — pause the job after a hard failure (`verified=3`), recording `repair_action=paused_job`; degraded runs (`verified=2`) stay active

Unrecognized values are rejected with an error listing the allowed values — a typo on `cron update` will not silently clear an existing policy.

### `skills`

| Command | Purpose |
|---|---|
| `nullclaw skills list` | List installed skills |
| `nullclaw skills install <source>` | Install from a GitHub URL or local path |
| `nullclaw skills remove <name>` | Remove a skill |
| `nullclaw skills info <name>` | Show skill metadata |

### `history`

| Command | Purpose |
|---|---|
| `nullclaw history list [--limit N] [--offset N] [--json]` | List conversation sessions |
| `nullclaw history show <session_id> [--limit N] [--offset N] [--json]` | Show messages for a session |

## Data, models, and workspace

### `memory`

| Command | Purpose |
|---|---|
| `nullclaw memory stats` | Show resolved memory config and counters |
| `nullclaw memory count` | Show total number of memory entries |
| `nullclaw memory reindex` | Rebuild the vector index |
| `nullclaw memory search "query" --limit 10` | Run retrieval against memory |
| `nullclaw memory get <key>` | Show one memory entry |
| `nullclaw memory list --category task --limit 20` | List memory entries by category |
| `nullclaw memory list --session <id>` | List entries for a specific session scope |
| `nullclaw memory list --show-age` | List entries with freshness age tags (≥7d, ≥30d) |
| `nullclaw memory drain-outbox` | Drain the durable vector outbox queue |
| `nullclaw memory forget <key>` | Delete one memory entry (all scopes) |
| `nullclaw memory forget <key> --session <id>` | Delete entry for a specific session scope only |
| `nullclaw memory run-hygiene` | Run a memory hygiene pass now (bypasses 12h cooldown) |

### `workspace`, `capabilities`, `models`, `migrate`

| Command | Purpose |
|---|---|
| `nullclaw workspace edit AGENTS.md` | Open a bootstrap markdown file in `$EDITOR` |
| `nullclaw workspace reset-md --dry-run` | Preview workspace markdown reset |
| `nullclaw workspace reset-md --include-bootstrap --clear-memory-md` | Reset bundled markdown files and optionally clear extra files |
| `nullclaw capabilities` | Show a text capability summary |
| `nullclaw capabilities --json` | Show a JSON capability manifest |
| `nullclaw models list` | List providers and default models |
| `nullclaw models info <model>` | Show model details |
| `nullclaw models benchmark` | Run model latency benchmark |
| `nullclaw models refresh` | Refresh the model catalog |
| `nullclaw migrate openclaw --dry-run` | Preview OpenClaw migration |
| `nullclaw migrate openclaw --source /path/to/workspace` | Migrate from a specific source workspace |

Notes:

- `workspace edit` works only with file-based backends such as `markdown` and `hybrid`.
- If bootstrap data is stored in the database backend, the CLI will tell you to use the agent's `memory_store` tool instead.

## Hardware and automation-facing entry points

### `hardware`

| Command | Purpose |
|---|---|
| `nullclaw hardware scan` | Scan connected hardware |
| `nullclaw hardware flash <firmware_file> [--target <board>]` | Flash firmware to a device (currently a placeholder command) |
| `nullclaw hardware monitor` | Monitor hardware devices (currently a placeholder command) |

### Top-level machine-facing flags

These are more useful for automation, probing, or integrations than for normal day-to-day CLI use:

| Command | Purpose |
|---|---|
| `nullclaw --export-manifest` | Export the runtime manifest |
| `nullclaw --list-models` | Print model information |
| `nullclaw --probe-provider-health` | Probe provider health |
| `nullclaw --probe-channel-health` | Probe channel health |
| `nullclaw --from-json` | Run a JSON-driven entry path |

## Recommended troubleshooting order

1. `nullclaw doctor`
2. `nullclaw status`
3. `nullclaw channel status`
4. `nullclaw agent -m "self-check"`
5. If gateway is involved, also run `curl http://127.0.0.1:3000/health`

## Next Steps

- Go to [Usage and Operations](./usage.md) for task-based runtime workflows
- Go to [Configuration](./configuration.md) if a command depends on provider, gateway, or memory settings
- Go to [Development](./development.md) if you plan to change command behavior or update docs alongside code

## Related Pages

- [README](./README.md)
- [Installation](./installation.md)
- [Gateway API](./gateway-api.md)
- [Architecture](./architecture.md)
