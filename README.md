# Hivemind

Multi-agent coordination for Claude Code - track who's working where, communicate between agents, and avoid conflicts.

## Notice

This currently only works fully on macOS and with iTerm2. This is due to the way user instructions need to be inserted into
idle terminals as Claude Code does not offer a way to be woken up by an external event trigger.

## Requirements

- **Claude Code** CLI
- **Docker and Docker Compose** for Milvus database
- **jq** for JSON processing
- **macOS + iTerm2** (optional) - Required for agent wake-up feature. You need to explicitly keep agents "awake" otherwise.

## Prerequisites

### Docker Installation

Docker is required to run Milvus, the vector database used for hivemind's data storage.

1. Install Docker Desktop from https://www.docker.com/products/docker-desktop/
2. Ensure Docker Compose is available (included with Docker Desktop)
3. Start Docker Desktop before using hivemind

### OpenAI API Key (Optional)

Hivemind supports OpenAI embeddings for future semantic search features. This is currently optional and not required for core functionality.

1. After initializing hivemind in your project, copy the example env file:
   ```bash
   cp .hivemind/.env.example .hivemind/.env
   ```

2. Add your API key to `.hivemind/.env`:
   ```
   OPENAI_API_KEY=sk-your-key-here
   ```

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

### 3. Run Setup

```
/hive setup
```

This starts Milvus (if not already running), initializes database collections, and configures the status line to show your agent name and current task.

Restart Claude Code after setup completes.

> **Note:** Milvus is also auto-started on agent session start if it isn't running. You can still start it manually with `./path/to/hivemind/scripts/start-milvus.sh` if needed.

### 4. Run your first command

```
/hive help
```

### 5. Add to `.gitignore`

```
.hivemind/
```

## What is Hivemind?

Hivemind enables multiple Claude Code agents to work together on the same codebase without stepping on each other's toes.

**Key Features:**
- **Automatic agent registration** - Each session gets a unique phonetic codename (alfa, bravo, charlie...)
- **Inter-agent messaging** - Send direct messages or broadcast to all agents
- **Agent wake-up** - Idle agents are automatically woken when they receive a message (macOS + iTerm2)
- **Task management** - Full task lifecycle with enforcement, elapsed time tracking, and quality reminders
- **Delegation protocol** - Structured delegation with automatic reporting reminders
- **File change logging** - See who changed what and when
- **Conflict warnings** - Advisory warnings when editing files another agent is working on
- **Auto-start Milvus** - Database starts automatically on first agent session
- **Observability dashboard** - Terminal UI showing agents and metrics

## Commands Reference

All commands are available via the `/hive` slash command or by calling the MCP tools directly.

| Command | MCP Tool | Description |
|---------|----------|-------------|
| `/hive` or `/hive help` | `hive_help` | Show all available commands |
| `/hive setup` | `hive_setup` | First-time setup: starts Milvus, configures status line |
| `/hive whoami` | `hive_whoami` | Show your agent identity |
| `/hive agents` | `hive_agents` | List all active agents with their tasks |
| `/hive status` | `hive_status` | Full dashboard (agents, locks, messages, changes) |
| `/hive message <agent> <text>` | `hive_message` | Send message to another agent |
| `/hive message all <text>` | `hive_message` | Broadcast to all agents |
| `/hive task <description>` | `hive_task` | Set your current task (visible to others) |
| `/hive task` | `hive_task` | Clear your current task |
| `/hive changes` | `hive_changes` | View last 20 file changes |
| `/hive changes <n>` | `hive_changes` | View last n changes |
| `/hive inbox` | `hive_inbox` | View your message history |
| `/hive read_message <id>` | `hive_read_message` | Read full content of a truncated message |
| `/hive clean_inbox` | `hive_clean_inbox` | Remove all read messages from your inbox |

## Dashboard

Hivemind includes a terminal-based dashboard for monitoring:

```bash
# From your project directory
./path/to/hivemind/scripts/dashboard.sh

# Single snapshot (non-interactive)
./path/to/hivemind/scripts/dashboard.sh --once
```

The dashboard shows:
- Agent status (active, idle, offline)
- File hotspots (conflict-prone files)
- Recent activity metrics

Controls: `q` to quit, `r` to refresh

## Examples

### `/hive help` - Command Reference

```
> /hive help

hive_setup - First-time setup (starts Milvus, configures status line)
hive_whoami - Get your agent name
hive_agents - List active agents and their tasks
hive_status - Coordination dashboard (agents, locks, recent changes)
hive_message target=<name|all> body=<text> - Send message to agent or broadcast
hive_task description=<text> - Set current task (empty to clear)
hive_changes count=<n> - View recent file changes (default 20)
hive_inbox limit=<n> unread_only=<bool> - View message history (long messages truncated)
hive_read_message id=<msg_id> - Read full content of a truncated message
hive_clean_inbox - Remove all read messages from your inbox
Messages from other agents are delivered automatically each prompt.
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

Agent: bravo (idle)

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
bravo
  Task: (none)

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

### `/hive task` - Set Your Current Task

Set a task so other agents know what you're working on:
```
> /hive task Implementing user authentication

Task set: "Implementing user authentication"
```

Clear your task when done:
```
> /hive task

Task cleared.
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

### Automatic Message Delivery

Messages are delivered automatically when you submit a prompt. You'll see them at the start of your context:

```
[HIVEMIND MESSAGES]
[HIVE AGENT MESSAGE] From bravo (2026-02-14T14:35:00Z): Hey, can you check the auth tests when you're done?
[BROADCAST] [HIVE AGENT MESSAGE] From charlie (2026-02-14T14:36:00Z): Pushing to main in 5 minutes
```

Messages are consumed after delivery.

### Agent Wake-Up (macOS + iTerm2)

When you send a message to an idle agent (one with no current task), Hivemind automatically wakes them up:

```
> /hive message bravo Need your help with the API design

Message sent to bravo (idle - waking agent): "Need your help with the API design"
```

The idle agent's terminal receives "New message!" which triggers Claude to check for pending messages.

**How Wake-Up Works:**
Wake requests are queued and processed sequentially by a singleton background process. This prevents race conditions when multiple agents need to be woken simultaneously (e.g., during broadcasts).

**Requirements:**
- macOS with iTerm2
- iTerm2 automation permissions enabled (see Quick Start)
- Both agents running in iTerm2 tabs/windows

**Important:** After waking an agent, verify ~10 seconds later that they started working on the delegated task. If not, try waking them again. The wake mechanism can occasionally fail silently, so repeat until all delegated tasks are being actively worked on.

### `/hive inbox` - View Message History

Check your recent messages:
```
> /hive inbox

Your recent messages:
From bravo (2026-02-14T14:35:00Z): Hey, can you check the auth tests when you're done?
[UNREAD] From charlie (2026-02-14T14:40:00Z): Found a bug in the login flow
```

Long messages (over 200 characters) are truncated with a hint to read the full content:
```
[UNREAD] From bravo (2026-02-14T15:00:00Z): Here's the full error trace from... [use hive_read_message id=msg-123 to read full message]
```

### `/hive read_message` - Read Full Message

Read the full content of a truncated message:
```
> /hive read_message msg-1708963200-12345-6789

From bravo (2026-02-14T15:00:00Z):
Here's the full error trace from the auth module...
```

### `/hive clean_inbox` - Clean Up Read Messages

Remove all delivered (read) messages from your inbox:
```
> /hive clean_inbox

Cleaned inbox: removed 5 read message(s).
```

### `/hive changes` - View File Change History

See what files have been modified:
```
> /hive changes 5

HIVEMIND CHANGELOG
==================

Last 5 changes:
[14:32:01] alfa: write src/auth.ts
[14:31:45] bravo: write tests/api.test.ts
[14:30:12] alfa: create src/middleware/auth.ts
[14:28:33] charlie: write README.md
[14:25:01] alfa: write package.json
```

### File Conflict Warnings

When you try to edit a file that another agent is working on:

```
[HIVEMIND WARNING] File 'src/auth.ts' is being edited by agent 'bravo'. Consider coordinating to avoid conflicts.
```

This is an advisory warning - the edit is not blocked, but you should coordinate with the other agent.

## How It Works

### Architecture Overview

Hivemind is a Claude Code plugin with these components:

1. **MCP Server** (`mcp/server.sh`) - Provides tools: `hive_whoami`, `hive_agents`, `hive_status`, `hive_message`, `hive_task`, `hive_changes`, `hive_inbox`, `hive_read_message`, `hive_clean_inbox`, `hive_help`, `hive_setup`

2. **Hooks** (`hooks/hooks.json`) - Intercept session and tool events:
   - `SessionStart` - Register agent, initialize database, auto-start Milvus
   - `SessionEnd` - Mark agent ended, release locks, complete active tasks
   - `UserPromptSubmit` - Deliver messages, task reminders
   - `PreToolUse` - File lock warnings, session ID injection, task enforcement
   - `PostToolUse` - Changelog entry, release locks, set awaiting_task flag
   - `Stop` - Agent cleanup

3. **Skill** (`skills/hive/SKILL.md`) - Maps `/hive` commands to MCP tools

4. **Wake Utilities** (`scripts/utils/`) - AppleScript and bash wrapper for waking idle agents

5. **Dashboard** (`scripts/dashboard.sh`) - Terminal UI for monitoring

### Database Storage

All data is stored in Milvus, a vector database running via Docker:

**Architecture:**
- Milvus v2.5.4 (standalone mode)
- etcd for configuration management
- MinIO for object storage
- All components run as Docker containers

**Ports:**
- `19531` - Milvus REST API
- `9092` - Health check endpoint
- `8083` - Attu UI (only starts with `--profile ui`)

**Collections:**
```
-- Core coordination (placeholder 8-dim vectors)
{project}_hivemind_agents              -- Agent registration and status
{project}_hivemind_file_locks          -- Advisory file locks
{project}_hivemind_messages            -- Inter-agent messages
{project}_hivemind_changelog           -- File change history
{project}_hivemind_metrics             -- Event metrics for dashboard
{project}_hivemind_context_injections  -- Token budget tracking
{project}_hivemind_wake_queue          -- Agent wakeup queue

-- Vector collections (3072-dim for semantic search)
{project}_hivemind_tasks               -- Task queue with semantic search
{project}_hivemind_knowledge           -- Knowledge base with embeddings
{project}_hivemind_memory              -- Key-value store with embeddings
{project}_hivemind_decisions           -- Decision log with embeddings

-- Sequences
{project}_hivemind_sequences           -- Auto-increment IDs
```

Collections are prefixed with the project name (e.g., `myproject_hivemind_agents`) to allow multiple projects to share the same Milvus instance.

### Agent Lifecycle

**SessionStart:**
1. Auto-starts Milvus if not running (with lock to prevent concurrent starts)
2. Auto-purges project data if `.hivemind` was deleted
3. Checks if session ID already has an agent assigned
4. If not, checks for TTY-based recovery (same terminal reuses existing agent)
5. If no existing agent, finds first available phonetic codename (alfa, bravo, charlie...)
6. Creates/updates agent record in database
7. Shows other active agents, assigned tasks, and tasks in review
8. Loads `ALFA.md` for agent alfa (if present in project root)

**TTY-Based Identity:**

Agent identity is tracked by TTY (terminal device path) in addition to session ID. This ensures agents maintain their identity even when Claude Code's session ID changes (which can happen on `/clear`, context truncation, or internal resets).

**SessionEnd:**
1. Looks up codename using TTY-first lookup
2. Marks agent as ended in database (preserves for TTY recovery)
3. Completes all active tasks for this agent
4. Releases file locks held by this agent
5. Cleans up messages to and from this agent

### Message Delivery

1. Sender calls `hive_message` with target and body
2. Message stored in `messages` table
3. If target is idle and has a TTY, wake script is triggered (macOS only)
4. On next `UserPromptSubmit`, recipient's hook checks for undelivered messages
5. Messages injected into context with `[HIVE AGENT MESSAGE]` prefix
6. Messages marked as delivered

### File Coordination

**PreToolUse (Write/Edit):**
1. Checks if file has a lock by another agent
2. Outputs advisory warning if locked
3. Creates/updates lock for current agent

**PostToolUse (Write/Edit):**
1. Appends entry to changelog
2. Releases file lock

### Task Management

Hivemind includes a task tracking system backed by a vector collection with semantic search support:

- **Task lifecycle:** pending → claimed → in_progress → review → done (or rejected)
- **Auto-completion:** When an agent clears their task (`hive_task` with no description), all in_progress tasks for that agent are marked as done
- **Session cleanup:** When an agent's session ends, active tasks are completed automatically
- **Elapsed time:** Clearing a task shows how long it was active
- **Quality reminders:** On task clear, agents are reminded to run tests, lints, and checks on their changes

### Task Enforcement (Delegation Protocol)

To ensure agents always report what they're working on:

1. After `ExitPlanMode`, the `PostToolUse` hook sets an `awaiting_task` flag on the agent
2. The `PreToolUse` hook checks this flag — if set and the agent tries to use any tool other than `hive_task`, the tool call is **denied** with a message requiring the agent to set a task first
3. Once `hive_task` is called, the flag is cleared and normal operation resumes

This prevents agents from starting work after accepting a plan without recording their task for visibility.

### Delegation Guidance

When an agent exits plan mode, Hivemind provides contextual guidance:

- Shows which agents are currently active and what they're working on (to avoid duplicating effort)
- Lists idle agents available for delegation
- Provides delegation rules: delegate early, one task at a time, include context
- Tracks delegation via a `delegated_by` flag — when a delegated agent clears their task, they are reminded to report back to the delegating agent

### ALFA.md Loading

When agent `alfa` starts a session, Hivemind checks for an `ALFA.md` file in the project root (next to `.hivemind/`). If found, its contents are injected into alfa's startup context. This allows project-specific instructions to be given to the lead agent.

### Auto-Start Milvus

On `SessionStart`, if Milvus is not running, Hivemind automatically starts it using `scripts/start-milvus.sh`. A lock file (`/tmp/hivemind-milvus-start.lock`) prevents multiple agents from starting Milvus simultaneously.

### Auto-Purge on .hivemind Removal

If the `.hivemind` directory doesn't exist when a session starts (e.g., it was deleted or the project was freshly cloned), Hivemind purges all stale project data from Milvus and reinitializes collections. This ensures a clean slate without manual intervention.

### Message Truncation

Messages over 200 characters are truncated in `hive_inbox` output with a hint to use `hive_read_message` for the full content. This keeps inbox output readable when agents send long messages (e.g., error traces or code snippets).

Delivered messages older than 5 minutes are automatically cleaned up on inbox access.

### Directory Structure

```
.hivemind/
├── .env              # API keys (gitignored)
├── .env.example      # Example env file
├── .gitignore        # Ignores .env
└── version.txt       # Plugin version
```

Data is stored in Docker volumes managed by Milvus, not in the `.hivemind/` directory.

## Troubleshooting

### Milvus not starting

Check that Docker is running and ports are available:

```bash
# Check Milvus health
curl http://localhost:9092/healthz

# View Milvus logs
docker logs hivemind-milvus

# View all container logs
docker logs hivemind-etcd
docker logs hivemind-minio
```

### Agent wake-up not working

The wake-up feature requires macOS + iTerm2 with automation permissions:

1. Ensure you're using iTerm2 (not Terminal.app or other terminals)
2. Check that iTerm2 has automation permissions in **System Settings** → **Privacy & Security** → **Automation**
3. Check the debug log: `tail /tmp/hivemind-mcp-debug.log`

If permissions are missing, you can trigger the macOS prompt by running:
```bash
osascript scripts/utils/send-keystroke.scpt /dev/ttys000 "test"
```

### Stale agents showing

Agents are automatically reclaimed when a new session starts in the same terminal (TTY-based recovery). However, if a terminal window was closed without proper cleanup, stale agents may remain.

To clean up, stop Milvus with volume removal:
```bash
./scripts/stop-milvus.sh --remove-volumes
./scripts/start-milvus.sh
```

### Messages not appearing

Messages are delivered automatically on the next prompt submission. Check:
1. The `UserPromptSubmit` hook is configured
2. Milvus is running: `curl http://localhost:9092/healthz`

### Debug logs

Check the debug logs for troubleshooting:
- `/tmp/hivemind-debug.log` - Hook router events
- `/tmp/hivemind-mcp-debug.log` - MCP server events
- `/tmp/hivemind-pre-tool-debug.log` - PreToolUse hook events

### Database queries

Query Milvus directly via REST API. Replace `{project}` with your project folder name (lowercase, underscores):

```bash
# List all agents (replace myproject with your project name)
curl -X POST http://localhost:19531/v2/vectordb/entities/query \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default","collectionName":"myproject_hivemind_agents","filter":"","outputFields":["*"],"limit":100}'

# List all collections
curl -X POST http://localhost:19531/v2/vectordb/collections/list \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default"}'

# View collection info
curl -X POST http://localhost:19531/v2/vectordb/collections/describe \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default","collectionName":"myproject_hivemind_agents"}'
```

### Data cleanup

To completely reset all data:
```bash
./scripts/stop-milvus.sh --remove-volumes
./scripts/start-milvus.sh
```

## Development

### Setup

After cloning the repository, enable the git hooks:

```bash
git config core.hooksPath .githooks
```

### Automatic Versioning

The repository uses a pre-push hook that automatically bumps the version in `.claude-plugin/plugin.json` based on conventional commits:

| Commit prefix | Version bump | Example |
|---------------|--------------|---------|
| `feat!:` or `BREAKING CHANGE` | Major (1.0.0 → 2.0.0) | `feat!: remove legacy API` |
| `feat:` | Minor (0.1.0 → 0.2.0) | `feat: add new command` |
| `fix:` | Patch (0.1.0 → 0.1.1) | `fix: handle edge case` |

The hook analyzes commits being pushed and creates a version bump commit if needed. You'll see output like:

```
Bumping version: 0.13.0 → 0.13.1 (patch)
Created version bump commit. Re-run 'git push' to include it.
```

Simply run `git push` again to include the bump commit.

## Contributing

Found a bug or have a feature request? Open an issue at:
https://github.com/AI-Origo/claude-hivemind/issues

## License

MIT
