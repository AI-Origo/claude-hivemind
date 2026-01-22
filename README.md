# Hivemind

Multi-agent coordination for Claude Code - track who's working where, send messages between agents, and avoid conflicts.

## Installation

```bash
claude --plugin-dir ./plugins/hivemind
```

## Commands

| Command | Description |
|---------|-------------|
| `/hive whoami` | Show your agent name |
| `/hive agents` | List all active agents |
| `/hive status` | Full dashboard (agents, locks, messages, changes) |
| `/hive message <agent> <text>` | Send message to another agent |
| `/hive message all <text>` | Broadcast to all agents |
| `/hive read` | Read and consume your messages |
| `/hive task <description>` | Set what you're working on |
| `/hive task` | Clear your task |
| `/hive changes` | View recent file changes |
| `/hive changes 10` | View last 10 changes |

## Examples

**Check who's working:**
```
> /hive agents

HIVEMIND AGENTS
===============
Agent: alfa <- this is me (active)
  Task: Implementing auth
  Files: src/auth.ts

Agent: bravo (active)
  Task: Writing tests
  Files: tests/auth.test.ts

Total: 2 agent(s)
```

**Send a message:**
```
> /hive message bravo Hold off on auth.ts, I'm refactoring it

Message sent to bravo: "Hold off on auth.ts, I'm refactoring it"
```

**Set your current task:**
```
> /hive task Refactoring authentication module

Task set: "Refactoring authentication module"
```

**See what files changed:**
```
> /hive changes 5

HIVEMIND CHANGELOG
==================
Last 5 changes:
[14:32:01] alfa: wrote src/auth.ts
[14:31:45] bravo: wrote tests/auth.test.ts
[14:30:12] alfa: wrote src/types.ts
```

## Setup

Add `.hivemind/` to your project's `.gitignore`:
```
.hivemind/
```

The `.hivemind/` directory contains runtime coordination data (agent registrations, messages, locks) that should not be committed.

## Troubleshooting

**Stale agents showing**

If a Claude session crashed without cleanup, remove stale entries:
```bash
rm -rf .hivemind/agents/*
rm -rf .hivemind/sessions/*
```

**Messages not appearing**

Use `/hive read` (or `hive_read_messages`) to read your inbox. Messages persist until explicitly read and consumed. Direct messages are deleted after reading; broadcast messages are marked as read.
