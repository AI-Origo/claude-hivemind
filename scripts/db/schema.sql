-- Hivemind DuckDB Schema
-- This schema replaces file-based storage with DuckDB + VSS for vector similarity search

-- Install and load VSS extension for semantic search
INSTALL vss;
LOAD vss;

-- Agents (replaces .hivemind/agents/*.json)
CREATE TABLE IF NOT EXISTS agents (
    name TEXT PRIMARY KEY,
    session_id TEXT,
    tty TEXT,
    started_at TIMESTAMP,
    ended_at TIMESTAMP,
    current_task TEXT,
    last_task TEXT
);

-- Agent file locks (replaces .hivemind/locks/*.lock)
CREATE TABLE IF NOT EXISTS file_locks (
    file_path TEXT PRIMARY KEY,
    agent_name TEXT NOT NULL,
    locked_at TIMESTAMP DEFAULT now(),
    FOREIGN KEY (agent_name) REFERENCES agents(name)
);

-- Messages (replaces .hivemind/messages/inbox-*/)
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    from_agent TEXT NOT NULL,
    to_agent TEXT NOT NULL,
    body TEXT NOT NULL,
    priority TEXT DEFAULT 'normal',
    created_at TIMESTAMP DEFAULT now(),
    delivered_at TIMESTAMP
);

-- Changelog (replaces .hivemind/changelog.jsonl)
CREATE TABLE IF NOT EXISTS changelog (
    id INTEGER PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT now(),
    agent TEXT NOT NULL,
    action TEXT NOT NULL,
    file_path TEXT NOT NULL,
    summary TEXT
);

-- Create sequence for changelog IDs
CREATE SEQUENCE IF NOT EXISTS changelog_id_seq;

-- Tasks (new feature)
CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    state TEXT DEFAULT 'pending' CHECK (state IN ('pending', 'claimed', 'in_progress', 'review', 'done')),
    assignee TEXT,
    depends_on INTEGER[],
    parent_id INTEGER,
    created_at TIMESTAMP DEFAULT now(),
    claimed_at TIMESTAMP,
    completed_at TIMESTAMP,
    rejection_note TEXT,
    embedding FLOAT[3072],
    FOREIGN KEY (assignee) REFERENCES agents(name),
    FOREIGN KEY (parent_id) REFERENCES tasks(id)
);

-- Create sequence for task IDs
CREATE SEQUENCE IF NOT EXISTS task_id_seq;

-- Knowledge base (new feature)
CREATE TABLE IF NOT EXISTS knowledge (
    id TEXT PRIMARY KEY,
    topic TEXT NOT NULL,
    content TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT now(),
    embedding FLOAT[3072]
);

-- Project memory (new feature - key/value store)
CREATE TABLE IF NOT EXISTS memory (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT now(),
    embedding FLOAT[3072]
);

-- Decisions log (new feature)
CREATE TABLE IF NOT EXISTS decisions (
    id INTEGER PRIMARY KEY,
    context TEXT,
    choice TEXT NOT NULL,
    rationale TEXT,
    created_at TIMESTAMP DEFAULT now(),
    embedding FLOAT[3072]
);

-- Create sequence for decision IDs
CREATE SEQUENCE IF NOT EXISTS decision_id_seq;

-- Metrics for observability (new feature)
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    task_id INTEGER,
    agent TEXT,
    timestamp TIMESTAMP DEFAULT now(),
    duration_minutes INTEGER,
    metadata TEXT
);

-- Create sequence for metrics IDs
CREATE SEQUENCE IF NOT EXISTS metrics_id_seq;

-- Context tracking for budget management (new feature)
CREATE TABLE IF NOT EXISTS context_injections (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL,
    agent_name TEXT,
    injection_type TEXT NOT NULL,
    char_count INTEGER NOT NULL,
    timestamp TIMESTAMP DEFAULT now()
);

-- Create sequence for context injection IDs
CREATE SEQUENCE IF NOT EXISTS context_injection_id_seq;

-- VSS indexes for semantic search (created after data insertion for better performance)
-- These use HNSW (Hierarchical Navigable Small World) algorithm
CREATE INDEX IF NOT EXISTS tasks_embedding_idx ON tasks USING HNSW (embedding);
CREATE INDEX IF NOT EXISTS knowledge_embedding_idx ON knowledge USING HNSW (embedding);
CREATE INDEX IF NOT EXISTS memory_embedding_idx ON memory USING HNSW (embedding);
CREATE INDEX IF NOT EXISTS decisions_embedding_idx ON decisions USING HNSW (embedding);

-- Additional indexes for common queries
CREATE INDEX IF NOT EXISTS agents_session_idx ON agents(session_id);
CREATE INDEX IF NOT EXISTS agents_tty_idx ON agents(tty);
CREATE INDEX IF NOT EXISTS messages_to_agent_idx ON messages(to_agent);
CREATE INDEX IF NOT EXISTS messages_delivered_idx ON messages(delivered_at);
CREATE INDEX IF NOT EXISTS tasks_state_idx ON tasks(state);
CREATE INDEX IF NOT EXISTS tasks_assignee_idx ON tasks(assignee);
CREATE INDEX IF NOT EXISTS changelog_timestamp_idx ON changelog(timestamp);
CREATE INDEX IF NOT EXISTS metrics_timestamp_idx ON metrics(timestamp);
CREATE INDEX IF NOT EXISTS metrics_event_type_idx ON metrics(event_type);
