---
name: hive
description: Multi-agent coordination - redirects to hivemind MCP tools
---

# /hive - Multi-Agent Coordination

All Hivemind commands are available as MCP tools. When the user runs `/hive <command>`, call the corresponding MCP tool.

## First-Time Setup

Run `/hive setup` to configure your environment:
- Starts Milvus if not already running
- Initializes database collections
- Configures status line to show agent name and current task

## Command Mapping

| User Command | MCP Tool to Call |
|--------------|------------------|
| `/hive` or `/hive help` | `hive_help` |
| `/hive setup` | `hive_setup` |
| `/hive whoami` | `hive_whoami` |
| `/hive agents` | `hive_agents` |
| `/hive status` | `hive_status` |
| `/hive message <target> <text>` | `hive_message` with `target` and `body` |
| `/hive changes [n]` | `hive_changes` with optional `count` |
| `/hive task [description]` | `hive_task` with optional `description` |
| `/hive inbox [n]` | `hive_inbox` with optional `limit` |
| `/hive read_message <id>` | `hive_read_message` with `id` |
| `/hive clean_inbox` | `hive_clean_inbox` |

## Instructions

Parse `$ARGUMENTS` and call the corresponding MCP tool:

1. If no arguments or `help`: Call `hive_help`
2. If `setup`: Call `hive_setup`
3. If `whoami`: Call `hive_whoami`
4. If `agents`: Call `hive_agents`
5. If `status`: Call `hive_status`
6. If `message <target> <text>`: Call `hive_message` with `{"target": "<target>", "body": "<text>"}`
7. If `changes [n]`: Call `hive_changes` with `{"count": n}` (default 20)
8. If `task [description]`: Call `hive_task` with `{"description": "<description>"}` (empty to clear)
9. If `inbox [n]`: Call `hive_inbox` with `{"limit": n}` (default 10)
10. If `read_message <id>`: Call `hive_read_message` with `{"id": "<id>"}`
11. If `clean_inbox`: Call `hive_clean_inbox`

The MCP tools handle all coordination logic.

## Examples

```
/hive setup
```
-> Call `hive_setup` (configures status line)

```
/hive
```
-> Call `hive_help`

```
/hive whoami
```
-> Call `hive_whoami`

```
/hive message bravo Please hold off on auth.ts
```
-> Call `hive_message` with `{"target": "bravo", "body": "Please hold off on auth.ts"}`

```
/hive task Implementing user authentication
```
-> Call `hive_task` with `{"description": "Implementing user authentication"}`

```
/hive task
```
-> Call `hive_task` with `{"description": ""}` to clear

```
/hive changes 10
```
-> Call `hive_changes` with `{"count": 10}`

```
/hive inbox
```
-> Call `hive_inbox`

```
/hive inbox 5
```
-> Call `hive_inbox` with `{"limit": 5}`

```
/hive read_message msg-1708963200-12345-6789
```
-> Call `hive_read_message` with `{"id": "msg-1708963200-12345-6789"}`

```
/hive clean_inbox
```
-> Call `hive_clean_inbox`
