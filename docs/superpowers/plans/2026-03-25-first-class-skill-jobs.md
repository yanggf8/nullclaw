# First-Class Skill Jobs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `skill` a first-class `job_type` in nullclaw's cron system so skills own their entire workflow (execution, delivery, formatting) and cron only schedules, triggers, and records status.

**Architecture:** Add `job_type = skill` alongside existing `shell` and `agent` types. Skill jobs store `skill_name` and `skill_args` columns. At execution time, the cron runner resolves the skill's SKILL.md, determines whether it's a script-based or LLM-based skill, and dispatches accordingly. Skills self-deliver (shell skills via `--deliver-to`, agent skills via their own delivery logic). The `resolveSkillCommand()` / `resolveSkillPrompt()` shims are removed once migration is complete.

**Tech Stack:** Zig 0.15.2, SQLite (cron.db), Python 3 (skill scripts), Claude API (news skill wrapper)

---

## Gemini Review — Issues Addressed

This plan incorporates all feedback from the Gemini tech evaluation review:

1. **Two-layer JobType enum** — Task 2 now explicitly updates BOTH `src/cron.zig` AND `src/cron/types.zig`
2. **All struct updates** — Task 2 covers `CronJob`, `CronJobSpec`, `CronJobPatch`, `NewJobSpec`, `CronJobSummary`
3. **`freeJobOwned()` leak fix** — Task 2 includes adding `skill_name`/`skill_args` frees
4. **`dbLoadJobSpec()` fallback path** — Task 3 explicitly covers this
5. **Dequeue vtable propagation** — Task 3 covers `DbCronBackend.vtableDequeue()`
6. **Enum ordinal cast safety** — Task 2 notes the invariant for `@enumFromInt(@intFromEnum(...))`
7. **Rebuild before seed reload** — Task 6 explicitly requires rebuild first
8. **`command` field for skill jobs** — Task 2 adds parser branch for `job_type == .skill`
9. **`builtin.is_test` guard** — Task 4 includes the guard pattern
10. **`ANTHROPIC_API_KEY` env** — Task 1 documents the requirement
11. **Task reordering** — Task 1 (Python script) moved to Task 7 (independent, no Zig coupling)
12. **E2E verifies DB status** — Task 8 includes `last_status`/`last_run_secs` check

---

## Current State

### How skills work today (shim layer)

- `job_type: shell` + `command: "skill:commute --from X --to Y --deliver-to CHAT_ID"` — resolveSkillCommand() reads `## Script` from SKILL.md, builds `python3 <path> <args>`
- `job_type: agent` + `prompt: "skill:news"` — resolveSkillPrompt() reads `## Prompt` from SKILL.md, inlines the full prompt text
- Delivery is split: shell skills self-deliver via `--deliver-to`; agent skills rely on cron's `delivery_mode: always`

### Problems with current approach

1. **Leaky abstraction** — cron must know whether a skill is shell or agent, and wire delivery differently for each
2. **No unified skill interface** — adding a new skill requires knowing which `job_type` to use and how to wire delivery
3. **News skill gap** — the only skill without a script, requires LLM, needs a Python wrapper to be self-contained
4. **resolveSkill* shims** — bolt-on resolution scattered across tick(), runQueueWorker(), cliRunJob()

### Target state

- `job_type: skill` with `skill_name` + `skill_args`
- Each skill is a self-contained building block: owns execution, delivery, and output formatting
- Cron only schedules, triggers, records status — does NOT manage delivery for skill jobs
- All skills have a runnable script (including news, which gets a Python wrapper calling Claude API)

---

## File Structure

### Files to modify

| File | Changes |
|------|---------|
| `src/cron/types.zig` | Add `.skill` to `JobType`, add `skill_name`/`skill_args` to `CronJob`, `CronJobSpec`, `CronJobPatch`, `NewJobSpec`, `CronJobSummary` |
| `src/cron.zig` | Add `.skill` to local `JobType`, update `freeJobOwned()`, `dbSaveJob()`, `dbListJobsJson()`, `dbLoadJobSpec()`, add `resolveSkillExec()`, add `.skill` branch to `tick()`, `cliRunJob()`, update job parser for `skill` type |
| `src/cron/db.zig` | Update `vtableAdd()`, `vtableDequeue()`, `vtableUpdate()` for skill fields, update schema migration |
| `src/cron/memory.zig` | Update `vtableAdd()`, `vtableDequeue()` for skill fields (propagation via `@enumFromInt`) |
| `src/gateway.zig` | Add `.skill` branch to `runQueueWorker()`, update `cronAddHandler()`, `cronUpdateHandler()` for skill fields |
| `~/.claude/skills/news/run.py` | Create: Python wrapper for self-contained news skill |
| `~/.claude/skills/news/SKILL.md` | Add `## Script` section, remove "No run.py" note |
| `~/.nullclaw/cron-seed.json` | Migrate all 9 jobs to `job_type: skill` |

### Enum ordinal invariant (CRITICAL)

Both `src/cron.zig:JobType` and `src/cron/types.zig:JobType` must add `.skill` at the **same ordinal position** (after `.agent`, ordinal 2). Multiple files use `@enumFromInt(@intFromEnum(...))` casts between these enums:
- `src/cron/memory.zig` (lines 100, 184, 257, 364)
- `src/cron/db.zig` (lines 136, 713)
- `src/gateway.zig` (line 3565)

If ordinals diverge, jobs will silently execute as the wrong type.

---

## Task 1: Add `skill` to JobType Enums (Both Files)

**Files:**
- Modify: `src/cron/types.zig` — canonical JobType enum
- Modify: `src/cron.zig` — legacy JobType enum (must match ordinal)

- [ ] **Step 1: Write failing test**

In `src/cron/types.zig` test section:
```zig
test "JobType parses skill" {
    const jt = JobType.parse("skill");
    try std.testing.expectEqual(JobType.skill, jt);
    try std.testing.expectEqualStrings("skill", jt.asStr());
}
```

- [ ] **Step 2: Run test — verify it fails**

```bash
zig build test --summary all 2>&1 | grep "JobType parses skill"
```

- [ ] **Step 3: Add `.skill` variant to `src/cron/types.zig:JobType`**

```zig
pub const JobType = enum {
    shell,
    agent,
    skill,

    pub fn asStr(self: JobType) []const u8 {
        return switch (self) {
            .shell => "shell",
            .agent => "agent",
            .skill => "skill",
        };
    }

    pub fn parse(raw: []const u8) JobType {
        if (std.ascii.eqlIgnoreCase(raw, "agent")) return .agent;
        if (std.ascii.eqlIgnoreCase(raw, "skill")) return .skill;
        return .shell;
    }
};
```

- [ ] **Step 4: Add `.skill` variant to `src/cron.zig:JobType` (must match ordinal)**

Mirror the same change: add `.skill` after `.agent`, update `asStr()` and `parse()`.

- [ ] **Step 5: Run tests — verify all pass**

```bash
zig build test --summary all
```

The compiler will flag every exhaustive `switch` on `JobType` that is missing `.skill`. Fix each by adding `.skill => { ... }` stubs (can be `@panic("TODO: skill")` temporarily — they will be filled in Task 4).

- [ ] **Step 6: Commit**

```bash
git add src/cron.zig src/cron/types.zig src/cron/db.zig src/cron/memory.zig src/gateway.zig
git commit -m "feat(cron): add skill variant to JobType enum in both type layers"
```

---

## Task 2: Add `skill_name` and `skill_args` to All Structs

**Files:**
- Modify: `src/cron/types.zig` — `CronJob`, `CronJobSpec`, `CronJobPatch`, `NewJobSpec`, `CronJobSummary`
- Modify: `src/cron.zig` — `freeJobOwned()`, job parser

- [ ] **Step 1: Add fields to `CronJob` in `src/cron/types.zig`**

After the `model` field (line 121):
```zig
skill_name: ?[]const u8 = null,
skill_args: ?[]const u8 = null,
```

- [ ] **Step 2: Add fields to `CronJobSpec`**

After `model` (line 138):
```zig
skill_name: ?[]const u8 = null,
skill_args: ?[]const u8 = null,
```

- [ ] **Step 3: Add fields to `CronJobPatch`**

After `delivery_account_id` (line 102):
```zig
skill_name: ?[]const u8 = null,
skill_args: ?[]const u8 = null,
```

- [ ] **Step 4: Add fields to `NewJobSpec`**

After `model` (line 188):
```zig
skill_name: ?[]const u8 = null,
skill_args: ?[]const u8 = null,
```

- [ ] **Step 5: Add fields to `CronJobSummary`**

After `timeout_secs` (line 177):
```zig
skill_name: ?[]const u8 = null,
skill_args: ?[]const u8 = null,
```

- [ ] **Step 6: Update `freeJobOwned()` in `src/cron.zig`**

Add after the `model` free (line 453):
```zig
if (job.skill_name) |sn| self.allocator.free(sn);
if (job.skill_args) |sa| self.allocator.free(sa);
```

- [ ] **Step 7: Update job parser in `src/cron.zig` for `job_type == .skill`**

In the JSON parser around line 1488, where `command` is extracted, add a branch:
```zig
if (job_type == .skill) {
    // skill jobs don't require command — use empty string
    break :blk "";
}
```

Also parse `skill_name` and `skill_args` from the JSON object and assign them to the job.

- [ ] **Step 8: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 9: Commit**

```bash
git add src/cron/types.zig src/cron.zig
git commit -m "feat(cron): add skill_name/skill_args to all job structs"
```

---

## Task 3: DB Schema — Columns, Persistence, and Dequeue

**Files:**
- Modify: `src/cron.zig` — schema migration, `dbSaveJob()`, `dbListJobsJson()`, `dbLoadJobSpec()`
- Modify: `src/cron/db.zig` — `vtableAdd()`, `vtableDequeue()`, `vtableUpdate()`, schema migration

- [ ] **Step 1: Write failing test**

```zig
test "skill job round-trips through DB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Create DB, add a skill job, reload, verify skill_name and skill_args survive
    // Use DbCronBackend with tmp dir db_path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try tmp.dir.realpath(".", &path_buf);
    var be = cron_db.DbCronBackend.initWithPath(std.testing.allocator, db_path);
    defer be.deinit();
    const backend = be.backend();

    const id = try backend.add(.{
        .expression = "*/5 * * * *",
        .job_type = .skill,
        .skill_name = "commute",
        .skill_args = "--from A --to B --deliver-to 123",
    });
    defer std.testing.allocator.free(id);

    // Dequeue and verify
    // ... or list and verify skill_name/skill_args in JSON output
}
```

- [ ] **Step 2: Add columns to schema migration in `src/cron/db.zig`**

In `ensureSchema()` or the equivalent migration path:
```sql
ALTER TABLE cron_jobs ADD COLUMN skill_name TEXT;
ALTER TABLE cron_jobs ADD COLUMN skill_args TEXT;
```

Use the existing pattern: try ALTER, ignore "duplicate column" error.

- [ ] **Step 3: Update `vtableAdd()` in `db.zig` to INSERT skill_name, skill_args**

Extend the INSERT statement to include the two new columns. Bind from `spec.skill_name` and `spec.skill_args`.

- [ ] **Step 4: Update `vtableDequeue()` in `db.zig` to SELECT and populate skill fields**

Add `skill_name` and `skill_args` to the SELECT in dequeue. Populate `CronJobSpec.skill_name` and `.skill_args` from the result columns.

- [ ] **Step 5: Update `vtableUpdate()` in `db.zig` for skill fields in `CronJobPatch`**

When `patch.skill_name` or `patch.skill_args` is non-null, include them in the UPDATE SET clause.

- [ ] **Step 6: Update `dbSaveJob()` in `src/cron.zig` to persist skill fields**

Add `skill_name` and `skill_args` to the INSERT/UPDATE in the legacy save path.

- [ ] **Step 7: Update `dbListJobsJson()` in `src/cron.zig` to emit skill fields**

Add `skill_name` and `skill_args` to the SELECT and JSON output. Note: this function is in `src/cron.zig`, not `src/gateway.zig`.

- [ ] **Step 8: Update `dbLoadJobSpec()` fallback in `src/cron.zig`**

The fallback path (used when vtable backend is absent) must SELECT and populate `skill_name`/`skill_args` too. This is around line 3420 of cron.zig.

- [ ] **Step 9: Update `MemoryCronBackend` in `src/cron/memory.zig`**

Propagate `skill_name`/`skill_args` in `vtableAdd()` and `vtableDequeue()`. These use `@enumFromInt(@intFromEnum(...)` casts for job_type — the field copies for skill_name/skill_args should be straightforward optional copies.

- [ ] **Step 10: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 11: Commit**

```bash
git add src/cron.zig src/cron/db.zig src/cron/memory.zig
git commit -m "feat(cron): add skill_name/skill_args columns, persistence, and dequeue"
```

---

## Task 4: Skill Execution Branch

Add `skill` case to the three execution paths: `tick()`, `runQueueWorker()`, and `cliRunJob()`.

**Files:**
- Modify: `src/cron.zig` — `tick()`, `cliRunJob()`, add `resolveSkillExec()`
- Modify: `src/gateway.zig` — `runQueueWorker()`

- [ ] **Step 1: Add `resolveSkillExec()` helper in `src/cron.zig`**

```zig
/// Resolves a skill name + args into an executable shell command.
/// Reads ## Script from ~/.claude/skills/<name>/SKILL.md.
/// Returns heap-allocated "python3 <expanded_path> <args>" or error.
/// The caller must free the returned slice.
pub fn resolveSkillExec(allocator: std.mem.Allocator, skill_name: ?[]const u8, skill_args: ?[]const u8) ![]const u8 {
    const name = skill_name orelse return error.MissingSkillName;
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/.claude/skills/{s}/SKILL.md", .{ home, name });
    defer allocator.free(skill_md_path);

    const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 256 * 1024) catch return error.SkillNotFound;
    defer allocator.free(content);

    // Extract first non-empty, non-``` line from ## Script section
    const script_header = "\n## Script\n";
    const header_pos = std.mem.indexOf(u8, content, script_header) orelse return error.NoScriptSection;
    const body_start = header_pos + script_header.len;
    const body = content[body_start..];
    const next_section = std.mem.indexOf(u8, body, "\n## ");
    const section = if (next_section) |n| body[0..n] else body;

    var line_iter = std.mem.splitScalar(u8, section, '\n');
    var script_path: ?[]const u8 = null;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r`");
        if (trimmed.len == 0) continue;
        script_path = trimmed;
        break;
    }
    const raw_path = script_path orelse return error.NoScriptPath;

    // Expand ~/
    const expanded = if (std.mem.startsWith(u8, raw_path, "~/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw_path[2..] })
    else
        try allocator.dupe(u8, raw_path);
    defer allocator.free(expanded);

    const args = skill_args orelse "";
    if (args.len > 0) {
        return try std.fmt.allocPrint(allocator, "python3 {s} {s}", .{ expanded, args });
    }
    return try std.fmt.allocPrint(allocator, "python3 {s}", .{expanded});
}
```

- [ ] **Step 2: Add `.skill` branch to `tick()` in `src/cron.zig`**

In the `switch (job.job_type)` block (around line 841):

```zig
.skill => {
    // Skill jobs own their entire workflow. Cron only triggers + records.
    const skill_cmd = if (!builtin.is_test)
        resolveSkillExec(self.allocator, job.skill_name, job.skill_args) catch |err| blk: {
            log.err("cron job '{s}' skill resolution failed: {}", .{ job.id, err });
            job.last_run_secs = now;
            job.last_status = "error";
            break :blk null;
        }
    else
        null;

    if (skill_cmd == null and !builtin.is_test) continue;

    if (builtin.is_test) {
        // Test mode: record execution without subprocess
        job.last_run_secs = now;
        job.last_status = "ok";
        continue;
    }

    defer self.allocator.free(skill_cmd.?);
    const result = std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &.{ platform.getShell(), platform.getShellFlag(), skill_cmd.? },
        .cwd = self.shell_cwd,
    }) catch |err| {
        log.err("cron job '{s}' failed to start: {}", .{ job.id, err });
        job.last_run_secs = now;
        job.last_status = "error";
        continue;
    };
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
    job.last_run_secs = now;
    job.last_status = if (exit_code == 0) "ok" else "error";
    job.last_output = if (result.stdout.len > 0)
        self.allocator.dupe(u8, result.stdout) catch null
    else if (result.stderr.len > 0)
        self.allocator.dupe(u8, result.stderr) catch null
    else
        null;
},
```

- [ ] **Step 3: Add `.skill` branch to `runQueueWorker()` in `src/gateway.zig`**

In the `switch (spec.job_type)` block (around line 3622):

```zig
.skill => {
    const skill_cmd = cron_mod.resolveSkillExec(arena, spec.skill_name, spec.skill_args) catch |err| {
        log.err("[{s}] skill resolution failed: {s}", .{ spec.id, @errorName(err) });
        complete(&state.cron_db_backend, state.cron_db_path, spec.id, dr.queue_row_id, now, "error", null, spec.delete_after_run, false);
        continue;
    };
    defer arena.free(skill_cmd);
    // Execute like shell — skill owns delivery, cron just records
    var shell_child = std.process.Child.init(
        &.{ @import("platform.zig").getShell(), @import("platform.zig").getShellFlag(), skill_cmd },
        arena,
    );
    // ... same subprocess pattern as .shell branch ...
    // Record status via complete()
},
```

- [ ] **Step 4: Add `.skill` branch to `cliRunJob()` in `src/cron.zig`**

In the `switch (job.job_type)` block (around line 3053):

```zig
.skill => {
    const skill_cmd = resolveSkillExec(allocator, job.skill_name, job.skill_args) catch |err| {
        job.last_run_secs = run_at;
        job.last_status = "error";
        try cron_save_fn();
        log.err("Skill resolution for job '{s}' failed: {s}", .{ id, @errorName(err) });
        return;
    };
    defer allocator.free(skill_cmd);
    // Execute via subprocess, same pattern as .shell
},
```

- [ ] **Step 5: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 6: Commit**

```bash
git add src/cron.zig src/gateway.zig
git commit -m "feat(cron): add skill execution branch to tick, worker, and CLI"
```

---

## Task 5: Wire Skill Jobs into HTTP API

**Files:**
- Modify: `src/gateway.zig` — `cronAddHandler()`, `cronUpdateHandler()`

- [ ] **Step 1: Update `cronAddHandler()` to parse skill fields**

When `job_type == "skill"`, parse `skill_name` and `skill_args` from the request body and set them on `NewJobSpec`.

- [ ] **Step 2: Update `cronUpdateHandler()` for skill fields**

When `patch.skill_name` or `patch.skill_args` is present, pass them through to the backend update.

- [ ] **Step 3: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 4: Commit**

```bash
git add src/gateway.zig
git commit -m "feat(cron): wire skill_name/skill_args into HTTP API handlers"
```

---

## Task 6: Migrate cron-seed.json and Live DB

**PREREQUISITE:** Binary MUST be rebuilt and gateway bounced with Tasks 1-5 changes BEFORE reloading seed. Otherwise `JobType.parse("skill")` falls through to `.shell` in the old binary.

**Files:**
- Modify: `~/.nullclaw/cron-seed.json`

- [ ] **Step 1: Rebuild and bounce gateway**

```bash
cd /home/yanggf/nullclaw && zig build
kill $(pgrep -f "nullclaw gateway")
# start-gateway.sh auto-restarts with new binary
sleep 5
curl -s http://localhost:3000/health | head -1  # verify alive
```

- [ ] **Step 2: Update cron-seed.json**

Convert all 9 jobs from `skill:` prefix to proper `job_type: "skill"`:

**Shell skill jobs** (commute, doughcon):
```json
{
  "expression": "20 23 * * 0,1,3",
  "job_type": "skill",
  "skill_name": "commute",
  "skill_args": "--from 淡水安泰登峰 --to 小巨蛋 --location 新北市 --location 臺北市 --deliver-to 1234567890",
  "timeout_secs": 90,
  "delivery_mode": "none"
}
```

**Agent skill jobs** (news) — now self-delivering via Python wrapper:
```json
{
  "expression": "30 0 * * 2-6",
  "job_type": "skill",
  "skill_name": "news",
  "skill_args": "--deliver-to 1234567890",
  "timeout_secs": 180,
  "delivery_mode": "none"
}
```

**Record-only jobs** (doughcon --mode record) — no `--deliver-to`, which is correct:
```json
{
  "expression": "0 12 * * *",
  "job_type": "skill",
  "skill_name": "doughcon",
  "skill_args": "--mode record",
  "timeout_secs": 30,
  "delivery_mode": "none"
}
```

- [ ] **Step 3: Reload from seed**

```bash
curl -s -X POST http://localhost:3000/cron/load-from-seed
```

- [ ] **Step 4: Verify all jobs loaded**

```bash
curl -s http://localhost:3000/cron/list | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    print(f\"{j['id'][:8]}  {j['job_type']:6}  {j.get('skill_name',''):10}  {j.get('skill_args','')[:60]}\")
print(f'Total: {len(jobs)} jobs')
assert all(j['job_type'] == 'skill' for j in jobs), 'Not all jobs are skill type!'
print('All jobs are skill type.')
"
```

- [ ] **Step 5: Commit seed file**

```bash
git add ~/.nullclaw/cron-seed.json
git commit -m "feat(cron): migrate seed jobs to job_type=skill"
```

---

## Task 7: News Skill Script (Python Wrapper)

The news skill is the only one without a `run.py`. Create a Python script that:
1. Fetches the 4 RSS feeds from SKILL.md
2. Calls Claude API to summarize
3. Sends the summary to Telegram via the shared `telegram.py` helper

**Operational requirement:** `ANTHROPIC_API_KEY` must be set in the gateway's environment (or the start-gateway.sh script). The Python script reads it from `os.environ`.

**Files:**
- Create: `~/.claude/skills/news/run.py`
- Modify: `~/.claude/skills/news/SKILL.md` (add `## Script` section, remove "No run.py" note)

- [ ] **Step 1: Create `run.py`**

```python
#!/usr/bin/env python3
"""News skill: fetch RSS feeds, summarize via Claude API, deliver to Telegram."""
import argparse
import sys
import os
import urllib.request
import xml.etree.ElementTree as ET

def fetch_rss(url: str) -> list[str]:
    """Fetch RSS feed and return list of article titles."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
        root = ET.fromstring(data)
        return [item.find("title").text for item in root.iter("item") if item.find("title") is not None]
    except Exception as e:
        print(f"Warning: failed to fetch {url}: {e}", file=sys.stderr)
        return []

def build_prompt(feeds: dict[str, list[str]]) -> str:
    """Build the summarization prompt from feed results."""
    sections = []
    for name, titles in feeds.items():
        if titles:
            items = "\n".join(f"- {t}" for t in titles[:80])
            sections.append(f"### {name}\n{items}")
    feed_text = "\n\n".join(sections)
    return f"""Based on these RSS feed articles from the last 24 hours, create a news summary in Traditional Chinese.

{feed_text}

Format EXACTLY as:

📰 早安新聞摘要

**🤖 AI 人工智慧**
- (list ALL AI-related items, unlimited, merge Chinese and English sources, deduplicate)
- (cover: model releases, enterprise AI, AI policy/regulation, AI safety, AI investment/M&A)

**💻 科技 & 半導體**
- (list tech, semiconductor, chip, consumer electronics, gaming, space tech - non-AI items, unlimited)

**🌏 重大新聞**（最多3則）
- (top 3 non-tech news items)

今日重點一句話：(one sentence summarizing the most important event today)

IMPORTANT:
- Only include news from the last 24 hours
- The AI section should ALWAYS have content if feeds returned results
- Translate English headlines to Traditional Chinese
- Do NOT say "今日無相關新聞" if feeds have items"""

def call_claude(prompt: str) -> str:
    """Call Claude API for summarization."""
    import json
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        # Fallback: try to read from nullclaw config
        config_path = os.path.expanduser("~/.nullclaw/config.json")
        if os.path.exists(config_path):
            with open(config_path) as f:
                cfg = json.load(f)
            providers = cfg.get("models", {}).get("providers", [])
            for p in providers:
                if p.get("apiKey"):
                    api_key = p["apiKey"]
                    break
    if not api_key:
        print("Error: ANTHROPIC_API_KEY not set and not found in config", file=sys.stderr)
        sys.exit(1)

    body = json.dumps({
        "model": "claude-sonnet-4-5-20250514",
        "max_tokens": 2048,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read())
    return result["content"][0]["text"]

def send_telegram(text: str, chat_id: str):
    """Send message via shared telegram helper."""
    lib_path = os.path.expanduser("~/.claude/skills/lib")
    sys.path.insert(0, lib_path)
    from telegram import send_message
    send_message(chat_id, text)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deliver-to", help="Telegram chat ID for delivery")
    args = parser.parse_args()

    feeds = {
        "AI新聞（中文）": fetch_rss("https://news.google.com/rss/search?q=AI+when:1d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
        "AI News (English)": fetch_rss("https://news.google.com/rss/search?q=artificial+intelligence+OpenAI+Anthropic+Claude+Gemini+DeepMind+when:1d&hl=en-US&gl=US&ceid=US:en"),
        "科技半導體": fetch_rss("https://news.google.com/rss/search?q=科技+半導體+晶片+when:1d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
        "台灣頭條": fetch_rss("https://news.google.com/rss?hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
    }

    total = sum(len(v) for v in feeds.values())
    if total == 0:
        print("No articles fetched from any feed")
        sys.exit(1)

    summary = call_claude(build_prompt(feeds))
    print(summary)

    if args.deliver_to:
        send_telegram(summary, args.deliver_to)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Update SKILL.md**

Add `## Script` section and remove the "No run.py" note:

```markdown
## Script

~/.claude/skills/news/run.py
```

Remove from Notes section:
```
- No `run.py` — this skill requires LLM (stays as `agent` job type in cron)
```

- [ ] **Step 3: Test the script manually**

```bash
python3 ~/.claude/skills/news/run.py
```

Expected: prints a news summary in the correct 3-section format with AI content.

- [ ] **Step 4: Test with delivery**

```bash
python3 ~/.claude/skills/news/run.py --deliver-to 1234567890
```

Expected: summary delivered to Telegram.

- [ ] **Step 5: Commit**

```bash
git add ~/.claude/skills/news/run.py ~/.claude/skills/news/SKILL.md
git commit -m "feat(skill/news): add Python wrapper for self-contained execution"
```

---

## Task 8: Remove resolveSkillCommand / resolveSkillPrompt Shims

Once all jobs use `job_type: skill`, the `skill:` prefix resolution shims are dead code.

**Files:**
- Modify: `src/cron.zig` — remove `resolveSkillCommand()`, `resolveSkillPrompt()`, and all call sites
- Modify: `src/gateway.zig` — remove shim calls from `runQueueWorker()`

- [ ] **Step 1: Remove `resolveSkillCommand()` and `resolveSkillPrompt()` functions**

Delete the two functions from `src/cron.zig` (around lines 1176-1263).

- [ ] **Step 2: Remove all call sites**

In `tick()` (shell and agent branches): remove `resolved_shell_cmd`, `resolved_agent_prompt` variables and their `defer` frees.

In `cliRunJob()`: remove `resolved_cli_cmd`, `resolved_prompt` variables.

In `runQueueWorker()` (gateway.zig): remove `resolved_cmd`, `resolved_p` variables.

- [ ] **Step 3: Run tests**

```bash
zig build test --summary all
```

- [ ] **Step 4: Commit**

```bash
git add src/cron.zig src/gateway.zig
git commit -m "refactor(cron): remove resolveSkill* shims — skill jobs are first-class"
```

---

## Task 9: E2E Verification

- [ ] **Step 1: Rebuild and bounce gateway**

```bash
zig build && kill $(pgrep -f "nullclaw gateway")
sleep 5
curl -s http://localhost:3000/health | head -1
```

- [ ] **Step 2: Verify all jobs loaded with correct types**

```bash
curl -s http://localhost:3000/cron/list | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    print(f\"{j['id'][:8]}  {j['job_type']:6}  {j.get('skill_name',''):10}  {j.get('skill_args','')[:60]}\")
print(f'Total: {len(jobs)} jobs')
assert all(j['job_type'] == 'skill' for j in jobs), 'Not all jobs are skill type!'
"
```

Expected: 9 jobs, all `job_type: skill`

- [ ] **Step 3: Trigger doughcon (record-only) and verify DB status**

```bash
DOUGHCON_ID=$(curl -s http://localhost:3000/cron/list | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    if j.get('skill_name') == 'doughcon' and '--mode record' in (j.get('skill_args') or ''):
        print(j['id']); break
")
curl -s -X POST http://localhost:3000/cron/run/$DOUGHCON_ID
sleep 5
# Verify last_status and last_run_secs are set
curl -s http://localhost:3000/cron/list | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    if j.get('skill_name') == 'doughcon' and '--mode record' in (j.get('skill_args') or ''):
        print(f\"status={j.get('last_status')}  last_run={j.get('last_run_secs')}\")
        assert j.get('last_status') is not None, 'last_status not recorded!'
        assert j.get('last_run_secs') is not None, 'last_run_secs not recorded!'
        print('DB status recording OK')
"
```

- [ ] **Step 4: Trigger news skill and verify Telegram delivery**

```bash
NEWS_ID=$(curl -s http://localhost:3000/cron/list | python3 -c "
import sys, json
jobs = json.load(sys.stdin)['jobs']
for j in jobs:
    if j.get('skill_name') == 'news':
        print(j['id']); break
")
curl -s -X POST http://localhost:3000/cron/run/$NEWS_ID
```

Verify delivery via log:
```bash
strings ~/.nullclaw/gateway.log | grep "$NEWS_ID\|delivery\|news" | tail -20
```

- [ ] **Step 5: Verify via log that no `resolveSkill*` shim messages appear**

```bash
strings ~/.nullclaw/gateway.log | grep -i "resolveSkill" | tail -5
# Expected: no output (shims are removed)
```

- [ ] **Step 6: Wait for next scheduled job and verify automatic execution**

Check log after the next cron tick:
```bash
strings ~/.nullclaw/gateway.log | grep "skill\|completed\|enqueued" | tail -20
```
