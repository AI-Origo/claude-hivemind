# Hivemind

Multi-agent coordination for Claude Code - track who's working where, manage tasks, share knowledge, and avoid conflicts.

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

### OpenAI API Key (Optional - for Semantic Search)

Hivemind can use OpenAI embeddings to enable semantic search across tasks, knowledge, and memory. This is optional - all other features work without it.

1. Get an API key from https://platform.openai.com/api-keys

2. After initializing hivemind in your project, copy the example env file:
   ```bash
   cp .hivemind/.env.example .hivemind/.env
   ```

3. Add your API key to `.hivemind/.env`:
   ```
   OPENAI_API_KEY=sk-your-key-here
   ```

**Note:** The API key is used for generating embeddings with `text-embedding-3-large` (3072 dimensions). Embeddings enable semantic search across tasks, knowledge, and memory. If no API key is configured, semantic search features are disabled but all other features work normally.

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

### 3. Start Milvus

```bash
./path/to/hivemind/scripts/start-milvus.sh
```

This starts the Milvus containers via Docker Compose. The first run may take a minute to download images.

### 4. Run Setup

```
/hive setup
```

This configures the status line to show your agent name and current task. Collections are auto-initialized on first use.

Restart Claude Code after setup completes.

### 5. Run your first command

```
/hive help
```

### 6. Add to `.gitignore`

```
.hivemind/
```

## What is Hivemind?

Hivemind enables multiple Claude Code agents to work together on the same codebase without stepping on each other's toes.

**Key Features:**
- **Automatic agent registration** - Each session gets a unique phonetic codename (alfa, bravo, charlie...)
- **Inter-agent messaging** - Send direct messages or broadcast to all agents
- **Agent wake-up** - Idle agents are automatically woken when they receive a message (macOS + iTerm2)
- **Task queue management** - Create, claim, review, and complete tasks with dependency tracking
- **Knowledge base** - Store and search project knowledge semantically
- **Project memory** - Key-value store for project state and decisions
- **Decision log** - Record architectural decisions with rationale
- **File change logging** - See who changed what and when
- **Conflict warnings** - Advisory warnings when editing files another agent is working on
- **Observability dashboard** - Terminal UI showing agents, tasks, and metrics

## Commands Reference

### Core Commands

| Command | Description |
|---------|-------------|
| `/hive` or `/hive help` | Show all available commands |
| `/hive whoami` | Show your agent identity |
| `/hive agents` | List all active agents with tasks |
| `/hive status` | Full dashboard (agents, locks, tasks, changes) |
| `/hive message <agent> <text>` | Send message to another agent |
| `/hive message all <text>` | Broadcast to all agents |
| `/hive changes` | View last 20 file changes |
| `/hive changes <n>` | View last n changes |

### Task Management

| Command | Description |
|---------|-------------|
| `/hive task create <title>` | Create a new task |
| `/hive task list` | List all tasks |
| `/hive task list pending` | List pending tasks |
| `/hive task claim <id>` | Claim a task for yourself |
| `/hive task start <id>` | Mark task as in progress |
| `/hive task review <id>` | Submit task for review |
| `/hive task approve <id>` | Approve a task in review |
| `/hive task reject <id> <note>` | Reject with feedback |
| `/hive task release <id>` | Release task back to pending |
| `/hive task get <id>` | Get task details |
| `/hive task search <query>` | Semantic search tasks |
| `/hive task split <id> <subtask1> <subtask2> ...` | Split into subtasks |

**Task States:**
```
pending → claimed → in_progress → review → done
                         ↑          │
                         └──reject──┘
```

### Knowledge Base

| Command | Description |
|---------|-------------|
| `/hive knowledge add <id> <topic> <content>` | Add knowledge entry |
| `/hive knowledge get <id>` | Retrieve knowledge by ID |
| `/hive knowledge search <query>` | Semantic search knowledge |
| `/hive knowledge list` | List all knowledge entries |
| `/hive knowledge remove <id>` | Remove knowledge entry |

### Project Memory

| Command | Description |
|---------|-------------|
| `/hive memory set <key> <value>` | Set a memory value |
| `/hive memory get <key>` | Get a memory value |
| `/hive memory search <query>` | Semantic search memory |
| `/hive memory list` | List all memory entries |
| `/hive memory delete <key>` | Delete a memory entry |

### Decision Log

| Command | Description |
|---------|-------------|
| `/hive decision record <choice>` | Record a decision |
| `/hive decision search <query>` | Search past decisions |
| `/hive decision list` | List recent decisions |

### Context Tracking

| Command | Description |
|---------|-------------|
| `/hive context budget` | Show context injection stats |
| `/hive context history` | Show injection history |

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
- Task queue summary
- File hotspots (conflict-prone files)
- 24h metrics (tasks completed, reviews)

Controls: `q` to quit, `r` to refresh

## Examples

### `/hive help` - Command Reference

```
> /hive help

HIVEMIND COMMANDS
=================

hive_whoami - Get my agent identity
hive_agents - List all active agents
hive_status - Show coordination dashboard
hive_message - Send message (target, body, priority?)
hive_changes - View recent file changes (count?)
hive_help - Show this help

TASK MANAGEMENT (hive_task)
---------------------------
action=create: title, description?, depends_on?
action=claim: id
action=start: id
action=review: id
action=approve: id
action=reject: id, note?
action=release: id
action=list: state?, assignee?
action=get: id
action=split: id, subtasks[]
action=search: query

KNOWLEDGE BASE (hive_knowledge)
-------------------------------
action=add: id, topic, content
action=get: id
action=search: query
action=list
action=remove: id

PROJECT MEMORY (hive_memory)
----------------------------
action=set: key, value
action=get: key
action=search: query
action=list
action=delete: key

DECISION LOG (hive_decision)
----------------------------
action=record: context?, choice, rationale?
action=search: query
action=list

CONTEXT TRACKING (hive_context)
-------------------------------
action=budget
action=history
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
Messages are delivered automatically with each prompt.

RECENT CHANGES
--------------
[14:32:01] alfa: write src/auth.ts
[14:31:45] bravo: write tests/api.test.ts
[14:30:12] alfa: create src/middleware/auth.ts

TASKS SUMMARY
-------------
pending: 3
in_progress: 2
review: 1
done: 5
```

### Task Management Examples

**Create a task:**
```
> /hive task create Implement user authentication

Task #1 created: Implement user authentication
```

**Create task with dependencies:**
```
> Use hive_task with action=create, title="Add login endpoint", depends_on=[1]

Task #2 created: Add login endpoint
```

**List tasks:**
```
> /hive task list

TASKS
=====
#1 [in_progress] Implement user authentication <- alfa
#2 [pending] Add login endpoint
#3 [review] Fix logout bug <- bravo
```

**Claim and work on a task:**
```
> /hive task claim 2
Task #2 claimed by alfa

> /hive task start 2
Task #2 started

> /hive task review 2
Task #2 submitted for review
```

**Split a task into subtasks:**
```
> Use hive_task with action=split, id=1, subtasks=["Add login endpoint", "Add logout endpoint", "Add token refresh"]

Created subtasks: #4, #5, #6 (parent: #1)
```

### Knowledge Base Examples

**Add knowledge:**
```
> Use hive_knowledge with action=add, id="auth-flow", topic="architecture", content="Authentication uses JWT tokens stored in httpOnly cookies. The flow is: login -> verify credentials -> issue token -> store in cookie -> subsequent requests include cookie automatically."

Knowledge 'auth-flow' added/updated
```

**Search knowledge:**
```
> /hive knowledge search how does login work

KNOWLEDGE SEARCH
================
[auth-flow] architecture: Authentication uses JWT tokens stored in httpOnly cookies...
```

### Memory Examples

**Set project state:**
```
> /hive memory set project-phase beta-testing

Memory 'project-phase' set
```

**Search memory:**
```
> /hive memory search current status

MEMORY SEARCH
=============
project-phase = beta-testing
deployment-target = staging
```

### Decision Log Examples

**Record a decision:**
```
> Use hive_decision with action=record, context="Needed session storage", choice="httpOnly cookies", rationale="More secure than localStorage, immune to XSS attacks"

Decision #1 recorded: httpOnly cookies
```

**Search past decisions:**
```
> /hive decision search session storage

DECISION SEARCH
===============
#1: Needed session storage -> httpOnly cookies
  Rationale: More secure than localStorage, immune to XSS attacks
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
[HIVE AGENT MESSAGE] From bravo (2025-01-22T14:35:00Z): Hey, can you check the auth tests when you're done?
[BROADCAST] [HIVE AGENT MESSAGE] From charlie (2025-01-22T14:36:00Z): Pushing to main in 5 minutes
```

Messages are consumed after delivery.

### Agent Wake-Up (macOS + iTerm2)

When you send a message to an idle agent (one with no current task), Hivemind automatically wakes them up:

```
> /hive message bravo Need your help with the API design

Message sent to bravo (idle - waking agent): "Need your help with the API design"
```

The idle agent's terminal receives "New message!" which triggers Claude to check for pending messages.

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

1. **MCP Server** (`mcp/server.sh`) - Provides tools: `hive_whoami`, `hive_agents`, `hive_status`, `hive_message`, `hive_task`, `hive_knowledge`, `hive_memory`, `hive_decision`, `hive_context`, `hive_changes`, `hive_help`

2. **Hooks** (`hooks/hooks.json`) - Intercept session and tool events:
   - `SessionStart` - Register agent, initialize database
   - `SessionEnd` - Mark agent ended, release locks
   - `UserPromptSubmit` - Deliver messages, task reminders
   - `PreToolUse` - File lock warnings, session ID injection
   - `PostToolUse` - Changelog entry, release locks

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
- `8083` - Optional Attu UI (if enabled)

**Collections:**
```
-- Core coordination (placeholder vectors)
hivemind_agents         -- Agent registration and status
hivemind_file_locks     -- Advisory file locks
hivemind_messages       -- Inter-agent messages
hivemind_changelog      -- File change history
hivemind_metrics        -- Event metrics for dashboard
hivemind_context_injections -- Context budget tracking

-- Vector-enabled collections (3072 dimensions)
hivemind_tasks          -- Task queue with semantic search
hivemind_knowledge      -- Knowledge base entries
hivemind_memory         -- Key-value project memory
hivemind_decisions      -- Decision log

-- Sequences
hivemind_sequences      -- Auto-increment IDs
```

All vector-enabled collections use OpenAI's `text-embedding-3-large` (3072 dimensions) for semantic search. Placeholder collections use 8-dimensional vectors.

### Agent Lifecycle

**SessionStart:**
1. Checks if session ID already has an agent assigned
2. If not, checks for TTY-based recovery (same terminal reuses existing agent)
3. If no existing agent, finds first available phonetic codename (alfa, bravo, charlie...)
4. Creates/updates agent record in database
5. Shows other active agents and assigned tasks

**TTY-Based Identity:**

Agent identity is tracked by TTY (terminal device path) in addition to session ID. This ensures agents maintain their identity even when Claude Code's session ID changes (which can happen on `/clear`, context truncation, or internal resets).

**SessionEnd:**
1. Looks up codename using TTY-first lookup
2. Marks agent as ended in database (preserves for TTY recovery)
3. Releases file locks held by this agent
4. Cleans up old delivered messages

### Message Delivery

1. Sender calls `hive_message` with target and body
2. Message stored in `messages` table
3. If target is idle and has a TTY, wake script is triggered (macOS only)
4. On next `UserPromptSubmit`, recipient's hook checks for undelivered messages
5. Messages injected into context with `[HIVE AGENT MESSAGE]` prefix
6. Messages marked as delivered

### Task State Machine

```
                    ┌─────────────────────────────────┐
                    │                                 │
                    ▼                                 │
pending ──claim──► claimed ──start──► in_progress ──review──► review
    ▲                                      ▲                    │
    │                                      │                    │
    └──────────release──────────┘          └─────reject─────────┘
                                                                │
                                                           approve
                                                                │
                                                                ▼
                                                              done
```

Tasks can have dependencies (`depends_on` array). A task is blocked if any of its dependencies are not in `done` state.

### File Coordination

**PreToolUse (Write/Edit):**
1. Checks if file has a lock by another agent
2. Outputs advisory warning if locked
3. Creates/updates lock for current agent

**PostToolUse (Write/Edit):**
1. Appends entry to changelog
2. Releases file lock

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

Query Milvus directly via REST API:

```bash
# List all agents
curl -X POST http://localhost:19531/v2/vectordb/entities/query \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default","collectionName":"hivemind_agents","filter":"","outputFields":["*"],"limit":100}'

# List pending tasks
curl -X POST http://localhost:19531/v2/vectordb/entities/query \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default","collectionName":"hivemind_tasks","filter":"state == \"pending\"","outputFields":["*"],"limit":100}'

# View collection info
curl -X POST http://localhost:19531/v2/vectordb/collections/describe \
  -H "Authorization: Bearer root:Milvus" \
  -H "Content-Type: application/json" \
  -d '{"dbName":"default","collectionName":"hivemind_agents"}'
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
