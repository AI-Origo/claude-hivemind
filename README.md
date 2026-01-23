# Hivemind

Multi-agent coordination for Claude Code - track who's working where, send messages between agents, and avoid conflicts.

## Notice

This currently only works fully on MacOS and with iTerm2. This is due to the way user instructions need to be inserted into
idle terminals as Claude Code does not offer a way to be woken up by an external event trigger.

## Requirements

- **Claude Code** CLI
- **jq** for JSON processing
- **macOS + iTerm2** (optional) - Required for agent wake-up feature. You need to explicitly keep agents "awake" otherwise.

## Quick Start

### 1. Enable iTerm2 Automation (macOS only)

The agent wake-up feature uses AppleScript to send keystrokes to iTerm2. macOS requires permission for this:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Enable access for **iTerm2** (add it if not listed)

Alternatively, the first time the wake feature runs, macOS will prompt you to allow access - click "OK" to grant permission.

### 2. Load the plugin

```bash
claude --plugin-dir /path/to/hivemind
```

### 3. Run your first command

```
/hive help
```

### 4. Add to `.gitignore`

```
.hivemind/
```

## What is Hivemind?

Hivemind enables multiple Claude Code agents to work together on the same codebase without stepping on each other's toes.

**Key Features:**
- **Automatic agent registration** - Each session gets a unique phonetic codename (alfa, bravo, charlie...)
- **Inter-agent messaging** - Send direct messages or broadcast to all agents
- **Agent wake-up** - Idle agents are automatically woken when they receive a message (macOS + iTerm2)
- **Task tracking** - Set what you're working on so others know
- **File change logging** - See who changed what and when
- **Conflict warnings** - Advisory warnings when editing files another agent is working on

## Commands Reference

| Command | Description |
|---------|-------------|
| `/hive` or `/hive help` | Show all available commands |
| `/hive whoami` | Show your agent identity |
| `/hive agents` | List all active agents with tasks and files |
| `/hive status` | Full dashboard (agents, locks, messages, changes) |
| `/hive message <agent> <text>` | Send message to another agent |
| `/hive message all <text>` | Broadcast to all agents |
| `/hive task <description>` | Set what you're working on |
| `/hive task` | Clear your task |
| `/hive changes` | View last 20 file changes |
| `/hive changes <n>` | View last n changes |

## Examples

### `/hive help` - Command Reference

```
> /hive help

HIVEMIND COMMANDS
=================

hive_whoami
  Get my agent identity (no parameters)

hive_agents
  List all active agents (no parameters)

hive_status
  Show coordination dashboard (no parameters)

hive_message
  Send message to another agent or broadcast
  Parameters:
    target (required) - Agent name (alfa, bravo, etc.) or "all" for broadcast
    body (required)   - Message content

hive_task
  Set or clear my current task
  Parameters:
    description (optional) - Task description, omit or empty to clear

hive_changes
  View recent file changes
  Parameters:
    count (optional) - Number of changes to show (default 20)

hive_help
  Show this help (no parameters)

Each session gets a unique phonetic codename (alfa, bravo, charlie...).
Names are released when the session ends.

MESSAGE DELIVERY
----------------
Messages from other agents are delivered automatically with each prompt.
When another agent sends you a message, you will see it prefixed with
[HIVE AGENT MESSAGE] in your context.

COORDINATION TIPS
-----------------
1. Set your task so others know what you're working on
2. Check hive_status before editing shared files
3. Use hive_message to coordinate on conflicts
4. Review hive_changes to see recent activity
```

### `/hive whoami` - Agent Identity

```
> /hive whoami

alfa
```

The agent responds in first person when reporting this to the user: "I am agent alfa."

### `/hive agents` - List Active Agents

```
> /hive agents

HIVEMIND AGENTS
===============

Agent: alfa (active)
  Task: Implementing user authentication
  Files: src/auth.ts, src/middleware/auth.ts

Agent: bravo (active)
  Task: Writing API tests
  Files: tests/api.test.ts

Total: 2 agent(s)
```

### `/hive status` - Full Dashboard

```
> /hive status

HIVEMIND STATUS DASHBOARD
=========================

AGENTS
------
alfa
  Task: Implementing user authentication
  Files: src/auth.ts, src/middleware/auth.ts
bravo
  Task: Writing API tests
  Files: tests/api.test.ts

FILE LOCKS
----------
src/auth.ts (held by alfa)

MESSAGES
--------
Messages from other agents are delivered automatically with each prompt.

RECENT CHANGES
--------------
[14:32:01] alfa: write src/auth.ts
[14:31:45] bravo: write tests/api.test.ts
[14:30:12] alfa: create src/middleware/auth.ts
```

### `/hive message` - Direct and Broadcast Messaging

**Send to a specific agent:**
```
> /hive message bravo Hold off on auth.ts, I'm refactoring it

Message sent to bravo: "Hold off on auth.ts, I'm refactoring it"
```

**Broadcast to all agents:**
```
> /hive message all Taking a break, back in 10 minutes

Broadcast sent to 2 agent(s): bravo, charlie
```

**If target agent doesn't exist:**
```
> /hive message delta Check the logs

Agent 'delta' not found. Active agents: alfa, bravo, charlie
```

### `/hive task` - Setting and Clearing Tasks

**Set a task:**
```
> /hive task Refactoring authentication module

Task set: "Refactoring authentication module"
```

**Clear your task:**
```
> /hive task

Task cleared.
```

### `/hive changes` - View Changelog

```
> /hive changes 5

HIVEMIND CHANGELOG
==================

Last 5 changes:
[14:32:01] alfa: write src/auth.ts
[14:31:45] bravo: write tests/api.test.ts
[14:31:12] alfa: edit src/types.ts
[14:30:45] charlie: create docs/api.md
[14:30:12] alfa: create src/middleware/auth.ts
```

### Automatic Message Delivery

Messages are delivered automatically when you submit a prompt. You'll see them at the start of your context:

```
[HIVEMIND MESSAGES]
[HIVE AGENT MESSAGE] From bravo (2025-01-22T14:35:00Z): Hey, can you check the auth tests when you're done?
[BROADCAST] [HIVE AGENT MESSAGE] From charlie (2025-01-22T14:36:00Z): Pushing to main in 5 minutes
```

Messages are consumed after delivery (deleted from inbox).

### Agent Wake-Up (macOS + iTerm2)

When you send a message to an idle agent (one with no current task), Hivemind automatically wakes them up:

```
> /hive message bravo Need your help with the API design

Message sent to bravo (idle - waking agent): "Need your help with the API design"
```

The idle agent's terminal receives "Task incoming, please complete the delegated task." which triggers Claude to check for pending messages.

**Requirements:**
- macOS with iTerm2
- iTerm2 automation permissions enabled (see Quick Start)
- Both agents running in iTerm2 tabs/windows

**Important:** After waking an agent, verify ~10 seconds later that they started working on the delegated task. If not, try waking them again. The wake mechanism can occasionally fail silently, so repeat until all delegated tasks are being actively worked on.

### File Conflict Warnings

When you try to edit a file that another agent is working on:

```
[HIVEMIND WARNING] File 'src/auth.ts' is being edited by agent 'bravo'. Consider coordinating to avoid conflicts.
```

This is an advisory warning - the edit is not blocked, but you should coordinate with the other agent.

## How It Works

### Architecture Overview

Hivemind is a Claude Code plugin with three components:

1. **MCP Server** (`mcp/server.sh`) - Provides tools: `hive_whoami`, `hive_agents`, `hive_status`, `hive_message`, `hive_task`, `hive_changes`, `hive_help`

2. **Hooks** (`hooks/hooks.json`) - Intercept session and tool events:
   - `SessionStart` - Register agent, capture TTY
   - `SessionEnd` - Cleanup agent
   - `UserPromptSubmit` - Deliver messages
   - `PreToolUse` - File lock warnings, session ID injection
   - `PostToolUse` - Changelog entry, heartbeat update

3. **Skill** (`skills/hive/SKILL.md`) - Maps `/hive` commands to MCP tools

4. **Wake Utilities** (`scripts/utils/`) - AppleScript and bash wrapper for waking idle agents

### Agent Lifecycle

**SessionStart:**
1. Finds first available phonetic codename (alfa, bravo, charlie...)
2. Captures agent's TTY for wake-up feature
3. Creates agent registry entry in `.hivemind/agents/<name>.json`
4. Maps session ID to codename in `.hivemind/sessions/`
5. Creates inbox directory for messages
6. Outputs context about other active agents

**SessionEnd:**
1. Looks up codename from session mapping
2. Removes agent registry entry (frees codename for reuse)
3. Removes session mapping
4. Cleans up any file locks held by this agent
5. Deletes agent's inbox and all messages
6. If no agents remain, removes entire `.hivemind` directory

### Message Delivery

1. Sender calls `hive_message` with target and body
2. Message stored as JSON in target's inbox: `.hivemind/messages/inbox-<target>/`
3. If target is idle and has a TTY, wake script is triggered (macOS only)
4. On next `UserPromptSubmit`, recipient's hook checks inbox
5. Messages injected into context with `[HIVE AGENT MESSAGE]` prefix
6. Messages deleted after delivery (consumed)

For broadcasts (`target: "all"`), individual messages are created in each agent's inbox.

### File Coordination

**PreToolUse (Write/Edit):**
1. Checks if file has a lock by another agent
2. Outputs advisory warning if locked
3. Creates/updates lock for current agent
4. Updates agent's `workingOn` list

**PostToolUse (Write/Edit):**
1. Appends entry to changelog (JSONL format)
2. Updates agent heartbeat timestamp
3. Releases file lock

### Directory Structure

```
.hivemind/
├── agents/              # Agent state files
│   ├── alfa.json        # Agent registry entry
│   └── bravo.json
├── sessions/            # Session ID -> codename mappings
│   └── <session-id>.txt
├── messages/            # Per-agent inboxes
│   ├── inbox-alfa/
│   │   └── msg-*.json   # Pending messages
│   └── inbox-bravo/
├── locks/               # File locks (advisory)
│   └── <hash>.lock      # Lock file with owner info
└── changelog.jsonl      # Change history (JSONL format)
```

**Agent file format:**
```json
{
  "sessionName": "alfa",
  "sessionId": "<claude-session-id>",
  "startedAt": "2025-01-22T14:30:00Z",
  "lastHeartbeat": "2025-01-22T14:35:00Z",
  "currentTask": "Implementing auth",
  "workingOn": ["src/auth.ts"],
  "tty": "/dev/ttys007",
  "status": "active"
}
```

**Message file format:**
```json
{
  "id": "msg-1737556500-12345-6789",
  "from": "bravo",
  "to": "alfa",
  "timestamp": "2025-01-22T14:35:00Z",
  "body": "Hey, can you check the auth tests?"
}
```

**Lock file format:**
```json
{
  "sessionName": "alfa",
  "sessionId": "<claude-session-id>",
  "filePath": "src/auth.ts",
  "lockedAt": "2025-01-22T14:35:00Z"
}
```

## Troubleshooting

### Agent wake-up not working

The wake-up feature requires macOS + iTerm2 with automation permissions:

1. Ensure you're using iTerm2 (not Terminal.app or other terminals)
2. Check that iTerm2 has automation permissions in **System Settings** → **Privacy & Security** → **Automation**
3. Verify the agent has a TTY registered: `cat .hivemind/agents/<name>.json | jq .tty`
4. Check the debug log: `tail /tmp/hivemind-mcp-debug.log`

If permissions are missing, you can trigger the macOS prompt by running:
```bash
osascript scripts/utils/send-keystroke.scpt /dev/ttys000 "test"
```

### Stale agents showing

If a Claude session crashed without cleanup, remove stale entries:
```bash
rm -rf .hivemind/agents/*
rm -rf .hivemind/sessions/*
```

### Messages not appearing

Messages are delivered automatically on the next prompt submission. They are:
- Stored in `.hivemind/messages/inbox-<your-agent>/`
- Injected into context with `[HIVE AGENT MESSAGE]` prefix
- Deleted after delivery

If messages aren't appearing, check that:
1. The inbox directory exists for your agent
2. Message files are present (`.json` files)
3. The `UserPromptSubmit` hook is configured

### Locks stuck

File locks are advisory and cleaned up automatically on session end. To manually clear:
```bash
rm -rf .hivemind/locks/*
```

### Debug logs

Check the debug logs for troubleshooting:
- `/tmp/hivemind-debug.log` - Hook router events
- `/tmp/hivemind-mcp-debug.log` - MCP server events
- `/tmp/hivemind-pre-tool-debug.log` - PreToolUse hook events

## Contributing

Found a bug or have a feature request? Open an issue at:
https://github.com/AI-Origo/claude-hivemind/issues

## License

MIT
