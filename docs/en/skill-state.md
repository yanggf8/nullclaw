# Structured skill state (opt-in)

Use this mode for a procedural skill whose future steps can be represented by a small, stable set of fields. It is an opt-in pilot; ordinary `nullclaw agent` turns keep their existing conversation history. A channel session can also opt in as described below.

Add `state-schema.json` beside the skill's `SKILL.md`:

```json
{
  "version": 1,
  "fields": {
    "goal": "string",
    "step": "integer",
    "completed": "array",
    "waiting_for_approval": "boolean"
  }
}
```

Supported field types are `string`, `integer`, `number`, `boolean`, `object`, and `array`. The model's final response must be a JSON object with `patch` and `reply`; `patch` may update declared fields or set one to `null` to delete it. Unknown fields, wrong types, and oversized state are rejected without changing the checkpoint.

```sh
nullclaw agent --skill my-skill --skill-state --session task-42 -m "Begin the workflow"
nullclaw agent --skill my-skill --skill-state --session task-42 -m "The reviewer approved step 2"
```

For a channel session, activate the skill with `/iskill my-skill`. If that skill contains `state-schema.json`, subsequent messages in that session use structured state automatically. `/skill clear` or another local slash command still follows the normal command path. The channel session key separates state between chats and threads.

The runtime stores a checkpoint and append-only turn observations in `<workspace>/skill-state/`, keyed by the skill and session. It sends the skill policy, schema, current state, and latest observation to the model on each turn; prior turn messages are cleared from the model context. Tool calls within a turn still use nullclaw's normal tool loop and security policy. The state update is validated and saved after the turn completes. This pilot updates state once per user turn, not after every tool call.

This pilot does not make tool side effects transactional with the state file. If a tool succeeds and the final JSON reply is invalid or the process crashes before the checkpoint write, inspect the observation log and external system before retrying the turn. The per-session file lock is released automatically when a process exits. Keep skill state free of secrets; its files are local workspace data.

The implementation tests verify state validation and persistence, not an improvement in task outcomes or cost. Before enabling it for more skills, run the same long workflow in ordinary and structured-state modes and compare completion rate, total prompt tokens, latency, and recovery after interruption. Short conversations may see no benefit because the skill policy and schema are sent on every turn. The mode is most useful when the schema can retain all facts needed for later actions. It is a poor fit when the schema must change during execution or when the historical sequence itself is the task output.
