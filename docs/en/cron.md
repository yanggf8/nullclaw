# Cron Operations

This guide explains how to operate NullClaw cron jobs after a claw is running. It is written for day-to-day operators, not for first-install bootstrapping.

## Operational Model

The cron DB at `~/.nullclaw/cron.db` is the scheduler authority. A running claw reads and updates this DB; it is the live state for job definitions, pause state, next run times, and run history.

Routine changes go through the CLI:

```bash
nullclaw cron add ...
nullclaw cron update <id> ...
nullclaw cron remove <id>
nullclaw cron pause <id>
nullclaw cron resume <id>
nullclaw cron run <id>
```

Backups use the live DB. `nullclaw cron backup` writes a timestamped backup file under `~/.nullclaw/backup/`, and `nullclaw cron restore [<file>]` reloads the latest backup or the file you name.

`~/.nullclaw/cron-seed.json` is a bootstrap artifact for first install only. After a claw is running, do not use seed reloads for routine changes.

`nullclaw cron init-seed` is bootstrap tooling for new installs with an empty cron DB. On a populated DB it refuses to run unless you pass `--rebuild`, which deliberately wipes existing jobs and run history before loading the seed. It is not the normal way to update jobs on a running claw.

## Job Types

NullClaw cron has three job types. Pick the type based on who should do the work and who should deliver the result.

| Type | Use when | Delivery | Argument forwarding |
|---|---|---|---|
| `shell` | You already have a command or script that performs the whole task. | The script usually self-delivers, so use `delivery_mode=none` unless you intentionally want cron to deliver captured output. | The command is executed by the scheduler as a shell command. Keep quoting explicit. |
| `agent` | You want the NullClaw agent to reason over a prompt with a selected model. | Cron captures the agent output and delivers it when `delivery_mode=always` or another delivery mode is configured. | The prompt is stored as the job input. Use `--model` and `--session-target isolated|main` to control execution. |
| `skill` | You want to run an installed skill script directly and keep delivery inside the skill. | The skill should accept `--deliver-to <chat_id>` and deliver through the channel helper itself. | Use `--skill-args "..."` or `-- <skill-args...>` to forward arguments to the skill. `--deliver-to` and `--account` are also forwarded so the script can use them. |

For skill jobs, the scheduler reads `~/.nullclaw/skills/<name>/SKILL.md`, resolves the `## Script` path, runs it as `python3 <script> <args>`, and injects execution context environment variables. In the production layout, `~/.nullclaw/skills/<name>` is usually a symlink into the editable skills mirror under `~/a/claw-skills/<name>`, so commit script changes in that mirror repository. Do not use an interactive `/skill <name>` prompt as a cron job; cron needs the script path or a normal agent prompt, not a background subagent command.

Typical skill job:

```bash
nullclaw cron add-skill "0 8 * * *" oilcon \
  --deliver-to 7972814626 \
  --account ping \
  --verify skill_contract \
  --repair alert_only \
  -- --market WTI
```

## Verification And Repair Policies

Verification decides whether a completed run was good enough. Repair decides what to do when it was not.

Verification modes:

| Mode | Meaning |
|---|---|
| `none` | Do not inspect the result beyond scheduler execution. |
| `exit_only` | Treat non-zero exit as failure; exit `0` is accepted. |
| `content_nonempty` | Require non-empty stdout. Empty stdout is recorded as degraded. |
| `content_has_trace` | Require stdout to contain the run trace ID. Skill scripts can emit `NULLCLAW_JOB_ID` after successful delivery. |
| `skill_contract` | Require separate stdout lines for `[skill-status:ok]` and `[trace:<job_id>]`. This is the strongest mode for self-delivering skill jobs. |

Skill status markers are semantic status from the script:

| Marker | Result |
|---|---|
| `[skill-status:ok]` | The script completed and judged its own result usable. |
| `[skill-status:degraded]` | The script ran, but the content or upstream data was not good enough. The run is recorded as degraded. |
| `[skill-status:failed]` | The script ran but reports semantic failure. The run is recorded as failed verification. |
| `[trace:<id>]` | Binds stdout to the scheduler trace ID. Emit this on its own line. |

Repair policies:

| Policy | Meaning |
|---|---|
| `none` | Record the run result and take no automatic action. |
| `retry_once` | Immediately retry once with the same execution context. The retry result is recorded in run history. |
| `alert_only` | Send an operator alert when a run fails or degrades, without retrying. |
| `pause_on_fail` | Pause the job after a hard failure. Degraded runs remain active. |

When `pause_on_fail` pauses a job, fix the underlying issue, inspect recent history, then resume it:

```bash
nullclaw cron runs <id>
nullclaw cron resume <id>
```

## Timezone Handling

Cron expressions are interpreted with the job's configured timezone offset. Use `--tz <offset>` when adding or updating a job, for example `--tz 8` for Taiwan time or `--tz -5` for US Eastern standard offset.

Schedules are stored as UTC epoch seconds in the DB. The timezone offset is stored with the job and used when calculating future fire times. This means two jobs with the same cron expression can have different `next_run_secs` values if their `--tz` values differ.

`cron show` output can be confusing because the stored timestamp is UTC while the schedule was chosen in local job time. If a job has a non-zero timezone offset, compare the job timezone and UTC time before assuming the job is late or early.

For a broader forecast, use:

```bash
nullclaw cron schedule --hours 24
nullclaw cron schedule --today
```

## Run History And Troubleshooting

Every completed execution is recorded in `cron_runs`. Start with per-job history:

```bash
nullclaw cron runs <id>
nullclaw cron show <id> --runs 20
```

To find bad runs across jobs:

```bash
nullclaw cron degraded --hours 24
nullclaw cron degraded --job <id> --hours 168
```

To find jobs without piping JSON through `grep`, filter `cron list` directly. Filters are ANDed:

```bash
nullclaw cron list --skill oilcon
nullclaw cron list --channel telegram --to 7972814626
nullclaw cron list --status error
nullclaw cron list --match oil --json
```

To inspect one run by trace:

```bash
nullclaw cron run-by-trace <trace_id>
```

For per-event diagnostics from skills (cache hits, LLM call timings, substaging
events, validation failures), use `cron trace`. It scans
`~/.nullclaw/skill-traces.jsonl` and pretty-prints matching events:

```bash
nullclaw cron trace skill-75e98cbb                         # all events for that job_id (prefix match)
nullclaw cron trace skill-75e98cbb --event llm_agent       # narrow by event-name substring
nullclaw cron trace skill-75e98cbb --limit 10              # most-recent 10 events only
```

The job_id argument is matched as a prefix, so the first 8-12 chars of a UUID
are usually enough. Each row shows `HH:MM:SS event variant=… elapsed_ms=…
returncode=… stdout_len=…` — known fields are surfaced; unknown ones are
omitted to keep rows scannable. For the raw JSON payload (including stderr
tails and full stack traces), `grep <job_id> ~/.nullclaw/skill-traces.jsonl`
remains the right tool.

To diagnose what a job will actually execute before it runs:

```bash
nullclaw cron explain <id>
nullclaw cron explain <id> --json
```

Cron-spawned subprocesses receive trace environment variables:

| Variable | Meaning |
|---|---|
| `NULLCLAW_EXECUTION_TRACE_ID` | Scheduler trace ID for this run, usually `<job_id>:<queue_or_time_id>`. |
| `NULLCLAW_JOB_ID` | Back-compatible alias for the same trace ID. Skill scripts should emit it when using trace verification. |
| `NULLCLAW_EXECUTION_SOURCE` | Execution path such as `cron_scheduler_skill`, `cron_manual_skill`, or a legacy scheduler source. |
| `NULLCLAW_SENSORIUM_STATE` | Set to `session_only_not_attached` so subprocess state is not persisted. |

For service-level troubleshooting, check the user service journal:

```bash
journalctl --user -u nullclaw.service -n 50 --no-pager
```

Healthy skill runs usually show this sequence:

```text
cron_tick: enqueued job '<id>'
cron_queue: running queued job '<id>'
cron_queue: [<id>] skill completed (ok)
```

If you see `cron_tick` without `cron_queue`, the worker may be stalled. If you see `cron_queue` without `skill completed`, inspect the run row and the script's stdout/stderr.

## Operator Recipes

Add a skill job with Telegram delivery:

```bash
nullclaw cron add-skill "0 8 * * *" oilcon \
  --deliver-to 7972814626 \
  --account ping \
  --timeout 120 \
  --tz 8 \
  --verify skill_contract \
  --repair alert_only
```

Pause a flaky job, inspect it, fix it, and resume:

```bash
nullclaw cron pause oilcon-daily
nullclaw cron runs oilcon-daily --limit 20
nullclaw cron show oilcon-daily --runs 20
# Fix the script, credentials, channel config, or job args.
nullclaw cron run oilcon-daily --dry-run
nullclaw cron run oilcon-daily
nullclaw cron resume oilcon-daily
```

Back up before bulk changes:

```bash
nullclaw cron backup
nullclaw cron list --json
nullclaw cron update <id> --expression "*/15 * * * *"
```

Restore after a bad change:

```bash
nullclaw cron pause <bad-job-id>
nullclaw cron restore
nullclaw cron list
```

If you need a specific backup instead of the latest one:

```bash
nullclaw cron restore ~/.nullclaw/backup/cron.db.20260416-080001
```
